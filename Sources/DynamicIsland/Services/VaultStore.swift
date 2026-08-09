import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum StagedKind: String, Codable {
    case text, image, file
}

struct StagedItem: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: StagedKind
    var title: String
    let createdAt: Date
    /// Filename inside the vault blob directory. `nil` for pure-text items.
    let filename: String?
    /// Inline payload for text snippets.
    let text: String?
    /// Set once the item has been filed into the mirrored tree.
    var filedTo: String?

    var isFiled: Bool { filedTo != nil }
}

/// Temporary holding area for dragged content.
///
/// Blobs are copied into Application Support rather than referenced in place, so a
/// staged screenshot survives the original being moved or deleted. The index is a
/// plain JSON file — small enough that atomic rewrites are cheaper than any
/// database, and trivially inspectable.
///
/// Every filesystem operation runs on `io`. Only the `items` mutation touches the
/// main thread, so staging a 500 MB video costs the UI one array insert.
final class VaultStore: ObservableObject {

    @Published private(set) var items: [StagedItem] = []
    /// Set briefly after a copy so the UI can flash a confirmation.
    @Published private(set) var lastCopiedID: UUID?

    private let blobDirectory: URL
    private let indexURL: URL
    private let io = DispatchQueue(label: "com.qwerty.dynamicisland.vault", qos: .userInitiated)

    init() {
        blobDirectory = Config.supportDirectory.appendingPathComponent("Vault", isDirectory: true)
        indexURL = Config.supportDirectory.appendingPathComponent("vault-index.json")
        try? FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([StagedItem].self, from: data) else { return }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        let snapshot = items
        io.async { [indexURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func url(for item: StagedItem) -> URL? {
        item.filename.map { blobDirectory.appendingPathComponent($0) }
    }

    // MARK: - Staging

    func addText(_ string: String, completion: @escaping (StagedItem?) -> Void = { _ in }) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = StagedItem(
            id: UUID(),
            kind: .text,
            title: Self.previewTitle(for: trimmed),
            createdAt: Date(),
            filename: nil,
            text: trimmed,
            filedTo: nil
        )
        // Text lives in the index itself — no blob, nothing to write off-thread.
        insert(item)
        completion(item)
    }

    func addImage(
        data: Data,
        fileExtension: String = "png",
        title: String? = nil,
        completion: @escaping (StagedItem?) -> Void = { _ in }
    ) {
        let display = title ?? "Image \(Self.timeStamp())"
        let name = Self.blobPath(for: "\(display).\(fileExtension)")
        let destination = blobDirectory.appendingPathComponent(name)

        io.async { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let item = StagedItem(
                id: UUID(),
                kind: .image,
                title: display,
                createdAt: Date(),
                filename: name,
                text: nil,
                filedTo: nil
            )
            DispatchQueue.main.async {
                self?.insert(item)
                completion(item)
            }
        }
    }

    /// Copies (never moves) the source, so dragging out of Finder is non-destructive.
    func addFile(at source: URL, completion: @escaping (StagedItem?) -> Void = { _ in }) {
        let name = Self.blobPath(for: source.lastPathComponent)
        let destination = blobDirectory.appendingPathComponent(name)

        io.async { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let isImage = (try? source.resourceValues(forKeys: [.contentTypeKey]))?
                .contentType?.conforms(to: .image) ?? false

            let item = StagedItem(
                id: UUID(),
                kind: isImage ? .image : .file,
                title: source.lastPathComponent,
                createdAt: Date(),
                filename: name,
                text: nil,
                filedTo: nil
            )
            DispatchQueue.main.async {
                self?.insert(item)
                completion(item)
            }
        }
    }

    private func insert(_ item: StagedItem) {
        items.insert(item, at: 0)
        persist()
    }

    // MARK: - Actions

    /// Quick-copy back to the clipboard. Image bytes are read off-thread; only the
    /// pasteboard write itself has to happen on main.
    func copyToClipboard(_ item: StagedItem) {
        switch item.kind {
        case .text:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(item.text ?? "", forType: .string)
            confirmCopy(item)

        case .image, .file:
            guard let url = url(for: item) else { return }
            io.async { [weak self] in
                let image = item.kind == .image ? NSImage(contentsOf: url) : nil
                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([url as NSURL])
                    // Also offer pixels, so paste works in editors that want them.
                    if let image { pb.writeObjects([image]) }
                    self?.confirmCopy(item)
                }
            }
        }
    }

    private func confirmCopy(_ item: StagedItem) {
        lastCopiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.lastCopiedID == item.id { self?.lastCopiedID = nil }
        }
    }

    func remove(_ item: StagedItem) {
        let relative = item.filename
        items.removeAll { $0.id == item.id }
        persist()
        io.async { [weak self] in
            if let relative { self?.deleteBlob(at: relative) }
        }
    }

    func clearAll() {
        let paths = items.compactMap(\.filename)
        items.removeAll()
        persist()
        io.async { [weak self] in
            for path in paths { self?.deleteBlob(at: path) }
        }
    }

    /// Marks an item as filed into the mirrored tree (the blob stays until removed).
    func markFiled(_ item: StagedItem, to destination: URL) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].filedTo = destination.path
        persist()
    }

    // MARK: - Helpers

    private static func previewTitle(for text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    private static func timeStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        return f.string(from: Date())
    }

    /// Blobs live in a per-item directory: `<uuid>/<real name>`.
    ///
    /// The uniquifier has to go *somewhere*, and putting it in the filename
    /// (`<uuid>-Screenshot.png`) means that is the name the file carries when it's
    /// dragged out into Mail or Messages. A containing directory keeps names
    /// collision-free and clean.
    private static func blobPath(for filename: String) -> String {
        let safe = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(UUID().uuidString)/\(safe.isEmpty ? "item" : safe)"
    }

    /// Removes the per-item directory, not just the file inside it. Flat
    /// legacy paths (no slash) are still handled, so older indexes stay valid.
    private func deleteBlob(at relative: String) {
        let url = blobDirectory.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent()
        let target = parent.path == blobDirectory.path ? url : parent
        try? FileManager.default.removeItem(at: target)
    }
}
