import AppKit
import Combine
import CoreServices
import Foundation

/// One entry in the mirrored tree.
struct MirrorNode: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    var children: [MirrorNode]

    var childCount: Int { children.count }
}

/// **The file listener.**
///
/// The mirror is deliberately *one-way authoritative*: the target directory on
/// disk is the single source of truth, and the island renders a live projection of
/// it. Creating a folder in the UI performs a real `createDirectory`; the FSEvents
/// stream then reports that change back and refreshes the tree. This means an
/// edit made in Finder, in a terminal, or by any other process shows up in the
/// island identically to one made in-app — there is no second copy of the state to
/// drift out of sync.
///
/// FSEvents (rather than a `DispatchSource` per directory) is what makes recursive
/// watching cheap: one kernel-backed stream covers the whole subtree, and it
/// coalesces bursts for us.
final class FolderMirror: ObservableObject {

    @Published private(set) var root: MirrorNode?
    @Published private(set) var rootURL: URL
    /// Human-readable description of the most recent filesystem event, for the UI.
    @Published private(set) var lastEvent: String?
    @Published private(set) var isWatching = false

    /// Directory depth to project into the UI. The island is a glanceable surface,
    /// not a file browser — bounding this keeps rescans O(small).
    private let maxDepth = 3

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.qwerty.dynamicisland.fsevents", qos: .utility)
    private var rescanWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Minimum wall-clock gap between two tree walks. Doubles as the worst-case
    /// staleness of the projection: ~3 refreshes/second under heavy writes, and
    /// no perceptible delay for the one-folder-at-a-time case, where the previous
    /// scan is always older than this and the refresh runs immediately.
    private static let minScanInterval: TimeInterval = 0.35

    /// Guards against stacking tree walks. Touched from both the main thread
    /// (`start`, `setRoot`) and `queue`, so the test-and-set has to be atomic.
    private let scanLock = NSLock()
    private var scanInFlight = false
    private var lastScanStarted = Date.distantPast

    private func beginScanIfIdle() -> Bool {
        scanLock.lock()
        defer { scanLock.unlock() }
        if scanInFlight { return false }
        scanInFlight = true
        lastScanStarted = Date()
        return true
    }

    private func endScan() {
        scanLock.lock()
        scanInFlight = false
        scanLock.unlock()
    }

