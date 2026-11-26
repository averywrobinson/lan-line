import Foundation

/// The welcome tour and the empty window's hints (beta.10). Three cards, shown once on a new install after pairing
/// and the first-run settings; never automatically for someone who was already paired before the tour existed.
/// The wording lives here so the Mac, Windows and iPhone apps say the same things in their own platform's terms.
public struct TourCard: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public init(id: String, title: String, body: String) { self.id = id; self.title = title; self.body = body }
}

public struct TourHint: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public enum Tour {
    public enum Platform: Sendable { case mac, windows, iphone }

    public static func cards(_ p: Platform) -> [TourCard] {
        switch p {
        case .mac: return [
            TourCard(id: "send", title: "Send anything",
                     body: "Type and press Return, paste, or drop files and folders on the window. They arrive on your other computer a moment later, encrypted end to end."),
            TourCard(id: "anywhere", title: "From anywhere",
                     body: "Share from Finder, or drop files on Lan-Line's Dock or menu bar icon. In Settings you can set a shortcut that sends the clipboard from any app."),
            TourCard(id: "close", title: "Always close by",
                     body: "Pin the window on top, or close it: Lan-Line stays in the menu bar and tells you when something arrives."),
        ]
        case .windows: return [
            TourCard(id: "send", title: "Send anything",
                     body: "Type and press Enter, paste, or drop files and folders on the window. They arrive on your other computer a moment later, encrypted end to end."),
            TourCard(id: "anywhere", title: "From anywhere",
                     body: "Right-click a file and choose Send to › Lan-Line. In Settings you can set a shortcut that sends the clipboard from any app."),
            TourCard(id: "close", title: "Always close by",
                     body: "Pin the window on top, or close it: Lan-Line stays in the notification area and tells you when something arrives."),
        ]
        case .iphone: return [
            TourCard(id: "send", title: "Send anything",
                     body: "Type a message, or tap + for photos, videos and files. They arrive on your computer a moment later, encrypted end to end."),
            TourCard(id: "anywhere", title: "Everything in one place",
                     body: "What your computers send appears here. Tap to preview; touch and hold to copy, share or save to Photos."),
            TourCard(id: "close", title: "Open while you use it",
                     body: "iPhone lets Lan-Line receive while it's open. Leave it open for big transfers."),
        ]
        }
    }

    /// The three lines under "Drop here. Grab there." while the window is empty.
    public static func hints(_ p: Platform) -> [TourHint] {
        switch p {
        case .mac: return [
            TourHint(id: "type", text: "Type or paste, then press Return"),
            TourHint(id: "drop", text: "Drop files or folders anywhere in this window"),
            TourHint(id: "share", text: "Or share from Finder to Lan-Line"),
        ]
        case .windows: return [
            TourHint(id: "type", text: "Type or paste, then press Enter"),
            TourHint(id: "drop", text: "Drop files or folders anywhere in this window"),
            TourHint(id: "share", text: "Or right-click a file: Send to › Lan-Line"),
        ]
        case .iphone: return [
            TourHint(id: "type", text: "Type a message"),
            TourHint(id: "drop", text: "Tap + for photos, videos and files"),
            TourHint(id: "share", text: "What your computers send appears here"),
        ]
        }
    }

    /// Show it now? Only when it was never seen, a computer is paired, and the first-run settings are saved.
    public static func shouldShow(seen: Bool?, paired: Bool, settingsConfirmed: Bool) -> Bool {
        seen == nil && paired && settingsConfirmed
    }

    /// At launch: someone already paired before the tour existed has nothing to be welcomed to.
    public static func seenAtLaunch(saved: Bool?, alreadyPaired: Bool) -> Bool? {
        saved ?? (alreadyPaired ? true : nil)
    }
}
