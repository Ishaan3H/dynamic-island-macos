import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = IslandModel()
    private var windowController: IslandWindowController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let hint = NSMenuItem(title: "Drag the pill (or the header) to move", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(withTitle: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
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

    @objc private func resetPosition() {
        windowController.resetPosition()
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
