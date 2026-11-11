import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut (Carbon hot keys need no Accessibility permission).
@MainActor
public final class Hotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// - Parameters: `key` is a virtual key code (kVK_…), `modifiers` Carbon flags (cmdKey | shiftKey).
    public init(key: Int, modifiers: Int, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let id = pressed.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x4652_4459, id: id),
                            GetApplicationEventTarget(), 0, &reference)
    }

    /// Pause listening: ⇧⌘M.
    public static func pause(_ action: @escaping () -> Void) -> Hotkey {
        Hotkey(key: kVK_ANSI_M, modifiers: cmdKey | shiftKey, action: action)
    }
}
