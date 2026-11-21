import Foundation

/// One JSON control frame (see PROTOCOL.md). Unused fields stay nil and are left out of the JSON.
public struct Frame: Codable, Sendable, Equatable {
    public var type: String
    public var v: Int?
    public var token: String?
    public var name: String?
    public var id: String?
    public var text: String?
    public var size: Int64?
    public var sha256: String?
    public var ok: Bool?
    public var err: String?
    /// v1 `hello_ok` (and v1 tests): the long-term secret. v2 sends it in an encrypted `rekey` frame (`token`).
    public var rekey: String?
    /// In an encrypted `addrs` frame: the listener's own addresses, the dialer's fallbacks.
    public var addrs: [String]?
    /// v2 handshake (ENCRYPTION.md): 32 random bytes, the ephemeral P-256 key (X9.63), the HMAC; all base64.
    public var nonce: String?
    public var epk: String?
    public var mac: String?

    public init(type: String, v: Int? = nil, token: String? = nil, name: String? = nil, id: String? = nil,
                text: String? = nil, size: Int64? = nil, sha256: String? = nil, ok: Bool? = nil, err: String? = nil,
                rekey: String? = nil, addrs: [String]? = nil, nonce: String? = nil, epk: String? = nil, mac: String? = nil) {
        self.type = type; self.v = v; self.token = token; self.name = name; self.id = id
        self.text = text; self.size = size; self.sha256 = sha256; self.ok = ok; self.err = err; self.rekey = rekey
        self.addrs = addrs; self.nonce = nonce; self.epk = epk; self.mac = mac
    }

    public static let protocolVersion = LL2.version

    /// A 0.9.0-beta.1…beta.4 (protocol v1) hello, with the secret in the clear. Only tests send it now.
    public static func legacyHello(token: String, name: String) -> Frame { Frame(type: "hello", v: 1, token: token, name: name, rekey: "?") }
    /// Sent in the clear to a v1 peer before closing, so it can say "update".
    public static let upgrade = Frame(type: "error", v: protocolVersion, err: "upgrade")
    /// Sent in the clear before closing on a hello whose MAC matches no secret.
    public static let refused = Frame(type: "error", v: protocolVersion, err: "auth")
    /// Encrypted, listener → dialer: the long-term secret that replaces the pairing code.
    public static func rekey(_ token: String) -> Frame { Frame(type: "rekey", token: token) }
    /// Encrypted, listener → dialer: the listener's own addresses (LAN, Tailscale…), the dialer's fallbacks.
    public static func addresses(_ a: [String]) -> Frame { Frame(type: "addrs", addrs: a) }
    public static func text(id: String, text: String) -> Frame { Frame(type: "text", id: id, text: text) }
    public static func fileBegin(id: String, name: String, size: Int64, sha256: String) -> Frame {
        Frame(type: "file_begin", name: name, id: id, size: size, sha256: sha256)
    }
    public static func fileEnd(id: String) -> Frame { Frame(type: "file_end", id: id) }
    public static func ack(id: String, ok: Bool, err: String? = nil) -> Frame { Frame(type: "ack", id: id, ok: ok, err: err) }
    public static let beat = Frame(type: "beat")

    public var json: String {
        // Encoding a struct of strings, numbers and bools cannot fail.
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public static func decode(_ s: String) -> Frame? {
        try? JSONDecoder().decode(Frame.self, from: Data(s.utf8))
    }
}
