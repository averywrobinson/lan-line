import Foundation

/// One paired computer. Each pairing has its own 32-byte secret (ENCRYPTION.md); the computer that showed the
/// code listens for it, the one that typed the code dials it.
public struct Partner: Codable, Sendable, Equatable, Identifiable {
    /// The partner's device id (from its hello), or a placeholder until it is known.
    public var id: String
    public var name: String
    public var secret: String
    /// "listen" or "connect".
    public var role: String
    public var hosts: [String]
    /// Port to dial; nil = the usual 47830 (tests use other ports).
    public var port: UInt16?
    public var pairedAt: Date

    public init(id: String, name: String, secret: String, role: String, hosts: [String], port: UInt16? = nil, pairedAt: Date = Date()) {
        self.id = id; self.name = name; self.secret = secret; self.role = role; self.hosts = hosts; self.port = port
        self.pairedAt = Date(timeIntervalSince1970: pairedAt.timeIntervalSince1970.rounded(.down))   // whole seconds, as saved
    }

    public var connects: Bool { role == "connect" }

    enum CodingKeys: String, CodingKey { case id, name, secret, role, hosts, port, pairedAt = "paired_at" }
}

public enum PartnerError: Error, Equatable { case tooMany }

/// config.json from beta.7 on: this computer's id and a list of partners. A beta.6 file (one `token`) is read
/// as one partner; on save the first partner is also written to the old single-pairing fields, so going back
/// to beta.6 keeps that pairing.
public struct DeviceConfig: Codable, Sendable, Equatable {
    public static let maxPartners = 8

    public var deviceID: String
    public var port: UInt16
    public var peers: [Partner]

    public init(deviceID: String = DeviceConfig.newDeviceID(), port: UInt16 = LanLineConfig.defaultPort, peers: [Partner] = []) {
        self.deviceID = deviceID; self.port = port; self.peers = peers
    }

    public static func newDeviceID() -> String { String(Secrets.newToken().prefix(32)) }

    public func partner(_ id: String) -> Partner? { peers.first { $0.id == id } }

    /// Add a partner; a partner with the same id (paired again) is replaced in place.
    public mutating func add(_ p: Partner) throws {
        if let i = peers.firstIndex(where: { $0.id == p.id }) { peers[i] = p; return }
        guard peers.count < Self.maxPartners else { throw PartnerError.tooMany }
        peers.append(p)
    }

    /// Forget a partner: its secret is gone, so it can't connect any more.
    public mutating func forget(_ id: String) { peers.removeAll { $0.id == id } }

    public mutating func rename(_ id: String, to name: String) {
        if let i = peers.firstIndex(where: { $0.id == id }) { peers[i].name = String(name.prefix(64)) }
    }

    // MARK: file

    /// Everything a beta.6 or beta.7 file may hold.
    private struct File: Codable {
        var device_id: String?
        var port: UInt16?
        var peers: [Partner]?
        var token: String?, hosts: [String]?, role: String?, peer: String?
    }

    enum CodingKeys: String, CodingKey { case deviceID = "device_id", port, peers }

    /// Read config.json, migrating a single beta.6 pairing. `defaultRole` is this platform's role when an old
    /// file has none ("listen" on the Mac).
    public static func load(from url: URL = LanLineConfig.defaultURL, defaultRole: String) throws -> DeviceConfig {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let f = try dec.decode(File.self, from: Data(contentsOf: url))
        var c = DeviceConfig(deviceID: f.device_id ?? newDeviceID(), port: f.port ?? LanLineConfig.defaultPort, peers: f.peers ?? [])
        if f.peers == nil, let tok = f.token, !tok.isEmpty {
            c.peers = [Partner(id: "legacy-" + PairCode.pairID(token: tok), name: f.peer ?? "Partner", secret: tok,
                               role: f.role ?? defaultRole, hosts: f.hosts ?? [])]
        }
        return c
    }

    /// Write atomically, readable by this user only (it holds secrets).
    public func save(to url: URL = LanLineConfig.defaultURL) throws {
        var f = File(device_id: deviceID, port: port, peers: peers)
        if let first = peers.first { f.token = first.secret; f.hosts = first.hosts; f.role = first.role; f.peer = first.name }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(f).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
