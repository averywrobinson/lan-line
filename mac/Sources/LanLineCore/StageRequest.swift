import Foundation

/// A request to stage items in the window: `lanline://stage?p=<absolute path>&…&t=<text>&…`, sent by the Share
/// extension (Finder → Share → Lan-Line). Staging never sends anything: the user sees the items above the message
/// box, can remove them, and presses Send. Parsed strictly: only existing absolute paths, bounded counts and sizes.
public struct StageRequest: Sendable, Equatable {
    public static let maxPaths = 200, maxTexts = 20, maxText = 100_000

    public var paths: [String]
    public var texts: [String]

    public init(paths: [String], texts: [String]) { self.paths = paths; self.texts = texts }

    public init?(url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        guard url.scheme?.lowercased() == "lanline", url.host?.lowercased() == "stage",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var p: [String] = [], t: [String] = []
        for q in items {
            guard let v = q.value, !v.isEmpty, !v.contains("\0") else { continue }
            switch q.name {
            case "p" where p.count < Self.maxPaths && v.hasPrefix("/") && !v.split(separator: "/").contains("..") && fileExists(v):
                if !p.contains(v) { p.append(v) }
            case "t" where t.count < Self.maxTexts && v.count <= Self.maxText:
                t.append(v)
            default: continue
            }
        }
        guard !(p.isEmpty && t.isEmpty) else { return nil }
        paths = p; texts = t
    }

    public var url: URL? {
        var c = URLComponents()
        c.scheme = "lanline"; c.host = "stage"
        c.queryItems = paths.map { URLQueryItem(name: "p", value: $0) } + texts.map { URLQueryItem(name: "t", value: $0) }
        return c.url
    }
}
