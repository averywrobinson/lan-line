/// A keyboard shortcut Lan-Line listens for everywhere (beta.10): "show/hide Lan-Line" and "send the clipboard".
/// Saved as text, `"ctrl+alt+L"` (modifiers in that fixed order, then the key), the same on Mac and Windows, so one
/// rule set (here and `Shortcut` in LanLine.Core) decides what is valid and how it reads.
public struct Shortcut: Equatable, Hashable, Sendable {
    public var ctrl = false, alt = false, shift = false, cmd = false
    /// "A"…"Z", "0"…"9", "Space", "F1"…"F12".
    public var key: String

    public init(ctrl: Bool = false, alt: Bool = false, shift: Bool = false, cmd: Bool = false, key: String) {
        self.ctrl = ctrl; self.alt = alt; self.shift = shift; self.cmd = cmd; self.key = key
    }

    public static let defaultShow = Shortcut(ctrl: true, alt: true, key: "L")
    /// Offered in Settings for "send the clipboard"; that one is off until the user picks a key.
    public static let suggestedSend = Shortcut(ctrl: true, alt: true, key: "V")

    static let keys: Set<String> = Set((65...90).map { String(UnicodeScalar(UInt8($0))) } + (0...9).map(String.init)
                                       + ["Space"] + (1...12).map { "F\($0)" })

    /// "ctrl+alt+L"; nil for anything else (unknown key, no key, repeats, wrong order is fine).
    public init?(_ text: String) {
        var s = Shortcut(key: "")
        for raw in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch raw.lowercased() {
            case "ctrl", "control": s.ctrl = true
            case "alt", "option": s.alt = true
            case "shift": s.shift = true
            case "cmd", "command": s.cmd = true
            default:
                guard s.key.isEmpty else { return nil }
                let k = raw.count == 1 ? raw.uppercased() : raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
                guard Self.keys.contains(k) else { return nil }
                s.key = k
            }
        }
        guard !s.key.isEmpty else { return nil }
        self = s
    }

    public var text: String {
        ([ctrl ? "ctrl" : nil, alt ? "alt" : nil, shift ? "shift" : nil, cmd ? "cmd" : nil].compactMap { $0 } + [key]).joined(separator: "+")
    }

    /// "⌃⌥L" on the Mac, "Ctrl+Alt+L" on Windows.
    public func display(mac: Bool) -> String {
        if mac { return (ctrl ? "⌃" : "") + (alt ? "⌥" : "") + (shift ? "⇧" : "") + (cmd ? "⌘" : "") + (key == "Space" ? "Space" : key) }
        return ([ctrl ? "Ctrl" : nil, alt ? "Alt" : nil, shift ? "Shift" : nil].compactMap { $0 } + [key]).joined(separator: "+")
    }

    /// Why this can't be a global shortcut on this platform; nil = fine.
    public func problem(mac: Bool) -> String? {
        if !mac, cmd { return "Windows has no ⌘ key." }
        if !(ctrl || alt || cmd) { return "Use Ctrl\(mac ? ", ⌥ or ⌘" : " or Alt") with the key, so normal typing isn't caught." }
        let only: (Bool, Bool, Bool, Bool) = (ctrl, alt, shift, cmd)
        if mac {
            if only == (false, false, false, true), ["Q", "W", "H", "M", "C", "V", "X", "Z", "A", "S", "F", "P", "N", "O", "T", "Space"].contains(key) {
                return "⌘\(key) is used by every app."
            }
            if only == (true, false, false, false), key == "Space" { return "⌃Space switches the keyboard language." }
            if only == (false, true, false, true), key == "Space" { return "⌥⌘Space opens Finder search." }
        } else {
            if only == (true, false, false, false), ["A", "C", "V", "X", "Z", "Y", "S", "F", "P", "N", "O", "W", "T"].contains(key) {
                return "Ctrl+\(key) is used by every app."
            }
            if only == (false, true, false, false), key == "F4" || key == "Space" { return "Alt+\(key) is used by Windows." }
        }
        return nil
    }
}

/// The in-window shortcuts, for the "Keyboard Shortcuts" list (⌘/ or Ctrl+/) (beta.10). The same rows on both
/// platforms, in each one's spelling.
public enum KeyboardHelp {
    public struct Row: Equatable, Sendable { public let keys: String; public let action: String }

    public static func rows(mac: Bool, show: Shortcut?, send: Shortcut?) -> [(section: String, rows: [Row])] {
        func k(_ m: String, _ w: String) -> String { mac ? m : w }
        var global: [Row] = []
        global.append(Row(keys: show?.display(mac: mac) ?? "Off (Settings)", action: "Show or hide Lan-Line, from any app"))
        global.append(Row(keys: send?.display(mac: mac) ?? "Off (Settings)", action: "Send what's on the clipboard"))
        return [
            ("Anywhere", global),
            ("Sending", [
                Row(keys: k("Return", "Enter"), action: "Send"),
                Row(keys: k("⇧Return", "Shift+Enter"), action: "New line"),
                Row(keys: k("⌘V", "Ctrl+V"), action: "Paste text, a picture or files (sends them)"),
                Row(keys: k("⌘O", "Ctrl+O"), action: "Send files…"),
                Row(keys: k("⌘L", "Ctrl+L"), action: "Go to the message box"),
            ]),
            ("Items", [
                Row(keys: k("⌘F", "Ctrl+F"), action: "Search the history"),
                Row(keys: k("⌘↑", "Ctrl+↑"), action: "From the message box: select the newest item"),
                Row(keys: "↑ ↓", action: "Select the item above or below"),
                Row(keys: "Space", action: "Preview the selected file"),
                Row(keys: k("Return", "Enter"), action: "Open the selected file"),
                Row(keys: k("⌘C", "Ctrl+C"), action: "Copy the selected item"),
                Row(keys: k("⌘⇧R", "Ctrl+Shift+R"), action: k("Show the file in Finder", "Show the file in its folder")),
                Row(keys: k("⌫", "Delete"), action: "Cancel a transfer, or remove the item from the list"),
                Row(keys: "Esc", action: "Back to the message box"),
            ]),
            ("Window", [
                Row(keys: k("⌘P", "Ctrl+P"), action: "Keep on top"),
                Row(keys: k("⌘,", "Ctrl+,"), action: "Settings"),
                Row(keys: k("⌘/", "Ctrl+/"), action: "This list"),
            ]),
        ]
    }
}
