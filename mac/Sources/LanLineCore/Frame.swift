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
    /// In hello / hello_ok (beta.6+): what this side can do. Absent = beta.5. "sha_end": the SHA-256 may come in
    /// file_end, so file_begin goes out without hashing first; "folders": folder_begin / mkdir / folder_end.
    public var caps: [String]?
    /// file_begin and mkdir inside a folder: the folder item's id, and the "/"-separated path inside it.
    public var folder: String?
    public var path: String?
    /// folder_begin: how many files follow.
    public var count: Int?
    /// "version" (encrypted, both ways, beta.6+): this side's version, and the newest version it knows of.
    public var version: String?
    public var latestKnown: LatestKnown?
    /// hello / hello_ok (beta.7+): this computer's device id, so a partner can be recognised after it moves.
    public var device: String?
    /// `clip` (beta.10, "clip" cap): a picture from the other computer's clipboard, PNG, base64.
    public var png: String?
    /// beta.10 ("resume" cap): `file_begin` with `resume: true` offers to continue an interrupted file; the receiver
    /// answers `resume` with the `offset` it already has (0 = from the start).
    public var resume: Bool?
    public var offset: Int64?

    public struct LatestKnown: Codable, Sendable, Equatable {
        public var version: String
        public var url: String
        public init(version: String, url: String) { self.version = version; self.url = url }
    }

    enum CodingKeys: String, CodingKey {
        case type, v, token, name, id, text, size, sha256, ok, err, rekey, addrs, nonce, epk, mac, caps, folder, path, count, version, device, png, resume, offset
        case latestKnown = "latest_known"
    }

    public init(type: String, v: Int? = nil, token: String? = nil, name: String? = nil, id: String? = nil,
                text: String? = nil, size: Int64? = nil, sha256: String? = nil, ok: Bool? = nil, err: String? = nil,
                rekey: String? = nil, addrs: [String]? = nil, nonce: String? = nil, epk: String? = nil, mac: String? = nil,
                caps: [String]? = nil, folder: String? = nil, path: String? = nil, count: Int? = nil) {
        self.type = type; self.v = v; self.token = token; self.name = name; self.id = id
        self.text = text; self.size = size; self.sha256 = sha256; self.ok = ok; self.err = err; self.rekey = rekey
        self.addrs = addrs; self.nonce = nonce; self.epk = epk; self.mac = mac
        self.caps = caps; self.folder = folder; self.path = path; self.count = count
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
    /// `sha256` nil = it comes in file_end (peer has "sha_end").
    public static func fileBegin(id: String, name: String, size: Int64, sha256: String?, folder: String? = nil, path: String? = nil) -> Frame {
        Frame(type: "file_begin", name: name, id: id, size: size, sha256: sha256, folder: folder, path: path)
    }
    /// The answer to a resumable `file_begin`: carry on from this byte.
    public static func resumeAt(id: String, offset: Int64) -> Frame { var f = Frame(type: "resume", id: id); f.offset = offset; return f }
    public static func fileEnd(id: String, sha256: String? = nil) -> Frame { Frame(type: "file_end", id: id, sha256: sha256) }
    public static func folderBegin(id: String, name: String, count: Int, size: Int64) -> Frame {
        Frame(type: "folder_begin", name: name, id: id, size: size, count: count)
    }
    public static func mkdir(folder: String, path: String) -> Frame { Frame(type: "mkdir", folder: folder, path: path) }
    public static func folderEnd(id: String) -> Frame { Frame(type: "folder_end", id: id) }
    /// beta.10 ("cancel" cap): the sender stopped this file or folder; the receiver deletes what arrived.
    public static func cancel(id: String) -> Frame { Frame(type: "cancel", id: id) }
    public static func versionInfo(_ own: String, latest: LatestKnown?) -> Frame {
        var f = Frame(type: "version"); f.version = own; f.latestKnown = latest; return f
    }
    public static func ack(id: String, ok: Bool, err: String? = nil) -> Frame { Frame(type: "ack", id: id, ok: ok, err: err) }
    public static let beat = Frame(type: "beat")
    /// beta.10 ("clip" cap): the sender's clipboard changed. Text or a PNG; may come between file chunks like `ack`.
    public static func clip(_ c: ClipContent) -> Frame {
        var f = Frame(type: "clip", id: UUID().uuidString)
        switch c { case .text(let t): f.text = t; case .png(let d): f.png = d.base64EncodedString() }
        return f
    }

    public var json: String {
        // Encoding a struct of strings, numbers and bools cannot fail.
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public static func decode(_ s: String) -> Frame? {
        try? JSONDecoder().decode(Frame.self, from: Data(s.utf8))
    }
}