    init(config: Config = .shared) {
        self.rootURL = config.mirrorRoot
        config.$mirrorRoot
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] url in self?.setRoot(url) }
            .store(in: &cancellables)
    }

    deinit { stopStream() }

    // MARK: - Lifecycle

    func start() {
        Config.shared.ensureMirrorRootExists()
        rescan()
        startStream()
    }

    func setRoot(_ url: URL) {
        stopStream()
        rootURL = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rescan()
        startStream()
    }

    // MARK: - FSEvents

    private func startStream() {
        stopStream()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        // Non-capturing C callback — state travels through `context.info`.
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let mirror = Unmanaged<FolderMirror>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            for i in 0..<count where i < paths.count {
                events.append((paths[i], rawFlags[i]))
            }
            mirror.handle(events: events)
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,                       // latency: coalesce bursts, stay responsive
            flags
        ) else {
            DispatchQueue.main.async { self.isWatching = false }
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        Log.debug("watching \(rootURL.path)")
        DispatchQueue.main.async { self.isWatching = true }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        DispatchQueue.main.async { self.isWatching = false }
    }

    private func handle(events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard let latest = events.last else { return }
        let summary = Self.describe(path: latest.path, flags: latest.flags, root: rootURL)
        Log.debug("fsevent \(events.count)x → \(summary)")

        // Rate-limit rather than debounce.
        //
        // A trailing debounce is wrong here in both directions. Short (120 ms) and
        // it never coalesces anything, because the stream's own latency spaces
        // batches ~150 ms apart — every batch clears the timer and gets its own
        // full tree walk. Long (250 ms) and it starves outright: each batch
        // cancels the pending item before it can fire, so a directory under
        // sustained writes never refreshes until all activity stops.
        //
        // A leading-edge throttle has neither failure mode. The first event in a
        // quiet period scans immediately; anything arriving inside the window is
        // folded into one scan pinned to the *next allowed slot*, not pushed
        // further out. Guaranteed max rate, guaranteed max staleness.
        rescanWorkItem?.cancel()

        scanLock.lock()
        let sinceLastScan = Date().timeIntervalSince(lastScanStarted)
        scanLock.unlock()

        if sinceLastScan >= Self.minScanInterval {
            rescan()
            DispatchQueue.main.async { self.lastEvent = summary }
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.rescan()
                DispatchQueue.main.async { self?.lastEvent = summary }
            }
            rescanWorkItem = work
            queue.asyncAfter(
                deadline: .now() + (Self.minScanInterval - sinceLastScan),
                execute: work
            )
        }
    }

    private static func describe(path: String, flags: FSEventStreamEventFlags, root: URL) -> String {
        let name = (path as NSString).lastPathComponent
        let f = Int(flags)
        if f & kFSEventStreamEventFlagItemRemoved != 0 { return "Removed \(name)" }
        if f & kFSEventStreamEventFlagItemRenamed != 0 { return "Renamed \(name)" }
        if f & kFSEventStreamEventFlagItemCreated != 0 { return "Added \(name)" }
        if f & kFSEventStreamEventFlagItemModified != 0 { return "Modified \(name)" }
        return "Updated \(name)"
    }

    // MARK: - Scanning

    private func rescan() {
        // `queue` is serial, so bursts would otherwise stack full tree walks
        // behind each other — every one of them producing a result the next
        // immediately supersedes. One in-flight scan is always enough.
        guard beginScanIfIdle() else { return }

        let url = rootURL
        let depth = maxDepth
        queue.async { [weak self] in
            defer { self?.endScan() }
            let tree = FolderMirror.scan(url: url, depth: depth)
            Log.debug("rescan → \(tree?.children.count ?? 0) top-level item(s)")
            DispatchQueue.main.async {
                guard let self else { return }
                // FSEvents reports plenty of changes the projection can't show —
                // mtime bumps, writes below the depth cap, attribute touches.
                // Publishing an identical tree would invalidate the list for free.
                guard self.root != tree else { return }
                self.root = tree
            }
        }
    }

    private static func scan(url: URL, depth: Int) -> MirrorNode? {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey
        ]) else { return nil }

        let isDir = values.isDirectory ?? false
        var children: [MirrorNode] = []

        if isDir && depth > 0 {
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []

            children = contents
                .compactMap { scan(url: $0, depth: depth - 1) }
                .sorted { lhs, rhs in
                    // Folders first, then alphabetical — matches Finder's "kind" grouping.
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
        }

        return MirrorNode(
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDir,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            children: children
        )
    }

    // MARK: - Mutations
    //
    // Every mutation writes to disk and lets the FSEvents stream drive the UI
    // update, so in-app and out-of-app changes take exactly the same path.
    //
    // All of them run on `queue`. Copying a multi-gigabyte file that a user just
    // dragged in must never happen on the main thread — that is a multi-second
    // beachball, not a dropped frame. Completions land back on main.

    func createFolder(
        named rawName: String,
        in parent: URL? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let name = Self.sanitize(rawName)
        guard !name.isEmpty else {
            DispatchQueue.main.async { completion(.failure(MirrorError.invalidName)) }
            return
        }
        let base = parent ?? rootURL

        queue.async {
            let target = Self.uniqueURL(for: base.appendingPathComponent(name, isDirectory: true))
            let result = Result { () -> URL in
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Copy a staged file into the mirrored tree.
    func ingest(
        fileAt source: URL,
        into destinationDir: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async {
            let target = Self.uniqueURL(
                for: destinationDir.appendingPathComponent(source.lastPathComponent))
            let result = Result { () -> URL in
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Write raw bytes (a dropped image or text snippet) into the mirrored tree.
    func write(
        data: Data,
        named name: String,
        into destinationDir: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async {
            let target = Self.uniqueURL(
                for: destinationDir.appendingPathComponent(Self.sanitize(name)))
            let result = Result { () -> URL in
                try data.write(to: target, options: .atomic)
                return target
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Moves to Trash rather than unlinking — a mirrored folder is real user data.
    func trash(_ url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    private static func sanitize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Appends " 2", " 3", … rather than overwriting an existing item.
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        for n in 2...999 {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(stem) \(n)")
                : dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6))")
    }

    enum MirrorError: LocalizedError {
        case invalidName
        var errorDescription: String? {
            switch self {
            case .invalidName: return "Folder name can't be empty."
            }
        }
    }
}
