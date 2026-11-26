import Foundation

/// What a system notification about arrived items says (beta.10). Pure, so the Mac and Windows apps word it the
/// same way and the tests pin it (`ArrivalNoticeTests` / the PC's "arrival notices"). The apps decide *when* to
/// post (only while Lan-Line isn't the window in use) and do the posting.
public struct ArrivalNotice: Equatable, Sendable {
    public enum Action: String, Sendable, Equatable { case copy, open, reveal }

    public var title: String
    public var body: String
    /// Buttons, in order. The notification itself always means "show Lan-Line".
    public var actions: [Action]
    /// The item the buttons act on; nil for a summary of several items.
    public var itemID: String?
    /// A received picture to show in the notification.
    public var imagePath: String?

    public init(title: String, body: String, actions: [Action] = [], itemID: String? = nil, imagePath: String? = nil) {
        self.title = title; self.body = body; self.actions = actions; self.itemID = itemID; self.imagePath = imagePath
    }
}

public enum ArrivalNotices {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    /// Longest text preview, in characters (an ellipsis is added when cut).
    public static let maxPreview = 160
    /// Arrivals this close together become one notification.
    public static let coalesceSeconds = 0.8

    /// One notification for everything that arrived in one short burst (`from` = the sender's name), in arrival
    /// order. nil when there is nothing to say.
    public static func make(_ arrivals: [(from: String, item: Item)]) -> ArrivalNotice? {
        guard let first = arrivals.first else { return nil }
        if arrivals.count == 1 { return single(from: first.from, first.item) }
        var senders: [String] = []
        for a in arrivals where !senders.contains(a.from) { senders.append(a.from) }
        var files = 0, folders = 0, texts = 0
        for a in arrivals {
            switch a.item.kind {
            case .file: files += 1
            case .folder: folders += 1
            case .text: texts += 1
            }
        }
        var parts: [String] = []
        if files > 0 { parts.append(count(files, "file")) }
        if folders > 0 { parts.append(count(folders, "folder")) }
        if texts > 0 { parts.append(count(texts, "message")) }
        let what = list(parts)
        if senders.count == 1 { return ArrivalNotice(title: senders[0], body: "Sent you \(what)") }
        return ArrivalNotice(title: "Lan-Line", body: "\(capitalized(what)) from \(list(senders))")
    }

    /// An incoming item that could not be saved.
    public static func failed(from: String, name: String, reason: String) -> ArrivalNotice {
        ArrivalNotice(title: "Couldn't receive \(name)", body: "From \(from): \(reason)")
    }

    static func single(from: String, _ item: Item) -> ArrivalNotice {
        switch item.kind {
        case .text(let t):
            return ArrivalNotice(title: from, body: preview(t), actions: [.copy], itemID: item.id)
        case .file(let name, let size, let url):
            let ext = (name as NSString).pathExtension.lowercased()
            return ArrivalNotice(title: from, body: "\(name) · \(Cleanup.formatBytes(size))", actions: [.open, .reveal],
                                 itemID: item.id, imagePath: imageExtensions.contains(ext) ? url.path : nil)
        case .folder(let name, let n, let size, _):
            return ArrivalNotice(title: from, body: "\(name) · \(count(n, "file")), \(Cleanup.formatBytes(size))",
                                 actions: [.open, .reveal], itemID: item.id)
        }
    }

    /// Whitespace runs (newlines included) become one space; long texts are cut at a word with "…".
    public static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if flat.isEmpty { return "(empty message)" }
        guard flat.count > maxPreview else { return flat }
        var cut = String(flat.prefix(maxPreview))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxPreview * 2 / 3 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "a", "a and b", "a, b and c".
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
