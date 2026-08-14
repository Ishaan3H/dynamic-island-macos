import AppKit
import Carbon.HIToolbox

/// Global hotkey for the voice assistant: ⌃⌥Space.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor,
/// and that choice is load-bearing. A global *keyboard* monitor requires an Input
/// Monitoring / Accessibility grant; `RegisterEventHotKey` requires **nothing**.
///
/// The cost is that Carbon cannot register a bare modifier chord — a hotkey needs
/// a real key. So ⌃⌥ alone would mean going back to an event monitor and asking
/// the user for Accessibility. ⌃⌥Space avoids that entirely, and has the side
/// benefit of not firing every time ⌃⌥ is pressed as the prefix of some other
/// shortcut.
final class HotkeyService {

    /// Fired on the main thread each time the chord is pressed.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Four-char code identifying our hotkey to Carbon: 'ISLD'.
    private static let signature: OSType = 0x49_53_4C_44

    @discardableResult
    func register() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return noErr }

                // Confirm it's ours before acting — other hotkeys route here too.
                var pressedID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressedID
                )
                guard pressedID.signature == HotkeyService.signature else { return noErr }

                let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { service.onTrigger?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            Log.debug("hotkey: InstallEventHandler failed (\(installStatus))")
            return false
        }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            Log.debug("hotkey: ⌃⌥Space registered")
            return true
        }
        // -9868 (eventHotKeyExistsErr) means something else already owns it.
        Log.debug("hotkey: RegisterEventHotKey failed (\(status)) — chord may be taken")
        return false
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit { unregister() }
}
