import AppKit
import Combine
import Foundation

/// Orchestrates the voice flow: hotkey → listen → parse → act → report.
///
/// Kept separate from `IslandModel` because it owns four collaborators of its own
/// and a multi-step async lifecycle. The island only needs to know *which phase*
/// to render, which is the single published value it observes.
final class VoiceAssistant: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case success(headline: String, detail: String?)
        case failure(message: String)

        var isActive: Bool { self != .idle }
    }

    @Published private(set) var phase: Phase = .idle
    /// Live transcript while speaking, for on-screen feedback.
    @Published private(set) var transcript = ""
    @Published private(set) var level: Double = 0

    let speech = SpeechService()
    let calendar = CalendarService()
    let obsidian = ObsidianService()
    private let hotkey = HotkeyService()

    /// Set by the model so mode changes can be recomputed.
    var onPhaseChange: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var resetWork: DispatchWorkItem?
    private var micAuthorised = false

    // MARK: - Lifecycle

    func start() {
        hotkey.onTrigger = { [weak self] in self?.toggle() }
        if !hotkey.register() {
            Log.debug("voice: hotkey unavailable — ⌃⌥Space may be taken by another app")
        }

        speech.onFinalTranscript = { [weak self] text in self?.handle(text) }

        // Mirror the pieces the UI draws, so views observe this one object.
        speech.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.transcript = $0 }
            .store(in: &cancellables)

        speech.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &cancellables)

        speech.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] speechPhase in
                guard let self else { return }
                if case .failed(let message) = speechPhase, self.phase == .listening {
                    self.set(.failure(message: message))
                    // Without this the island sits on the error forever.
                    self.scheduleReset(after: 4)
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        hotkey.unregister()
        speech.reset()
    }

    // MARK: - Hotkey

    /// Pressing the chord while listening submits early rather than cancelling —
    /// the silence timer is a fallback, not the only way to finish.
    func toggle() {
        Log.debug("voice: hotkey fired (phase=\(phase))")
        switch phase {
        case .listening:
            speech.stop()
        case .idle, .success, .failure:
            beginListening()
        case .thinking:
            break
        }
    }

    private func beginListening() {
        resetWork?.cancel()
        transcript = ""

        guard micAuthorised else {
            // Enter `.listening` first so the island opens immediately. Requesting
            // authorisation can block indefinitely — macOS may be showing a TCC
            // prompt, and a rebuild invalidates the previous grant because an
            // ad-hoc signature changes every time. Waiting silently looked exactly
            // like a hang: the hotkey fired and nothing whatsoever happened.
            set(.listening)
            Log.debug("voice: requesting mic/speech authorisation")

            var settled = false
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, !settled, self.phase == .listening else { return }
                self.set(.failure(message: "Waiting on the Microphone permission dialog"))
                self.scheduleReset(after: 5)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: deadline)

            speech.requestAuthorization { [weak self] granted, message in
                settled = true
                deadline.cancel()
                guard let self else { return }
                self.micAuthorised = granted
                Log.debug("voice: authorisation granted=\(granted)")
                if granted {
                    self.set(.idle)          // allow beginListening to re-enter
                    self.beginListening()
                } else {
                    self.set(.failure(message: message ?? "Microphone access denied"))
                    self.scheduleReset(after: 4)
                }
            }
            return
        }

        set(.listening)
        speech.start()
    }

    // MARK: - Dispatch

    private func handle(_ text: String) {
        set(.thinking)

        switch VoiceIntentParser.parse(text) {
        case .openVault(let query):
            openVault(query)
        case .createEvent(let title, let start, let end):
            createEvent(title: title, start: start, end: end)
        case .quickLink(let link):
            openQuickLink(link)
        case .unrecognised(let reason):
            set(.failure(message: reason))
            scheduleReset(after: 4)
        }
    }

    private func openVault(_ query: String) {
        guard obsidian.isInstalled else {
            set(.failure(message: "Obsidian isn't installed"))
            scheduleReset(after: 4)
            return
        }
        guard let vault = obsidian.match(query) else {
            let known = obsidian.vaults().map(\.name).joined(separator: ", ")
            set(.failure(message: known.isEmpty
                ? "No vaults found"
                : "No vault matching “\(query)”. Known: \(known)"))
            scheduleReset(after: 5)
            return
        }

        if obsidian.open(vault) {
            // Collapse straight away rather than holding a confirmation. Obsidian
            // coming to the front *is* the confirmation, and by then the user is
            // looking at their vault, not at a panel telling them so.
            //
            // Deliberately different from the calendar path below, which keeps its
            // confirmation up: creating an event produces nothing visible, so the
            // "what, when, and which calendar" readout is the only feedback there is.
            Log.debug("voice: opened \(vault.name), collapsing")
            dismiss()
        } else {
            set(.failure(message: "Couldn't open \(vault.name)"))
            scheduleReset(after: 4)
        }
    }

    /// Opens one of Google's instant-create URLs in the default browser.
    ///
    /// Collapses immediately, like the vault: the browser arriving with a new doc
    /// or meeting is the confirmation, and the user's attention has already moved.
    private func openQuickLink(_ link: QuickLink) {
        Log.debug("voice: opening \(link.title) — \(link.url)")
        if NSWorkspace.shared.open(link.url) {
            dismiss()
        } else {
            set(.failure(message: "Couldn't open \(link.title)"))
            scheduleReset(after: 4)
        }
    }

    private func createEvent(title: String, start: Date, end: Date) {
        let write: () -> Void = { [weak self] in
            guard let self else { return }
            self.calendar.createEvent(title: title, start: start, end: end) { result in
                switch result {
                case .success:
                    let when = Self.formatSpan(start: start, end: end)
                    var detail = when
                    if let destination = self.calendar.destinationDescription() {
                        detail += " · \(destination)"
                    }
                    // Say so rather than implying it reached Google.
                    if self.calendar.isLocalOnly {
                        detail += " — local calendar only"
                    }
                    self.set(.success(headline: title, detail: detail))
                    self.scheduleReset(after: 3.5)
                case .failure(let error):
                    self.set(.failure(message: error.localizedDescription))
                    self.scheduleReset(after: 5)
                }
            }
        }

        if calendar.access == .granted {
            write()
        } else {
            calendar.requestAccess { [weak self] granted in
                guard let self else { return }
                if granted {
                    write()
                } else {
                    self.set(.failure(message: "Calendar access denied"))
                    self.scheduleReset(after: 4)
                }
            }
        }
    }

    // MARK: - Helpers

    private func set(_ next: Phase) {
        guard phase != next else { return }
        Log.debug("voice: phase \(phase) → \(next)")
        phase = next
        onPhaseChange?()
    }

    private func scheduleReset(after delay: TimeInterval) {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.speech.reset()
            self?.transcript = ""
            self?.set(.idle)
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Always recomputes, even if the phase was already `.idle`.
    ///
    /// `set()` early-returns on an unchanged phase, so a panel that had somehow
    /// desynced from the island's mode could never be closed — the X button would
    /// do nothing at all. Forcing the recompute makes dismissal unconditional.
    func dismiss() {
        resetWork?.cancel()
        speech.reset()
        transcript = ""
        if phase == .idle {
            onPhaseChange?()
        } else {
            set(.idle)
        }
    }

    private static func formatSpan(start: Date, end: Date) -> String {
        let time = DateFormatter()
        time.setLocalizedDateFormatFromTemplate("j:mm")

        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE d MMM")

        let isToday = Calendar.current.isDateInToday(start)
        let prefix = isToday ? "Today" : day.string(from: start)
        return "\(prefix) \(time.string(from: start))–\(time.string(from: end))"
    }

    static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
