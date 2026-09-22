import AppKit
import ApplicationServices

/// Puts dictated text into whatever the user is actually typing into.
///
/// **There is no way to do this without Accessibility.** Any mechanism that puts
/// characters into another application's text field — synthetic keystrokes, a
/// scripted ⌘V, or writing through the accessibility tree — is gated behind
/// `AXIsProcessTrusted()`. That is the whole point of the permission, and a tool
/// that types into your banking app should require it.
///
/// So the behaviour is split honestly:
///
/// - **Trusted** → the text is typed straight into the focused field.
/// - **Not trusted** → the text goes to the clipboard and the island says so, so
///   dictation is still useful with zero permissions; you just press ⌘V yourself.
///
/// Typing is done with `keyboardSetUnicodeString` rather than the more common
/// clipboard-and-paste trick. Pasting means clobbering whatever the user had
/// copied, and restoring it afterwards is unreliable once images, file promises
/// or multiple representations are involved. Synthesising the characters leaves
/// the clipboard completely untouched.
final class TextInserter {

    enum Outcome: Equatable {
        case typed(characters: Int)
        case copiedToClipboard
        case empty
    }

    /// Whether the app may synthesise input. Queried, never assumed.
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt. Only call in response to the
    /// user doing something — it opens System Settings.
    func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Inserts `text` wherever the keyboard focus currently is.
    ///
    /// Completion fires on the main thread. Typing happens off it: the pacing
    /// between chunks is a real sleep, and doing that on the main thread would
    /// stall the island's animation for the length of the dictation.
    func insert(_ text: String, completion: @escaping (Outcome) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.empty)
            return
        }

        guard isTrusted else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmed, forType: .string)
            Log.debug("insert: not trusted — copied \(trimmed.count) chars instead")
            completion(.copiedToClipboard)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            Self.typeUnicode(trimmed)
            Log.debug("insert: typed \(trimmed.count) chars")
            DispatchQueue.main.async { completion(.typed(characters: trimmed.count)) }
        }
    }

    // MARK: - Synthetic typing

    /// Longest run of UTF-16 units to attach to a single synthetic event.
    ///
    /// `keyboardSetUnicodeString` accepts more, but long strings are silently
    /// truncated or dropped by some receivers, so the text is fed through in
    /// small runs with a brief gap for the target app to consume them.
    private static let chunkSize = 16
    private static let chunkGap: UInt32 = 1_800   // microseconds

    private static func typeUnicode(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let units = Array(text.utf16)
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            // virtualKey 0 with a unicode payload: the keycode is ignored and the
            // string is delivered verbatim, so layout and dead keys don't mangle it.
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.post(tap: .cghidEventTap)
            }

            index = end
            usleep(chunkGap)
        }
    }
}
