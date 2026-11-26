import Foundation

/// What a text item is, beyond plain words (beta.10, polish item 13): a one-time code, a colour, code, a link.
/// Pure, so both apps read messages the same way (`SmartText` in LanLine.Core, same cases).
public struct SmartColor: Equatable, Sendable {
    public var r: Int, g: Int, b: Int
    public var a: Double
    public init(r: Int, g: Int, b: Int, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) + (a < 1 ? String(format: "%02X", Int((a * 255).rounded())) : "") }
    public var rgb: String { a < 1 ? "rgba(\(r), \(g), \(b), \(SmartText.trim(a)))" : "rgb(\(r), \(g), \(b))" }
    public var hsl: String {
        let (h, s, l) = SmartText.toHSL(r, g, b)
        return a < 1 ? "hsla(\(h), \(s)%, \(l)%, \(SmartText.trim(a)))" : "hsl(\(h), \(s)%, \(l)%)"
    }
}

public struct SmartCode: Equatable, Sendable {
    /// What to copy: the code without fences.
    public var body: String
    /// The language named after an opening ``` fence, if any.
    public var language: String?
}

public struct SmartInfo: Equatable, Sendable {
    /// A one-time code to offer on its own ("482913").
    public var otp: String?
    /// The whole message is one colour.
    public var color: SmartColor?
    /// The message is code.
    public var code: SmartCode?
    /// The whole message is one link.
    public var singleLink: URL?
    /// Every http(s) link in the message, in order, without repeats (at most 5).
    public var links: [URL] = []
}

public enum SmartText {
    public static func analyze(_ text: String) -> SmartInfo {
        var info = SmartInfo()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 100_000 else { return info }
        info.code = code(t)
        if info.code == nil {
            info.otp = otp(t)
            info.color = color(t)
        }
        info.links = links(t)
        if info.code == nil, info.links.count == 1, !t.contains(where: \.isWhitespace) {
            func n(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }   // match Windows, where a bare host gets a "/"
            let only = n(info.links[0].absoluteString)
            if n(t) == only || n("https://" + t) == only || n("http://" + t) == only { info.singleLink = info.links[0] }
        }
        return info
    }

    // MARK: one-time codes

    static let otpWords = #"(?i)\b(code|passcode|otp|verification|verify|2fa|one[- ]time|security code|login|sign[- ]in|pin)\b"#

