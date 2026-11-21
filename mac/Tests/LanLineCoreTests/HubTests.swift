import XCTest
@testable import LanLineCore

final class DeviceConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let u = tempDir("cfg").appendingPathComponent("config.json")
        try Data(json.utf8).write(to: u)
        return u
    }

    /// A beta.6 config (one token) becomes peers[0]; the pairing keeps working.
    func testMigratesSinglePairing() throws {
        let tok = String(repeating: "ab", count: 32)
        let u = try write(#"{"hosts":["192.168.1.20","100.64.0.7"],"peer":"STUDIO-PC","port":47830,"role":"connect","token":"\#(tok)"}"#)
        let c = try DeviceConfig.load(from: u, defaultRole: "listen")
        XCTAssertEqual(c.peers.count, 1)
        let p = c.peers[0]
        XCTAssertEqual(p.secret, tok); XCTAssertEqual(p.role, "connect"); XCTAssertEqual(p.name, "STUDIO-PC")
        XCTAssertEqual(p.hosts, ["192.168.1.20", "100.64.0.7"])
        XCTAssertEqual(c.port, 47830)
        XCTAssertEqual(c.deviceID.count, 32, "a device id is made on first load")
        // saved: the new list, plus the first partner mirrored in the old fields (so beta.6 still reads it)
        try c.save(to: u)
        let again = try DeviceConfig.load(from: u, defaultRole: "listen")
        XCTAssertEqual(again, c)
        let legacy = try LanLineConfig.load(from: u)
        XCTAssertEqual(legacy.token, tok); XCTAssertEqual(legacy.role, "connect"); XCTAssertEqual(legacy.hosts ?? [], p.hosts)
        let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "secrets: owner only")
    }

    func testMissingRoleUsesPlatformDefault() throws {
        let u = try write(#"{"port":47830,"token":"ABCDE12345"}"#)
        XCTAssertEqual(try DeviceConfig.load(from: u, defaultRole: "listen").peers.first?.role, "listen")
        XCTAssertEqual(try DeviceConfig.load(from: u, defaultRole: "connect").peers.first?.role, "connect")
    }

    func testAddForgetRenameAndCap() throws {
        var c = DeviceConfig()
        XCTAssertTrue(c.peers.isEmpty)
        for i in 0..<DeviceConfig.maxPartners {
            try c.add(Partner(id: "dev\(i)", name: "C\(i)", secret: Secrets.newToken(), role: "listen", hosts: []))
        }
        XCTAssertThrowsError(try c.add(Partner(id: "dev9", name: "too many", secret: Secrets.newToken(), role: "listen", hosts: [])))
        // pairing again with a computer already in the list replaces it (no duplicates, no cap problem)
        let fresh = Secrets.newToken()
        try c.add(Partner(id: "dev3", name: "C3 again", secret: fresh, role: "connect", hosts: ["10.0.0.3"]))
        XCTAssertEqual(c.peers.count, DeviceConfig.maxPartners)
        XCTAssertEqual(c.partner("dev3")?.secret, fresh)
        c.rename("dev3", to: "Studio PC")
        XCTAssertEqual(c.partner("dev3")?.name, "Studio PC")
        c.forget("dev3")
        XCTAssertNil(c.partner("dev3"))
        XCTAssertEqual(c.peers.count, DeviceConfig.maxPartners - 1)
        // forgetting everything leaves no legacy token behind
        for p in c.peers { c.forget(p.id) }
        let u = tempDir("cfg-empty").appendingPathComponent("config.json")
        try c.save(to: u)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any]
        XCTAssertNil(raw?["token"])
    }

    func testFreshConfigHasNoPartners() throws {
        let u = try write(#"{"port":47830}"#)
        let c = try DeviceConfig.load(from: u, defaultRole: "listen")
        XCTAssertTrue(c.peers.isEmpty)
        XCTAssertFalse(c.deviceID.isEmpty)
    }
}

