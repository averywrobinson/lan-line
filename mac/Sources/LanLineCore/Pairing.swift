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