    /// "482913", "482 913", "482-913", "G-482913" on their own, or a 4–8 digit number in a message that says it's a code.
    public static func otp(_ t: String) -> String? {
        let digitsOnly = { (s: String) in s.filter(\.isNumber) }
        if let m = t.range(of: #"^(?:[A-Z]{1,3}-)?(\d{3}[ -]\d{3}|\d{4,8})$"#, options: .regularExpression) {
            return digitsOnly(String(t[m]).components(separatedBy: "-").count > 2 ? String(t[m]) : String(t[m].drop { !$0.isNumber }))
        }
        guard t.count <= 400, t.range(of: otpWords, options: .regularExpression) != nil,
              let m = t.range(of: #"(?<![\d.,:/])(?:[A-Z]{1,3}-)?(\d{3}[ -]\d{3}|\d{4,8})(?![\d/]|[.,:]\d)"#, options: .regularExpression) else { return nil }
        let raw = String(t[m])
        return digitsOnly(String(raw.drop { !$0.isNumber }))
    }

    // MARK: colours

    public static func color(_ t: String) -> SmartColor? {
        let s = t.lowercased().replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("#") {
            let h = Array(s.dropFirst())
            // ASCII only: Character.isHexDigit also says yes to fullwidth forms ("ｆｆｆ"), which don't parse.
            guard [3, 4, 6, 8].contains(h.count), h.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            let full = h.count <= 4 ? h.flatMap { [$0, $0] } : h
            let bytes = (0..<full.count / 2).compactMap { Int(String(full[$0 * 2...$0 * 2 + 1]), radix: 16) }
            guard bytes.count == full.count / 2 else { return nil }
            return SmartColor(r: bytes[0], g: bytes[1], b: bytes[2], a: bytes.count == 4 ? Double(bytes[3]) / 255 : 1)
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let fn = String(s[..<open])
        let parts = s[s.index(after: open)..<s.index(before: s.endIndex)].split(separator: ",").map(String.init)
        func num(_ p: String) -> Double? { Double(p.replacingOccurrences(of: "%", with: "")) }
        switch fn {
        case "rgb", "rgba":
            guard parts.count == (fn == "rgb" ? 3 : 4), let r = num(parts[0]), let g = num(parts[1]), let b = num(parts[2]),
                  [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
            let a = parts.count == 4 ? num(parts[3]) : 1
            guard let a, (0...1).contains(a) else { return nil }
            return SmartColor(r: Int(r), g: Int(g), b: Int(b), a: a)
        case "hsl", "hsla":
            guard parts.count == (fn == "hsl" ? 3 : 4), let h = num(parts[0]), let sat = num(parts[1]), let l = num(parts[2]),
                  (0...360).contains(h), (0...100).contains(sat), (0...100).contains(l) else { return nil }
            let a = parts.count == 4 ? num(parts[3]) : 1
            guard let a, (0...1).contains(a) else { return nil }
            let (r, g, b) = fromHSL(h, sat / 100, l / 100)
            return SmartColor(r: r, g: g, b: b, a: a)
        default: return nil
        }
    }

    static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> (Int, Int, Int) {
        let c = (1 - abs(2 * l - 1)) * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        func to255(_ v: Double) -> Int { Int(((v + m) * 255).rounded()) }
        return (to255(r1), to255(g1), to255(b1))
    }

    static func toHSL(_ r: Int, _ g: Int, _ b: Int) -> (Int, Int, Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), l = (mx + mn) / 2, d = mx - mn
        guard d > 0 else { return (0, 0, Int((l * 100).rounded())) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch mx {
        case rf: h = ((gf - bf) / d).truncatingRemainder(dividingBy: 6)
        case gf: h = (bf - rf) / d + 2
        default: h = (rf - gf) / d + 4
        }
        h *= 60; if h < 0 { h += 360 }
        return (Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    static func trim(_ a: Double) -> String {
        let s = String(format: "%.2f", a)
        return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    // MARK: code

    static let codeHints = #"^\s*(func |def |class |import |from \S+ import|return\b|let |var |const |public |private |#include|using |package |fn |SELECT |INSERT |UPDATE |CREATE |if \(|for \(|while \(|\$ |sudo |git |npm |pip |brew |cd |curl )"#

    /// Fenced (```lang … ```), or several lines that mostly look like code (indentation, braces, semicolons, keywords).
    public static func code(_ t: String) -> SmartCode? {
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            let lang = lines.removeFirst().dropFirst(3).trimmingCharacters(in: .whitespaces)
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            return SmartCode(body: lines.joined(separator: "\n"), language: lang.isEmpty ? nil : lang)
        }
        let lines = t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let codey = lines.filter { l in
            let s = l.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("  ") || l.hasPrefix("\t")
                || ["{", "}", ";", "};", ")", "]", "):", "=>", "->", "\\"].contains(where: { s.hasSuffix($0) })
                || s.range(of: codeHints, options: [.regularExpression, .caseInsensitive]) != nil
                || ["==", "!=", "=>", "::", "&&", "||", "</", "/>"].contains(where: { s.contains($0) })
        }.count
        // Prose ends sentences with full stops; code rarely does.
        let sentences = lines.filter { $0.trimmingCharacters(in: .whitespaces).range(of: #"[a-z][.!?]$"#, options: .regularExpression) != nil }.count
        guard codey >= 2, Double(codey) / Double(lines.count) >= 0.5, sentences * 2 < lines.count else { return nil }
        return SmartCode(body: t, language: nil)
    }

    // MARK: links

    public static func links(_ t: String) -> [URL] {
        guard let rx = try? NSRegularExpression(pattern: #"(?i)\b(?:https?://|www\.)[^\s<>"']+"#) else { return [] }
        var out: [URL] = []
        for m in rx.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t) else { continue }
            var s = String(t[r])
            while let last = s.last, ".,;:!?)]}'\"".contains(last) {   // trailing punctuation isn't part of the link
                if last == ")", s.filter({ $0 == "(" }).count >= s.filter({ $0 == ")" }).count { break }
                s.removeLast()
            }
            if s.lowercased().hasPrefix("www.") { s = "https://" + s }
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { continue }
            if !out.contains(u) { out.append(u) }
            if out.count == 5 { break }
        }
        return out
    }
}
