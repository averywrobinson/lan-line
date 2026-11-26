import Foundation

/// One finished item in this computer's history (beta.10): what it was, which way, with whom, when, how it ended.
/// Kept in `history.jsonl` next to the settings (one JSON object per line), never sent anywhere.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var incoming: Bool
    /// "text", "file" or "folder".
    public var kind: String
    public var text: String?
    public var name: String?
    public var size: Int64?
    public var path: String?
    public var count: Int?
    public var at: Date
    /// The other computer's name (from / to); "everyone" for an item sent to several.
    public var who: String?
    /// "received", "delivered", "failed" or "cancelled".
    public var state: String
    public var error: String?

    public init(id: String, incoming: Bool, kind: String, text: String? = nil, name: String? = nil, size: Int64? = nil,
                path: String? = nil, count: Int? = nil, at: Date, who: String? = nil, state: String, error: String? = nil) {
        self.id = id; self.incoming = incoming; self.kind = kind; self.text = text; self.name = name; self.size = size
        self.path = path; self.count = count; self.at = at; self.who = who; self.state = state; self.error = error
    }
}

public enum HistoryFilter: String, CaseIterable, Sendable {
    case all, text, pictures, files, links
    public var title: String {
        switch self { case .all: "All"; case .text: "Text"; case .pictures: "Pictures"; case .files: "Files"; case .links: "Links" }
    }
}

public enum History {
    /// Most items kept; older ones drop off when the file is rewritten.
    public static let cap = 1000
    public static let fileName = "history.jsonl"
    /// Texts longer than this are kept cut (the copy in the window is whole while it is open).
    public static let maxText = 20_000

    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Oldest first, one per id (the last line wins), at most `cap`. Unreadable lines are skipped.
    public static func load(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = decoder()
        var byID: [String: HistoryEntry] = [:]
        var order: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let e = try? dec.decode(HistoryEntry.self, from: Data(line)) else { continue }
            if byID[e.id] == nil { order.append(e.id) }
            byID[e.id] = e
        }
        let all = order.compactMap { byID[$0] }.sorted { $0.at < $1.at }
        return Array(all.suffix(cap))
    }

    /// Add one entry at the end of the file (texts cut to `maxText`).
    public static func append(_ e: HistoryEntry, to url: URL) throws {
        var e = e
        if let t = e.text, t.count > maxText { e.text = String(t.prefix(maxText)) }
        var line = try encoder().encode(e)
        line.append(UInt8(ascii: "\n"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: [.atomic])
        }
    }

    /// Rewrite the file with just these entries (at launch, so it never grows past `cap` for long).
    public static func compact(_ entries: [HistoryEntry], to url: URL) throws {
        let enc = encoder()
        var d = Data()
        for e in entries.suffix(cap) { d.append(try enc.encode(e)); d.append(UInt8(ascii: "\n")) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: [.atomic])
    }

    public static func clear(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: search

    static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]

    public static func isPicture(_ e: HistoryEntry) -> Bool {
        e.kind == "file" && pictureExtensions.contains(((e.name ?? "") as NSString).pathExtension.lowercased())
    }

    public static func isLink(_ e: HistoryEntry) -> Bool {
        guard e.kind == "text", let t = e.text else { return false }
        return t.range(of: #"(?i)\bhttps?://\S+|\bwww\.[a-z0-9-]+\.[a-z]{2,}\S*"#, options: .regularExpression) != nil
    }

    /// Lower case, accents removed: "Résumé" → "resume".
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Every word of the query must appear in the text, file name or computer name (any order).
    public static func matches(_ e: HistoryEntry, query: String, filter: HistoryFilter) -> Bool {
        switch filter {
        case .all: break
        case .text: guard e.kind == "text" else { return false }
        case .pictures: guard isPicture(e) else { return false }
        case .files: guard e.kind == "file" || e.kind == "folder" else { return false }
        case .links: guard isLink(e) else { return false }
        }
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = fold([e.text, e.name, e.who].compactMap { $0 }.joined(separator: " "))
        return words.allSatisfy { hay.contains($0) }
    }
}
