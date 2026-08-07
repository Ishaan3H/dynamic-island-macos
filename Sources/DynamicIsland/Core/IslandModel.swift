import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Which expanded face the island shows.
enum IslandFace: String { case media, vault }

/// Regions that respond to a bare click.
enum TapZone { case body, header }

/// Presentation state for the island.
///
/// **Observation strategy.** This object deliberately does *not* re-publish its
/// services' changes. An earlier version bridged every child `objectWillChange`
/// into this one so views could reach services through `model.spotify.…`; the
/// effect was that a single filesystem event, or the 1 Hz scrubber tick,
/// invalidated the entire view tree — including twenty image decodes. Each service
/// is injected into the environment separately and observed by exactly the views
/// that read it, so a scrubber tick now redraws a progress bar and nothing else.
///
/// What remains here are the few subscriptions that genuinely change *which state
/// is on screen*, each de-duplicated so it fires on transitions rather than ticks.
final class IslandModel: ObservableObject {

    @Published private(set) var mode: IslandMode = .collapsed
    @Published var face: IslandFace = .media
    /// Which corner stays put as the island grows. Owned by the window controller,
    /// which is the only thing that knows about screens.
    @Published var anchor = IslandAnchor()
    /// True while the island is being dragged to a new position.
    @Published var isMoving = false

    /// Set by the window controller: `(translationFromDragStart, isFinished)`.
    var moveHandler: ((CGSize, Bool) -> Void)?
    @Published var isDropTargeted = false
    @Published var selectedFolder: URL?
    @Published var newFolderName = ""
    @Published var isNamingFolder = false
    @Published var toast: String?

    // Services — each injected into the environment independently.
    let spotify = SpotifyService()
    let vault = VaultStore()
    let mirror = FolderMirror()
    let deviceActivity = DeviceActivityMonitor()
    let calls = CallMonitor()
    let status = SystemStatusService()

    /// Sticky open, set by a click. Survives the pointer leaving; only a click on
    /// the header or outside the island clears it.
    private(set) var isExpanded = false

    private var toastWork: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func start() {
        spotify.start()
        mirror.start()
        deviceActivity.start()
        calls.start(deviceActivity: deviceActivity)
        status.start()

        // Only two things reorder the priority ladder from outside: a call
        // arriving, and audio starting or stopping. Both are de-duplicated so a
        // position tick or a repeated flag can't schedule needless work.
        calls.$activeCall
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeMode() }
            .store(in: &cancellables)

