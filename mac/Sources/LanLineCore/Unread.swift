/// Items that arrived while Lan-Line wasn't the window in use (beta.10). Shown as the Dock badge and a dot on the
/// menu bar icon (Windows: the taskbar overlay and the tray icon); cleared when the window is used again.
/// The same rules on Windows (`Unread` in LanLine.Core).
public struct Unread: Equatable, Sendable {
    public private(set) var count = 0
    public init() {}

    /// Something arrived; `inUse` = the user has Lan-Line in front, so it was seen straight away.
    public mutating func arrived(inUse: Bool) { if !inUse { count += 1 } }
    public mutating func seen() { count = 0 }

    /// The badge text: nil for none, "1"…"99", then "99+".
    public var badge: String? { count == 0 ? nil : count > 99 ? "99+" : String(count) }
    /// "3 new" for tooltips and the menu, nil for none.
    public var phrase: String? { count == 0 ? nil : "\(badge!) new" }
}
