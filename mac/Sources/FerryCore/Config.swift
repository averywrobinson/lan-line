import Foundation
import CryptoKit

public struct FerryConfig: Codable, Sendable, Equatable {
    public var port: UInt16
    public var token: String
    public var hosts: [String]?
    /// "listen" (wait for the other computer) or "connect" (dial it). Missing = this platform's default (listen on the Mac).
    public var role: String?
    /// The partner's name from the last connection, for "Waiting for …" while it is away.
    public var peer: String?

    public static let defaultPort: UInt16 = 47830

    public init(port: UInt16 = FerryConfig.defaultPort, token: String, hosts: [String]? = nil, role: String? = nil, peer: String? = nil) {
        self.port = port; self.token = token; self.hosts = hosts; self.role = role; self.peer = peer
    }

    public var connects: Bool { role == "connect" }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lan-Line/config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> FerryConfig {
        try JSONDecoder().decode(FerryConfig.self, from: Data(contentsOf: url))
    }

    /// Write atomically, readable by this user only (the token is a secret).
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static var downloadsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Lan-Line")
    }
}

public enum Secrets {
    /// Constant-time comparison: the time taken depends only on the lengths, never on where the bytes differ.
    public static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt64(x.count ^ y.count)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            diff |= UInt64(p ^ q)
        }
        return diff == 0
    }

    /// 32 random bytes as 64 hex characters.
    public static func newToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.hex
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

public enum Hashing {
    /// SHA-256 of a file, read in 1 MiB pieces so big files are never held in memory.
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).hex
    }
}
