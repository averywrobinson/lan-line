import Foundation
import CryptoKit

/// Protocol v2 encryption (ENCRYPTION.md): the shared secret authenticates a fresh P-256 ECDH per connection,
/// HKDF-SHA256 gives one AES-256-GCM key per direction, and every message after the handshake is sealed.
public enum LL2 {
    public static let version = 2
    static let macSalt = Data("lan-line/v2".utf8)

    /// 4-byte big-endian length, then the bytes.
    static func lp(_ d: Data) -> Data {
        var n = UInt32(d.count).bigEndian
        return Data(bytes: &n, count: 4) + d
    }

    public static func macKey(_ secret: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)), salt: macSalt,
                               info: Data("mac".utf8), outputByteCount: 32)
    }

    public static func t1(name: String, nonce: Data, epk: Data) -> Data {
        Data("LL2-HELLO".utf8) + lp(Data(name.utf8)) + nonce + epk
    }

    public static func t2(t1: Data, name: String, nonce: Data, epk: Data) -> Data {
        Data("LL2-OK".utf8) + t1 + lp(Data(name.utf8)) + nonce + epk
    }

    public static func mac(_ key: SymmetricKey, _ t: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: t, using: key)) }

    /// Constant time (CryptoKit compares the codes without early exit).
    public static func verify(_ key: SymmetricKey, _ t: Data, _ mac: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: t, using: key)
    }

    /// 64 bytes: dialer→listener key, then listener→dialer key.
    public static func sessionKeys(z: Data, secret: String, t2: Data) -> (d2l: Data, l2d: Data) {
        let salt = Data(SHA256.hash(data: Data(secret.utf8)))
        let info = Data("LL2-KEYS".utf8) + Data(SHA256.hash(data: t2))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: z), salt: salt, info: info, outputByteCount: 64)
        let all = okm.withUnsafeBytes { Data($0) }
        return (all.prefix(32), all.suffix(32))
    }

    public static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    static func z(_ priv: P256.KeyAgreement.PrivateKey, _ peer: Data) -> Data? {
        guard peer.count == 65, let pub = try? P256.KeyAgreement.PublicKey(x963Representation: peer),
              let s = try? priv.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        return s.withUnsafeBytes { Data($0) }
    }
}

/// The dialer's half of the handshake: make the hello, then check the listener's hello_ok.
public struct DialerHandshake: Sendable {
    let priv: P256.KeyAgreement.PrivateKey
    let nonce: Data
    let t1: Data
    let secret: String
    public let hello: Frame

    public init(secret: String, name: String, priv: P256.KeyAgreement.PrivateKey = .init(), nonce: Data = LL2.randomBytes(32)) {
        self.priv = priv; self.nonce = nonce; self.secret = secret
        let epk = priv.publicKey.x963Representation
        t1 = LL2.t1(name: name, nonce: nonce, epk: epk)
        hello = Frame(type: "hello", v: LL2.version, name: name, nonce: nonce.base64EncodedString(),
                      epk: epk.base64EncodedString(), mac: LL2.mac(LL2.macKey(secret), t1).base64EncodedString())
    }

    /// nil = the listener does not know our secret (or the reply was tampered with).
    public func finish(_ ok: Frame) -> Channel? {
        guard ok.type == "hello_ok", ok.v == LL2.version,
              let n = ok.nonce.flatMap({ Data(base64Encoded: $0) }), n.count == 32,
              let e = ok.epk.flatMap({ Data(base64Encoded: $0) }),
              let m = ok.mac.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        let t2 = LL2.t2(t1: t1, name: ok.name ?? "", nonce: n, epk: e)
        guard LL2.verify(LL2.macKey(secret), t2, m), let z = LL2.z(priv, e) else { return nil }
        let k = LL2.sessionKeys(z: z, secret: secret, t2: t2)
        return Channel(sendKey: k.d2l, recvKey: k.l2d)
    }
}

/// The listener's half: check a hello against the secrets it accepts and answer it.
public enum ListenerHandshake {
    public struct Answer: Sendable {
        public let ok: Frame
        public let channel: Channel
        /// Which of the offered secrets matched (0 = current, 1 = the previous one).
        public let secretIndex: Int
    }

    public static func answer(_ hello: Frame, secrets: [String], name: String,
                              priv: P256.KeyAgreement.PrivateKey = .init(), nonce: Data = LL2.randomBytes(32)) -> Answer? {
        guard hello.type == "hello", hello.v == LL2.version,
              let n = hello.nonce.flatMap({ Data(base64Encoded: $0) }), n.count == 32,
              let e = hello.epk.flatMap({ Data(base64Encoded: $0) }), e.count == 65,
              let m = hello.mac.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        let t1 = LL2.t1(name: hello.name ?? "", nonce: n, epk: e)
        var matched: Int?
        for (i, s) in secrets.enumerated() where LL2.verify(LL2.macKey(s), t1, m) && matched == nil { matched = i }
        guard let idx = matched, let z = LL2.z(priv, e) else { return nil }
        let secret = secrets[idx]
        let epk = priv.publicKey.x963Representation
        let t2 = LL2.t2(t1: t1, name: name, nonce: nonce, epk: epk)
        let ok = Frame(type: "hello_ok", v: LL2.version, name: name, nonce: nonce.base64EncodedString(),
                       epk: epk.base64EncodedString(), mac: LL2.mac(LL2.macKey(secret), t2).base64EncodedString())
        let k = LL2.sessionKeys(z: z, secret: secret, t2: t2)
        return Answer(ok: ok, channel: Channel(sendKey: k.l2d, recvKey: k.d2l), secretIndex: idx)
    }
}

/// One direction pair of AES-256-GCM keys with message counters. Confined to one queue (the Link's).
public final class Channel: @unchecked Sendable {
    public enum Kind: UInt8 { case control = 1, chunk = 2 }
    static let limit: UInt64 = 1 << 31
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private(set) var sent: UInt64 = 0
    private(set) var received: UInt64 = 0

    public init(sendKey: Data, recvKey: Data) {
        self.sendKey = SymmetricKey(data: sendKey); self.recvKey = SymmetricKey(data: recvKey)
    }

    static func nonce(_ n: UInt64) -> AES.GCM.Nonce {
        var be = n.bigEndian
        // A 12-byte nonce is always valid.
        return try! AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &be, count: 8))
    }

    /// ciphertext ‖ 16-byte tag. nil once the counter limit is reached (the link must reconnect).
    public func seal(_ kind: Kind, _ payload: Data) -> Data? {
        guard sent < Channel.limit else { return nil }
        var pt = Data([kind.rawValue]); pt.append(payload)
        guard let box = try? AES.GCM.seal(pt, using: sendKey, nonce: Channel.nonce(sent)) else { return nil }
        sent += 1
        var out = Data(capacity: pt.count + 16)   // 0-based: CryptoKit's ciphertext is a slice
        out.append(contentsOf: box.ciphertext); out.append(contentsOf: box.tag)
        return out
    }

    /// nil = tampered, replayed, reordered or past the limit: close the link.
    public func open(_ d: Data) -> (Kind, Data)? {
        guard received < Channel.limit, d.count >= 17,
              let box = try? AES.GCM.SealedBox(nonce: Channel.nonce(received), ciphertext: d.prefix(d.count - 16), tag: d.suffix(16)),
              let pt = try? AES.GCM.open(box, using: recvKey), let first = pt.first, let kind = Kind(rawValue: first) else { return nil }
        received += 1
        return (kind, pt.withUnsafeBytes { Data($0.dropFirst()) })
    }
}
