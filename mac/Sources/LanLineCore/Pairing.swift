import Foundation
import CryptoKit

/// The code one computer shows and the other types to pair. It doubles as the shared token.
/// 10 characters of Crockford base32 (50 bits), shown as `XXXXX-XXXXX`.
public enum PairCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in alphabet[Int(g.next(upperBound: UInt32(alphabet.count)))] })
    }

    /// What the user typed, in canonical form: upper case, separators dropped, look-alikes mapped
    /// (O→0, I/L→1). Nil unless it is exactly 10 code characters.
    public static func normalize(_ typed: String) -> String? {
        var out = ""
        for ch in typed.uppercased() {
            switch ch {
            case "-", " ", "\u{2013}", "\u{2014}", "\t": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        return out.count == 10 ? out : nil
    }

    public static func display(_ code: String) -> String {
        code.count == 10 ? "\(code.prefix(5))-\(code.suffix(5))" : code
    }

    /// A public tag for a pairing, so a computer can find its partner again after an address change
    /// without revealing the token. Short and one-way.
    public static func pairID(token: String) -> String {
        Data(SHA256.hash(data: Data("lan-line-pair:\(token)".utf8))).prefix(4).hex
    }
}

/// The pairing link a QR code carries (beta.10, for the iPhone companion): the code on screen, this computer's
/// name, port and addresses, `lanline://pair?v=1&c=7QK4M2XH9C&n=Studio%20PC&p=47830&h=192.168.1.20,100.64.0.5`.
/// It holds nothing the pairing screen doesn't already show, and is useless once that screen closes.
public struct PairLink: Equatable, Sendable {
    public var code: String
    public var name: String
    public var port: UInt16
    public var hosts: [String]

    public init(code: String, name: String, port: UInt16, hosts: [String]) {
        self.code = code; self.name = name; self.port = port; self.hosts = hosts
    }

    /// Values escaped to RFC 3986's unreserved characters (the same as .NET's EscapeDataString), so "Mac & PC" can't
    /// break the query and both apps write the same link.
    public var url: String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let n = String(name.prefix(40)).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return "lanline://pair?v=1&c=\(code)&n=\(n)&p=\(port)&h=\(hosts.prefix(4).joined(separator: ","))"
    }

    /// Is this an address a computer has on a home or office network (private, link-local, shared address space
    /// as VPNs like Tailscale use, or this device itself)? A pairing link that points anywhere else deserves a
    /// warning before the iPhone dials it.
    public static func isLocalNetworkAddress(_ host: String) -> Bool {
        let p = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard p.count == 4, Session.isIPv4(host) else { return false }
        switch (p[0], p[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    /// Every address in the link is on a local network.
    public var isLocal: Bool { hosts.allSatisfy(PairLink.isLocalNetworkAddress) }

    /// Strict: our scheme and host, version 1, a valid code, a port, at least one IPv4 address (8 at most).
    public static func parse(_ s: String) -> PairLink? {
        guard s.count <= 400, let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "lanline", c.host?.lowercased() == "pair" else { return nil }
        var q: [String: String] = [:]
        for i in c.queryItems ?? [] { if let v = i.value { q[i.name] = v } }
        guard q["v"] == "1", let code = q["c"].flatMap(PairCode.normalize), let port = q["p"].flatMap(UInt16.init), port > 0 else { return nil }
        let hosts = (q["h"] ?? "").split(separator: ",").map(String.init).filter(Session.isIPv4).prefix(8)
        guard !hosts.isEmpty else { return nil }
        let name = String((q["n"] ?? "").filter { ch in ch.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }.prefix(40))
        return PairLink(code: code, name: name.isEmpty ? "Computer" : name, port: port, hosts: Array(hosts))
    }
}
