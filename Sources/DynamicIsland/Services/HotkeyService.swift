import AppKit
import Carbon.HIToolbox

/// Global hotkeys, via Carbon's `RegisterEventHotKey`.
///
/// Chosen over an `NSEvent` global monitor for one reason: a global *keyboard*
/// monitor requires an Input Monitoring / Accessibility grant, and
/// `RegisterEventHotKey` requires **nothing**.
///
/// The cost is that Carbon cannot register a bare modifier chord — a hotkey needs
/// a real key. That is why both shortcuts here include one, rather than being
/// modifier-only combinations in the style of other dictation tools.
final class HotkeyService {

    /// One registered chord.
    struct Chord {
        let key: Int
        let modifiers: Int
        let handler: () -> Void

        static func controlOption(_ key: Int, _ handler: @escaping () -> Void) -> Chord {
            Chord(key: key, modifiers: controlKey | optionKey, handler: handler)
        }
    }

    /// Four-char code identifying our hotkeys to Carbon: 'ISLD'.
    private static let signature: OSType = 0x49_53_4C_44

    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Installs the shared Carbon handler once, then registers each chord.
    /// Returns the chords that could not be claimed — usually because another app
    /// already owns them.
    @discardableResult
    func register(_ chords: [Chord]) -> [Chord] {
        installHandlerIfNeeded()

        var failed: [Chord] = []
        for chord in chords {
            let id = nextID
            nextID += 1

            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(chord.key),
                UInt32(chord.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr {
                handlers[id] = chord.handler
                refs.append(ref)
                Log.debug("hotkey: registered id=\(id) key=\(chord.key)")
            } else {
                // -9868 (eventHotKeyExistsErr) means something else owns it.
                Log.debug("hotkey: could not register key \(chord.key) (status \(status))")
                failed.append(chord)
            }
        }
        return failed
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return noErr }

                var pressed = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                guard pressed.signature == HotkeyService.signature else { return noErr }

                let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
                // Dispatch by id — every hotkey in the app routes through this one
                // handler, so it has to know which chord actually fired.
                if let handler = service.handlers[pressed.id] {
                    DispatchQueue.main.async(execute: handler)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    func unregister() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    deinit { unregister() }
}