        spotify.$current
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeMode() }
            .store(in: &cancellables)

        installGlobalClickMonitor()

        // DI_OPEN=1 pins the island open at launch. Working on the expanded states
        // is otherwise a matter of holding the pointer still with one hand.
        if ProcessInfo.processInfo.environment["DI_OPEN"] == "1" {
            face = .vault
            isExpanded = true
            recomputeMode()
        }
    }

    func stop() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
        spotify.stop()
        deviceActivity.stop()
        status.stop()
    }

    // MARK: - Mode resolution

    /// The single decision point. Priority, highest first.
    ///
    /// Pointer position is not an input. The island opens only because the user
    /// clicked it (`isExpanded`), or because something genuinely demands the
    /// space: a call, or a drag being held over it.
    private func resolveMode() -> IslandMode {
        if calls.activeCall != nil { return .alert }
        // Only the *collapsed* island morphs into a generic drop zone. Once it is
        // open the vault is already showing, with per-folder drop targets that are
        // more useful than a catch-all — and swapping the content out mid-drag
        // would also yank the source view out from under a drag starting here.
        if isDropTargeted && !isExpanded { return .dropTarget }
        if isExpanded { return .expanded }
        return .collapsed
    }

    private func recomputeMode() {
        let next = resolveMode()
        guard next != mode else { return }

        let previous = mode
        Log.debug("mode \(previous) → \(next)")
        withAnimation(IslandSpring.transition(from: previous, to: next)) {
            mode = next
        }

        // Timers run only while their output is on screen. Collapsed, the island
        // schedules no wakeups at all.
        spotify.isVisible = (next == .expanded)
        status.isVisible = next.showsStatusHeader
    }

    // MARK: - Interaction

    /// Bare clicks on the island. Buttons consume their own hits before this runs,
    /// so pressing play never also toggles the expansion.
    func handleTap(_ zone: TapZone) {
        // A reposition drag ends with a click-like event at the drop point.
        guard !isMoving else { return }
        Log.debug("tap \(zone) (expanded=\(isExpanded))")
        switch zone {
        case .header:
            // Header is the collapse affordance once open.
            if isExpanded { collapse() } else { expand() }
        case .body:
            // Already open: let the click fall through to content interaction.
            guard !isExpanded else { return }
            expand()
        }
    }

    /// A drag that moves the island must not also be read as a click that opens
    /// it, so the tap handler checks this.
    func move(translation: CGSize, finished: Bool) {
        if !isMoving { isMoving = true }
        moveHandler?(translation, finished)
        if finished {
            // Cleared a beat later: the tap gesture resolves after the drag ends,
            // and would otherwise expand the island the moment you let go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.isMoving = false
            }
        }
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        recomputeMode()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        isNamingFolder = false
        recomputeMode()
    }

    func show(face newFace: IslandFace) {
        guard face != newFace else { return }
        // Faces are different heights, so this resizes the island — spring it
        // rather than cross-fading in place.
        withAnimation(IslandSpring.morph) { face = newFace }
        recomputeMode()
    }

    func setDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        isDropTargeted = targeted
        recomputeMode()
    }

    /// Global monitors receive only events destined for *other* applications, so
    /// this fires on clicks outside the island and never on clicks within it.
    /// Mouse-event monitors need no Accessibility grant (key events would).
    private func installGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.isExpanded else { return }
            self.collapse()
        }
    }

    func flash(_ message: String) {
        toastWork?.cancel()
        withAnimation(IslandSpring.content) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(IslandSpring.content) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    // MARK: - Drag & drop
    //
    // Providers resolve on system background queues; the vault then does its file
    // I/O on its own queue. Nothing here touches the main thread except the final
    // model update, so dropping a large file cannot stall a frame.

    @discardableResult
    func handleDrop(providers: [NSItemProvider], into destination: URL? = nil) -> Bool {
        guard !providers.isEmpty else { return false }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    self?.receive(fileURL: url, into: destination)
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] object, _ in
                    guard let image = object as? NSImage, let data = image.pngData() else { return }
                    self?.receive(imageData: data, into: destination)
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                    guard let string = object as? String, !string.isEmpty else { return }
                    self?.receive(text: string, into: destination)
                }
            }
        }

        DispatchQueue.main.async { self.setDropTargeted(false) }
        return true
    }

    private func receive(fileURL: URL, into destination: URL?) {
        if let destination {
            mirror.ingest(fileAt: fileURL, into: destination) { [weak self] result in
                switch result {
                case .success(let written): self?.flash("Filed \(written.lastPathComponent)")
                case .failure: self?.flash("Couldn't file that item")
                }
            }
        } else {
            vault.addFile(at: fileURL) { [weak self] item in
                self?.flash(item == nil ? "Couldn't stage that file" : "Staged \(fileURL.lastPathComponent)")
            }
        }
    }

    private func receive(imageData: Data, into destination: URL?) {
        if let destination {
            mirror.write(data: imageData, named: "Dropped Image.png", into: destination) { [weak self] result in
                switch result {
                case .success(let url): self?.flash("Filed \(url.lastPathComponent)")
                case .failure: self?.flash("Couldn't file that image")
                }
            }
        } else {
            vault.addImage(data: imageData) { [weak self] item in
                self?.flash(item == nil ? "Couldn't stage that image" : "Staged image")
            }
        }
    }

    private func receive(text: String, into destination: URL?) {
        if let destination {
            let data = Data(text.utf8)
            mirror.write(data: data, named: "Snippet.txt", into: destination) { [weak self] result in
                switch result {
                case .success(let url): self?.flash("Filed \(url.lastPathComponent)")
                case .failure: self?.flash("Couldn't file that snippet")
                }
            }
        } else {
            vault.addText(text) { [weak self] _ in self?.flash("Staged snippet") }
        }
    }

    // MARK: - Folder actions

    func commitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            isNamingFolder = false
            return
        }
        let parent = selectedFolder
        newFolderName = ""
        isNamingFolder = false

        mirror.createFolder(named: name, in: parent) { [weak self] result in
            switch result {
            case .success(let url): self?.flash("Created \(url.lastPathComponent)")
            case .failure(let error): self?.flash(error.localizedDescription)
            }
        }
    }

    func file(_ item: StagedItem, into folder: URL) {
        if item.kind == .text, let text = item.text {
            mirror.write(
                data: Data(text.utf8),
                named: "\(item.title.prefix(30)).txt",
                into: folder
            ) { [weak self] result in
                if case .success(let url) = result {
                    self?.vault.markFiled(item, to: url)
                    self?.flash("Filed to \(folder.lastPathComponent)")
                }
            }
            return
        }

        guard let source = vault.url(for: item) else { return }
        mirror.ingest(fileAt: source, into: folder) { [weak self] result in
            switch result {
            case .success(let written):
                self?.vault.markFiled(item, to: written)
                self?.flash("Filed to \(folder.lastPathComponent)")
            case .failure:
                self?.flash("Couldn't file that item")
            }
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