/// Thread-safe log of one Hub's events.
final class HubRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HubEvent] = []
    func add(_ e: HubEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [HubEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var port: UInt16? { for case .listening(let p) in all { return p }; return nil }
    func connected(_ partner: String) -> Bool {
        var up = false
        for e in all {
            if case .connected(let p, _) = e, p == partner { up = true }
            if case .disconnected(let p, _) = e, p == partner { up = false }
        }
        return up
    }
    func connects(_ partner: String) -> Int { all.filter { if case .connected(let p, _) = $0 { return p == partner }; return false }.count }
    func received(from partner: String? = nil) -> [Item] {
        all.compactMap { if case .received(let p, let i) = $0, partner == nil || p == partner { return i }; return nil }
    }
    func last(_ id: String) -> HubItem? {
        for case .outgoing(let h) in all.reversed() where h.id == id { return h }
        return nil
    }
}

func hubConfig(_ tag: String, device: String) -> HubConfig {
    var c = HubConfig(name: tag, deviceID: device, downloadDir: tempDir(tag))
    c.port = 0; c.bindHost = "127.0.0.1"
    c.tune = { s in s.backoff = [0.2, 0.4]; s.dialTimeout = 2 }
    return c
}

final class HubTests: XCTestCase {
    let ab = Secrets.newToken(), ac = Secrets.newToken(), bc = Secrets.newToken()

    /// A listens for B and C; C listens for B; B dials both. Device ids are 8+ characters.
    private func triangle() async -> (Hub, HubRecorder, Hub, HubRecorder, Hub, HubRecorder) {
        let ra = HubRecorder(), rb = HubRecorder(), rc = HubRecorder()
        let a = Hub(config: hubConfig("A", device: "device-aaaa"), partners: [
            Partner(id: "device-bbbb", name: "B", secret: ab, role: "listen", hosts: []),
            Partner(id: "device-cccc", name: "C", secret: ac, role: "listen", hosts: [])]) { ra.add($0) }
        a.start()
        await waitUntil(5, "A listening") { ra.port != nil }
        let c = Hub(config: hubConfig("C", device: "device-cccc"), partners: [
            Partner(id: "device-aaaa", name: "A", secret: ac, role: "connect", hosts: ["127.0.0.1"], port: ra.port),
            Partner(id: "device-bbbb", name: "B", secret: bc, role: "listen", hosts: [])]) { rc.add($0) }
        c.start()
        await waitUntil(5, "C listening") { rc.port != nil }
        let b = Hub(config: hubConfig("B", device: "device-bbbb"), partners: [
            Partner(id: "device-aaaa", name: "A", secret: ab, role: "connect", hosts: ["127.0.0.1"], port: ra.port),
            Partner(id: "device-cccc", name: "C", secret: bc, role: "connect", hosts: ["127.0.0.1"], port: rc.port)]) { rb.add($0) }
        b.start()
        await waitUntil(10, "all six links up") {
            ra.connected("device-bbbb") && ra.connected("device-cccc") && rb.connected("device-aaaa") && rb.connected("device-cccc")
                && rc.connected("device-aaaa") && rc.connected("device-bbbb")
        }
        return (a, ra, b, rb, c, rc)
    }

    func testTriangleAndEveryone() async throws {
        let (a, ra, b, rb, c, rc) = await triangle()
        defer { a.stop(); b.stop(); c.stop() }
        XCTAssertTrue(ra.all.contains(.peerDevice(partner: "device-bbbb", device: "device-bbbb")))
        let t = b.send(text: "hello everyone", to: nil)
        XCTAssertEqual(Set(t.to), ["device-aaaa", "device-cccc"])
        await waitUntil(5, "both got it") { ra.received(from: "device-bbbb").count == 1 && rc.received(from: "device-bbbb").count == 1 }
        await waitUntil(5, "2/2") { rb.last(t.id)?.delivered == 2 }
        XCTAssertEqual(rb.last(t.id)?.summary, .delivered)
        // to one computer only
        let src = try randomFile(tempDir("hub-src"), name: "only-c.bin", bytes: 600_000)
        let f = b.send(file: src, to: "device-cccc")
        await waitUntil(10, "C got the file") { rc.received(from: "device-bbbb").count == 2 }
        await waitUntil(5, "1/1") { rb.last(f.id)?.summary == .delivered }
        XCTAssertEqual(ra.received().count, 1, "A didn't get the file")
        guard case .file(_, _, let got)? = rc.received(from: "device-bbbb").last?.kind else { return XCTFail() }
        XCTAssertEqual(try Hashing.sha256(of: got), try Hashing.sha256(of: src))
        // a folder to everyone from the listener side
        let folder = try sampleFolder("hub-fold")
        let d = a.send(folder: folder, to: nil)
        await waitUntil(15, "folder 2/2") { ra.last(d.id)?.delivered == 2 }
    }

    func testWrongSecretRefusedAndOthersUnaffected() async throws {
        let (a, ra, b, rb, c, rc) = await triangle()
        defer { a.stop(); b.stop(); c.stop() }
        let rx = HubRecorder()
        let x = Hub(config: hubConfig("X", device: "device-xxxx"), partners: [
            Partner(id: "device-aaaa", name: "A", secret: Secrets.newToken(), role: "connect", hosts: ["127.0.0.1"], port: ra.port)]) { rx.add($0) }
        x.start(); defer { x.stop() }
        await waitUntil(5, "refused") { rx.all.contains { if case .status(_, let s) = $0 { return s.hasPrefix("Refused") }; return false } }
        XCTAssertFalse(rx.connected("device-aaaa"))
        XCTAssertEqual(ra.connects("device-bbbb"), 1); XCTAssertEqual(ra.connects("device-cccc"), 1)
        _ = rb; _ = rc
    }

    /// The same partner connecting again replaces its own link; other partners keep theirs.
    func testSamePartnerReplacesOnlyItself() async throws {
        let (a, ra, b, rb, c, rc) = await triangle()
        defer { a.stop(); b.stop(); c.stop() }
        let raw = RawClient(port: ra.port!)
        defer { raw.close() }
        let ok = try await raw.hello(token: ab, name: "B again")
        XCTAssertEqual(ok?.type, "hello_ok")
        await waitUntil(5, "B reconnects") { ra.connects("device-bbbb") >= 2 }
        XCTAssertEqual(ra.connects("device-cccc"), 1, "C's link was never touched")
        XCTAssertTrue(ra.connected("device-cccc"))
        _ = rb; _ = rc
    }

    /// An item for an offline partner waits in its queue and goes out when it comes back.
    func testOfflinePartnerGetsQueuedItems() async throws {
        let (a, ra, b, rb, c, rc) = await triangle()
        defer { a.stop(); b.stop() }
        c.stop()
        await waitUntil(10, "C gone") { !rb.connected("device-cccc") }
        let t = b.send(text: "while C was away", to: nil)
        await waitUntil(5, "A has it") { ra.received(from: "device-bbbb").contains { $0.kind == .text("while C was away") } }
        XCTAssertEqual(rb.last(t.id)?.delivered, 1)
        // C comes back on the same port, with the same pairings
        let rc2 = HubRecorder()
        var cfg = hubConfig("C", device: "device-cccc"); cfg.port = c.boundPort ?? 0
        let c2 = Hub(config: cfg, partners: [
            Partner(id: "device-aaaa", name: "A", secret: ac, role: "connect", hosts: ["127.0.0.1"], port: ra.port),
            Partner(id: "device-bbbb", name: "B", secret: bc, role: "listen", hosts: [])]) { rc2.add($0) }
        c2.start(); defer { c2.stop() }
        await waitUntil(20, "C gets it after coming back") { rc2.received(from: "device-bbbb").contains { $0.kind == .text("while C was away") } }
        await waitUntil(5, "2/2") { rb.last(t.id)?.delivered == 2 }
        _ = rc
    }

    /// Pairing a new computer adds a partner; the existing ones stay connected and keep their secrets.
    func testPairingAddsAPartner() async throws {
        let (a, ra, b, rb, c, rc) = await triangle()
        defer { a.stop(); b.stop(); c.stop() }
        let code = "PAIRD12345"
        a.add(Partner(id: "pairing-1", name: "New computer", secret: code, role: "listen", hosts: []), pairing: true)
        let rd = HubRecorder()
        let d = Hub(config: hubConfig("D", device: "device-dddd"), partners: [
            Partner(id: "pairing-1", name: "A", secret: code, role: "connect", hosts: ["127.0.0.1"], port: ra.port)]) { rd.add($0) }
        d.start(); defer { d.stop() }
        await waitUntil(10, "D paired") { rd.connected("pairing-1") && ra.connected("pairing-1") }
        let aKey = ra.all.compactMap { if case .rekeyed(let p, let t) = $0, p == "pairing-1" { return t }; return nil }.first
        let dKey = rd.all.compactMap { if case .rekeyed(let p, let t) = $0, p == "pairing-1" { return t }; return nil }.first
        XCTAssertNotNil(aKey); XCTAssertEqual(aKey, dKey)
        XCTAssertTrue(ra.all.contains(.peerDevice(partner: "pairing-1", device: "device-dddd")), "A learns D's device id")
        XCTAssertEqual(ra.connects("device-bbbb"), 1); XCTAssertEqual(ra.connects("device-cccc"), 1)
        // Forget: D can't connect any more
        a.remove("pairing-1")
        await waitUntil(5, "D dropped") { !rd.connected("pairing-1") }
        _ = rb; _ = rc
    }
}

final class HubDiscoveryTests: XCTestCase {
    /// One reply per listening partner (beta.6 computers find theirs), each with this device id.
    func testResponderAnswersPerPartner() async throws {
        let port = UInt16.random(in: 40000...49000)
        let s1 = Secrets.newToken(), s2 = Secrets.newToken()
        let rec = HubRecorder()
        var cfg = hubConfig("disc", device: "device-disc"); cfg.port = 0
        let hub = Hub(config: cfg, partners: [
            Partner(id: "p1", name: "One", secret: s1, role: "listen", hosts: []),
            Partner(id: "p2", name: "Two", secret: s2, role: "listen", hosts: []),
            Partner(id: "p3", name: "Dialled", secret: Secrets.newToken(), role: "connect", hosts: ["127.0.0.1"], port: 9)]) { rec.add($0) }
        hub.start(); defer { hub.stop() }
        hub.startResponder(port: port)
        try await Task.sleep(nanoseconds: 300_000_000)
        let q = DispatchQueue(label: "disc-test")
        let found: [DiscoveredPeer] = await withCheckedContinuation { k in
            Discovery.search(port: port, timeout: 0.6, targets: ["127.0.0.1"], queue: q) { k.resume(returning: $0) }
        }
        XCTAssertEqual(Set(found.map(\.pairID)), [PairCode.pairID(token: s1), PairCode.pairID(token: s2)], "only listening partners")
        XCTAssertTrue(found.allSatisfy { $0.device == "device-disc" })
    }

    /// A partner that moved is found again by its pair id and dialled at the new address.
    func testFindMovedRedials() async throws {
        let secret = Secrets.newToken()
        let rl = HubRecorder(), rd = HubRecorder()
        let l = Hub(config: hubConfig("moved-l", device: "device-moved"), partners: [
            Partner(id: "device-dialer", name: "D", secret: secret, role: "listen", hosts: [])]) { rl.add($0) }
        l.start(); defer { l.stop() }
        await waitUntil(5, "listening") { rl.port != nil }
        let dport = UInt16.random(in: 40000...49000)
        l.startResponder(port: dport)
        let d = Hub(config: hubConfig("moved-d", device: "device-dialer"), partners: [
            Partner(id: "device-moved", name: "L", secret: secret, role: "connect", hosts: ["192.0.2.1"], port: rl.port)]) { rd.add($0) }
        d.start(); defer { d.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        d.findMoved(port: dport, targets: ["127.0.0.1"], timeout: 0.5)
        await waitUntil(10, "found and connected") { rd.connected("device-moved") }
        XCTAssertTrue(rd.all.contains(.peerAddresses(partner: "device-moved", ["127.0.0.1", "192.0.2.1"])))
    }
}
