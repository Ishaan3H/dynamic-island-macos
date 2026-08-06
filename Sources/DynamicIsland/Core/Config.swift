import Foundation
import Combine

/// User-tunable settings, persisted as JSON in Application Support.
///
/// `mirrorRoot` is the **target local directory** that the island's folder tree
/// mirrors. Change it here, in `config.json`, or via "Choose Mirror Folder…" in
/// the status-bar menu.
final class Config: ObservableObject {
    static let shared = Config()

    @Published var mirrorRoot: URL { didSet { save() } }
    /// Poll interval for Spotify progress. State changes arrive by notification;
    /// this only advances the scrubber, so it can stay lazy.
    @Published var progressTick: TimeInterval = 1.0

    /// Collapsed pill's frame origin in AppKit global coordinates, or `nil` for
    /// the default top-right corner. Written on drag *end* only — persisting on
    /// every frame of a drag would be dozens of disk writes per gesture.
    private(set) var pillOrigin: CGPoint?

    func savePillOrigin(_ origin: CGPoint?) {
        pillOrigin = origin
        save()
    }

    private struct Payload: Codable {
        var mirrorRoot: String
        var pillX: Double?
        var pillY: Double?
    }

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DynamicIsland", isDirectory: true)
    }()

    private static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    /// Default target directory. Overridable — see `mirrorRoot`.
    static var defaultMirrorRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IslandVault", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: Self.configURL),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            mirrorRoot = URL(fileURLWithPath: payload.mirrorRoot, isDirectory: true)
            if let x = payload.pillX, let y = payload.pillY {
                pillOrigin = CGPoint(x: x, y: y)
            }
        } else {
            mirrorRoot = Self.defaultMirrorRoot
        }
        ensureMirrorRootExists()
    }

    func ensureMirrorRootExists() {
        try? FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
    }

    private func save() {
        var payload = Payload(mirrorRoot: mirrorRoot.path, pillX: nil, pillY: nil)
        if let origin = pillOrigin {
            payload.pillX = Double(origin.x)
            payload.pillY = Double(origin.y)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }
}
