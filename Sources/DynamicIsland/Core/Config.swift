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

    /// Which calendar dictated events go to, by title. `nil` means "decide
    /// automatically" — see `CalendarService.preferredCalendar()`. Set this when
    /// the automatic choice isn't the calendar you want.
    @Published var calendarTitle: String? { didSet { save() } }

    private struct Payload: Codable {
        var mirrorRoot: String
        var calendarTitle: String?
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
            calendarTitle = payload.calendarTitle
        } else {
            mirrorRoot = Self.defaultMirrorRoot
        }
        ensureMirrorRootExists()
    }

    func ensureMirrorRootExists() {
        try? FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
    }

    private func save() {
        let payload = Payload(mirrorRoot: mirrorRoot.path, calendarTitle: calendarTitle)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }
}
