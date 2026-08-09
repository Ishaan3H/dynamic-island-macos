import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = IslandModel()
    private var windowController: IslandWindowController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // DI_CALENDAR_CHECK=1 reports where dictated events would land, then quits.
        // Runs inside the real app on purpose: the Calendar grant TCC records is
        // keyed to this bundle, so checking from a separate binary would prove
        // nothing about what the island itself can see.
        if ProcessInfo.processInfo.environment["DI_CALENDAR_CHECK"] == "1" {
            runCalendarCheck()
            return
        }
        if ProcessInfo.processInfo.environment["DI_MIC_CHECK"] == "1" {
            runMicCheck()
            return
        }

        registerURLHandler()

        model.start()
        windowController = IslandWindowController(model: model)
        buildStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "capsule.portrait.fill",
            accessibilityDescription: "Dynamic Island"
        )
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Vault", action: #selector(openVault), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Reveal Mirror Folder", action: #selector(revealMirror), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Choose Mirror Folder…", action: #selector(chooseMirror), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Voice: press \u{2303}\u{2325}Space", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(withTitle: "Start Listening", action: #selector(startListening), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Recentre on Notch", action: #selector(reposition), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Test Call Banner", action: #selector(testCall), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    @objc private func openVault() {
        model.show(face: .vault)
        model.expand()
    }

    @objc private func revealMirror() {
        NSWorkspace.shared.activateFileViewerSelecting([model.mirror.rootURL])
    }

    @objc private func chooseMirror() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Mirror Here"
        panel.directoryURL = model.mirror.rootURL

        if panel.runModal() == .OK, let url = panel.url {
            Config.shared.mirrorRoot = url
            model.selectedFolder = nil
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func startListening() {
        model.voice.toggle()
    }

    @objc private func reposition() {
        windowController.reposition()
    }

    @objc private func testCall() {
        model.calls.present(CallEvent(
            id: UUID(),
            displayName: "Test Caller",
            source: "FaceTime",
            phase: .incoming,
            startedAt: Date()
        ))
    }

    /// Writes to a file as well as stdout, because this has to be launched with
    /// `open` to be meaningful: exec'ing the binary from a shell makes the
    /// terminal the TCC *responsible process*, so macOS evaluates the terminal's
    /// calendar permission instead of the app's — and answers "denied" without
    /// ever prompting. Launched via LaunchServices the app is its own responsible
    /// process, but then stdout goes nowhere, hence the file.
    private static let checkReportPath = "/tmp/di-calendar-check.txt"

    private func runCalendarCheck() {
        var output: [String] = []
        let emit: (String) -> Void = { line in
            print(line)
            output.append(line)
        }

        emit("Requesting Calendar access — click Allow if macOS asks.")

        model.calendar.requestAccess { granted in
            if granted {
                for line in self.model.calendar.report() { emit(line) }
            } else {
                emit("Calendar access DENIED.")
                emit("Grant it in System Settings → Privacy & Security → Calendars,")
                emit("then run this check again.")
            }
            try? output.joined(separator: "\n")
                .write(toFile: Self.checkReportPath, atomically: true, encoding: .utf8)
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static let micReportPath = "/tmp/di-mic-check.txt"

    /// Opens the mic for a couple of seconds and reports whether audio actually
    /// flows. Buffers arrive even in a silent room, so a non-zero count proves the
    /// engine bound to a real input device — which is precisely the failure that
    /// made every transcript come back empty.
    private func runMicCheck() {
        var output: [String] = []
        let emit: (String) -> Void = { print($0); output.append($0) }
        let finish: () -> Void = {
            try? output.joined(separator: "\n")
                .write(toFile: Self.micReportPath, atomically: true, encoding: .utf8)
            fflush(stdout)
            NSApp.terminate(nil)
        }

        let speech = model.voice.speech
        emit("Requesting Microphone + Speech Recognition — click Allow if asked.")

        speech.requestAuthorization { granted, message in
            guard granted else {
                emit("DENIED: \(message ?? "unknown")")
                emit("Grant both in System Settings → Privacy & Security.")
                finish()
                return
            }
            emit("Both granted. Opening the microphone for 2.5s — you can stay silent.")
            speech.start()

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                emit("")
                emit("input device : \(speech.inputDescription ?? "none bound")")
                emit("buffers      : \(speech.bufferCount)")
                emit(String(format: "peak level   : %.3f", speech.peakLevel))
                emit("")
                if speech.bufferCount == 0 {
                    emit("FAIL: no audio reached the tap — the engine is not bound to an input.")
                } else if speech.peakLevel < 0.01 {
                    emit("Audio is flowing, but it was essentially silent.")
                    emit("That is expected if you said nothing. Check System Settings →")
                    emit("Sound → Input shows level when you speak.")
                } else {
                    emit("PASS: audio is flowing and the mic is picking up sound.")
                }
                speech.reset()
                finish()
            }
        }
    }

    // MARK: - URL scheme (dynamicisland://call?...)

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        model.calls.handle(url: url)
    }
}
