import AppKit
import Carbon.HIToolbox
import LanLineCore

/// System-wide shortcuts (beta.10) through Carbon's RegisterEventHotKey: no Accessibility or Input Monitoring
/// permission, and macOS delivers only our own combinations (never other keystrokes).
@MainActor
final class HotKeys {
    enum Slot: UInt32 { case show = 1, send = 2 }

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var actions: [Slot: () -> Void] = [:]
    private var handler: EventHandlerRef?
    nonisolated(unsafe) private static weak var current: HotKeys?

    init() {
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, let slot = Slot(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.current?.actions[slot]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Register (or clear, with nil) one slot. Returns why it couldn't be registered, nil when it worked.
    @discardableResult
    func set(_ slot: Slot, _ shortcut: Shortcut?, action: @escaping () -> Void) -> String? {
        if let r = refs.removeValue(forKey: slot) { UnregisterEventHotKey(r) }
        actions[slot] = action
        guard let s = shortcut else { return nil }
        if let p = s.problem(mac: true) { return p }
        guard let code = Self.keyCodes[s.key] else { return "That key can't be used." }
        var mods: UInt32 = 0
        if s.cmd { mods |= UInt32(cmdKey) }
        if s.alt { mods |= UInt32(optionKey) }
        if s.ctrl { mods |= UInt32(controlKey) }
        if s.shift { mods |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: OSType(0x4C4C_4E45), id: slot.rawValue),   // 'LLNE'
                                      GetApplicationEventTarget(), 0, &ref)
        guard err == noErr, let ref else {
            return err == OSStatus(eventHotKeyExistsErr) ? "\(s.display(mac: true)) is taken by another app." : "macOS refused \(s.display(mac: true)) (\(err))."
        }
        refs[slot] = ref
        return nil
    }

    /// Virtual key codes (physical keys, as on a US layout) for the keys a Shortcut may use.
    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G,
            "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N,
            "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U,
            "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "Space": kVK_Space,
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, c) in f.enumerated() { m["F\(i + 1)"] = c }
        return m
    }()

    /// A key press in the shortcut recorder → a Shortcut (nil for keys a shortcut can't use).
    static func shortcut(from e: NSEvent) -> Shortcut? {
        guard let key = keyCodes.first(where: { $0.value == Int(e.keyCode) })?.key else { return nil }
        let f = e.modifierFlags
        return Shortcut(ctrl: f.contains(.control), alt: f.contains(.option), shift: f.contains(.shift), cmd: f.contains(.command), key: key)
    }
}
