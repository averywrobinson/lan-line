import Foundation

/// Link previews (beta.10, off unless turned on: fetching a page tells that website you looked). What a page says
/// about itself: Open Graph / Twitter tags, else <title>. Pure parsing; the apps fetch (≤ 512 KB, 5 s, http(s) only).
public struct LinkPreview: Equatable, Sendable {
    public var title: String?
    public var site: String?
    public var image: URL?

    public static let maxHTML = 512 * 1024
    public static let maxImage = 2_000_000
    public static let timeout: TimeInterval = 5

    public static func parse(html: String, base: URL) -> LinkPreview {
        var p = LinkPreview()
        func meta(_ key: String) -> String? {
            // <meta property="og:title" content="…"> in either attribute order
            let k = NSRegularExpression.escapedPattern(for: key)
            for pat in [#"<meta[^>]+(?:property|name)\s*=\s*["']"# + k + #"["'][^>]*content\s*=\s*["']([^"']*)["']"#,
                        #"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']"# + k + #"["']"#] {
                if let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                   let m = rx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range(at: 1), in: html) {
                    let v = decode(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { return v }
                }
            }
            return nil
        }
        p.title = meta("og:title") ?? meta("twitter:title")
        if p.title == nil, let rx = try? NSRegularExpression(pattern: #"<title[^>]*>([^<]{1,500})</title>"#, options: [.caseInsensitive]),
           let m = rx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(m.range(at: 1), in: html) {
            let v = decode(String(html[r])).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !v.isEmpty { p.title = v }
        }
        if let t = p.title, t.count > 200 { p.title = String(t.prefix(200)) + "…" }
        p.site = meta("og:site_name")
        if let img = meta("og:image") ?? meta("twitter:image"), let u = URL(string: img, relativeTo: base)?.absoluteURL,
           let s = u.scheme?.lowercased(), s == "http" || s == "https" { p.image = u }
        return p
    }

    /// The few HTML entities titles use.
    static func decode(_ s: String) -> String {
        var t = s
        for (k, v) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    /// "example.com" (without "www.") for the card.
    public static func host(_ u: URL) -> String {
        let h = u.host ?? u.absoluteString
        return h.lowercased().hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
