import AppKit
import Combine
import Foundation

struct CallEvent: Equatable, Identifiable {
    enum Phase: String { case incoming, active }

    let id: UUID
    var displayName: String
    var source: String
    var phase: Phase
    var startedAt: Date
}

/// Call awareness.
///
/// **Read this before trusting it.** macOS has no public API for "a call is
/// ringing". FaceTime posts no notification a third party can observe, CallKit is
/// iOS-only, and the incoming-call banner lives in Notification Center's private
/// SQLite store (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`),
/// which is TCC-protected, undocumented, and reshaped between releases. Reading it
/// would require Full Disk Access and would break silently on upgrade.
///
/// So this monitor uses two honest signals instead:
///
/// 1. **External push (reliable).** A `dynamicisland://call?...` URL, which
///    Shortcuts, Hammerspoon, a companion iOS shortcut, or any script can fire.
///    This is the path to use if you want true incoming-call banners.
/// 2. **Conferencing heuristic (best-effort).** A known call app running *and* the
///    microphone live means the user is in a call. That is genuinely reliable for
///    the "active call" state, and needs no extra permissions — it rides on the
///    same CoreAudio signal as the recording indicator.
final class CallMonitor: ObservableObject {

    @Published private(set) var activeCall: CallEvent?

    /// Bundle identifiers whose presence + live mic implies an in-progress call.
    private static let conferencingApps: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.hnc.Discord": "Discord",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.google.meet": "Meet"
    ]

    private var cancellables = Set<AnyCancellable>()
    private weak var deviceActivity: DeviceActivityMonitor?
    private var autoDismiss: DispatchWorkItem?

    func start(deviceActivity: DeviceActivityMonitor) {
        self.deviceActivity = deviceActivity

        // Heuristic: mic goes live while a conferencing app is running.
        deviceActivity.$microphoneActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] micLive in self?.evaluateHeuristic(micLive: micLive) }
            .store(in: &cancellables)
    }

    private func evaluateHeuristic(micLive: Bool) {
        guard micLive else {
            if activeCall?.source != "External" { clear() }
            return
        }
        guard let app = runningConferencingApp() else { return }
        // Don't stomp a richer externally-pushed event.
        guard activeCall == nil else { return }

        present(CallEvent(
            id: UUID(),
            displayName: "Call in progress",
            source: app,
            phase: .active,
            startedAt: Date()
        ))
    }

    private func runningConferencingApp() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = Self.conferencingApps[id] {
                return name
            }
        }
        return nil
    }

    // MARK: - External ingress

    /// Handles `dynamicisland://call?name=Ada&app=FaceTime&phase=incoming`
    /// and `dynamicisland://call?phase=ended`.
    func handle(url: URL) {
        guard url.host == "call" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (key: String) in items.first { $0.name == key }?.value }

        if value("phase") == "ended" {
            clear()
            return
        }

        present(CallEvent(
            id: UUID(),
            displayName: value("name") ?? "Incoming call",
            source: "External",
            phase: CallEvent.Phase(rawValue: value("phase") ?? "incoming") ?? .incoming,
            startedAt: Date()
        ))
    }

    func present(_ event: CallEvent) {
        autoDismiss?.cancel()
        activeCall = event

        // Incoming banners are transient; active-call state persists until the mic drops.
        if event.phase == .incoming {
            let work = DispatchWorkItem { [weak self] in self?.clear() }
            autoDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        }
    }

    func clear() {
        autoDismiss?.cancel()
        autoDismiss = nil
        activeCall = nil
    }
}
