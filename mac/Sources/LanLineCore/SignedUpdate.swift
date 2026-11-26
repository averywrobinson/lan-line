import Foundation
import CryptoKit

/// One-click updates (beta.10). Next to `version.json` (which older betas still read), each release publishes
/// `update.json`: `{"payload": <base64 JSON>, "sig": <base64 P-256 ECDSA signature over the payload bytes>}`.
/// The payload names the version and, per platform, the download URL, its size and SHA-256. The apps accept it
/// only when the signature verifies with the public key built into them, the version is newer, and the URL is
/// one of Lan-Line's own GitHub release downloads; the downloaded file must then match the size and hash exactly.
/// The private key never leaves the release Mac (Keychain item `lan-line-update-signing`).
public enum SignedUpdate {
    /// The release public key (P-256, raw X‖Y, base64). Its private half is in the release Mac's Keychain.
    public static let publicKeyBase64 = "q2SRNVgYuzy0KDhRFFkP24vfKIMkSm8sRvuevCsQajMJj7WBFftW8qqfmFbvIZ76mOoGX6CigiUGzlIuBQOUMg=="
    public static let manifestURL = URL(string: "https://averywrobinson.com/lan-line/update.json")!
    static let downloadPrefix = "https://github.com/averywrobinson/lan-line/releases/download/"

    public struct Asset: Codable, Sendable, Equatable {
        public let url: String
        public let size: Int64
        public let sha256: String
        public init(url: String, size: Int64, sha256: String) { self.url = url; self.size = size; self.sha256 = sha256 }
    }

    public struct Payload: Codable, Sendable, Equatable {
        public let version: String
        public let mac: Asset?
        public let windows: Asset?
        public let notes_url: String?
        public init(version: String, mac: Asset?, windows: Asset?, notes_url: String?) {
            self.version = version; self.mac = mac; self.windows = windows; self.notes_url = notes_url
        }
    }

    /// What can be installed: the version and this platform's file.
    public struct Offer: Sendable, Equatable {
        public let version: LanLineVersion
        public let asset: Asset
        public let notesURL: String?
        public init(version: LanLineVersion, asset: Asset, notesURL: String?) { self.version = version; self.asset = asset; self.notesURL = notesURL }
    }

    public enum Platform: Sendable { case mac, windows }

    /// Only Lan-Line's own release downloads: `…/releases/download/v<version>/<file>`, plain characters only.
    public static func isAllowedDownload(_ s: String, version: LanLineVersion) -> Bool {
        let prefix = downloadPrefix + "v\(version)/"
        guard s.count <= 300, s.hasPrefix(prefix) else { return false }
        let file = s.dropFirst(prefix.count)
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !file.isEmpty && file.allSatisfy { ok.contains($0) } && !file.hasPrefix(".")
    }

    /// update.json → the offer for this platform, or nil when anything is off (bad signature, older or equal
    /// version, foreign URL, odd size or hash). `key` is for tests; the apps use the built-in key.
    public static func verify(_ data: Data, current: LanLineVersion, platform: Platform, key: String = publicKeyBase64) -> Offer? {
        struct Envelope: Decodable { let payload: String; let sig: String }
        guard data.count <= 64 * 1024,
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = Data(base64Encoded: env.payload), let sig = Data(base64Encoded: env.sig),
              let keyData = Data(base64Encoded: key), keyData.count == 64,
              let pub = try? P256.Signing.PublicKey(rawRepresentation: keyData),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
              pub.isValidSignature(signature, for: payload),
              let p = try? JSONDecoder().decode(Payload.self, from: payload),
              let v = LanLineVersion(p.version), v > current,
              let a = platform == .mac ? p.mac : p.windows,
              isAllowedDownload(a.url, version: v),
              a.size > 0, a.size <= 1_000_000_000,
              a.sha256.count == 64, a.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else { return nil }
        let notes = p.notes_url.flatMap { Updates.isAllowedURL($0) ? $0 : nil }
        return Offer(version: v, asset: a, notesURL: notes)
    }

    /// Sign a payload (the release tool; the key comes from the Keychain). Returns update.json's bytes.
    public static func sign(_ payload: Payload, privateKey: P256.Signing.PrivateKey) throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let body = try enc.encode(payload)
        let sig = try privateKey.signature(for: body).rawRepresentation
        let env = ["payload": body.base64EncodedString(), "sig": sig.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys, .prettyPrinted])
    }

    /// Does a downloaded file match the offer exactly?
    public static func matches(_ file: URL, _ a: Asset) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attrs[.size] as? NSNumber)?.int64Value == a.size,
              let h = try? Hashing.sha256Hex(of: file) else { return false }
        return h == a.sha256
    }

    /// Fetch update.json (one GET, no cookies, like the version check). nil = nothing to install.
    public static func fetchOffer(current: String, platform: Platform, from url: URL = manifestURL, key: String = publicKeyBase64) async -> Offer? {
        guard let own = LanLineVersion(current) else { return nil }
        guard let data = await get(url, current: current, limit: 64 * 1024) else { return nil }
        return verify(data, current: own, platform: platform, key: key)
    }

    /// Download the offer's file into `dir` and check it. Returns the file, or a reason it can't be used.
    public static func download(_ o: Offer, current: String, into dir: URL,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Result<URL, UpdateError> {
        guard let url = URL(string: o.asset.url) else { return .failure(.badOffer) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if matches(dest, o.asset) { return .success(dest) }   // already here from an earlier try
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue("Lan-Line/\(current)", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .failure(.download("the server said no")) }
            let tmp = dest.appendingPathExtension("part")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let h = try FileHandle(forWritingTo: tmp)
            var buf = Data(); buf.reserveCapacity(1 << 20)
            var got: Int64 = 0
            for try await b in bytes {
                buf.append(b)
                if buf.count >= 1 << 20 {
                    try h.write(contentsOf: buf); got += Int64(buf.count); buf.removeAll(keepingCapacity: true)
                    if got > o.asset.size { try? h.close(); try? FileManager.default.removeItem(at: tmp); return .failure(.mismatch) }
                    progress(Double(got) / Double(o.asset.size))
                }
            }
            try h.write(contentsOf: buf); try h.close()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            return .failure(.download(error.localizedDescription))
        }
        guard matches(dest, o.asset) else { try? FileManager.default.removeItem(at: dest); return .failure(.mismatch) }
        progress(1)
        return .success(dest)
    }

    static func get(_ url: URL, current: String, limit: Int) async -> Data? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("Lan-Line/\(current)", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (d, r) = try? await session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200, d.count <= limit else { return nil }
        return d
    }
}

public enum UpdateError: Error, Equatable, Sendable, CustomStringConvertible {
    case badOffer
    case download(String)
    case mismatch
    case install(String)

    public var description: String {
        switch self {
        case .badOffer: return "The update information didn't check out."
        case .download(let why): return "Couldn't download the update (\(why))."
        case .mismatch: return "The download didn't match the signed update, so it wasn't used."
        case .install(let why): return "Couldn't install the update (\(why))."
        }
    }
}
