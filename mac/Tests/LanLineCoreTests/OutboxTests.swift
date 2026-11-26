import XCTest
@testable import LanLineCore

/// beta.11: what is still waiting for a partner is kept in `outbox.json`, so quitting or restarting the sender
/// doesn't drop it (the iPhone, which only receives while its app is open, is the usual case).
final class OutboxTests: XCTestCase {
    let ab = Secrets.newToken(), ac = Secrets.newToken()

    private func sender(_ outbox: URL, partners: [Partner]) async -> (Hub, HubRecorder) {
        let r = HubRecorder()
        var c = hubConfig("A", device: "device-aaaa")
        c.outboxURL = outbox
        let h = Hub(config: c, partners: partners) { r.add($0) }
        h.start()
        await waitUntil(5, "A listening") { r.port != nil }
        return (h, r)
    }

    private func phone(_ tag: String, device: String, secret: String, port: UInt16?) -> (Hub, HubRecorder) {
        let r = HubRecorder()
        let h = Hub(config: hubConfig(tag, device: device), partners: [
            Partner(id: "device-aaaa", name: "A", secret: secret, role: "connect", hosts: ["127.0.0.1"], port: port)]) { r.add($0) }
        h.start()
        return (h, r)
    }

    private var b: Partner { Partner(id: "device-bbbb", name: "B", secret: ab, role: "listen", hosts: []) }
    private var c: Partner { Partner(id: "device-cccc", name: "C", secret: ac, role: "listen", hosts: []) }

    private func texts(_ r: HubRecorder) -> [String] {
        r.received().compactMap { if case .text(let t) = $0.kind { return t }; return nil }
    }

    func testWaitingItemsSurviveARestartAndGoInOrder() async throws {
        let dir = tempDir("outbox-restart"), outbox = dir.appendingPathComponent("outbox.json")
        let file = dir.appendingPathComponent("photo.jpg")
        try Data(repeating: 7, count: 50_000).write(to: file)
        var (a, _) = await sender(outbox, partners: [b])
        a.send(text: "first", to: "device-bbbb")
        a.send(file: file, to: "device-bbbb")
        a.send(text: "third", to: "device-bbbb")
        await waitUntil(5, "three saved") { Hub.loadOutbox(outbox).count == 3 }
        a.stop()
        let saved = Hub.loadOutbox(outbox)
        XCTAssertEqual(saved.map(\.kind), ["text", "file", "text"], "in the order they were sent")
        XCTAssertEqual(saved.map(\.to), [["device-bbbb"], ["device-bbbb"], ["device-bbbb"]])

        // Lan-Line starts again; the phone comes back afterwards
        let ra: HubRecorder
        (a, ra) = await sender(outbox, partners: [b])
        let ids = saved.map(\.id)
        await waitUntil(5, "restored rows shown") { ids.allSatisfy { ra.last($0) != nil } }
        let (p, rp) = phone("B", device: "device-bbbb", secret: ab, port: ra.port)
        await waitUntil(10, "all three arrive") { rp.received().count == 3 }
        XCTAssertEqual(texts(rp), ["first", "third"])
        XCTAssertEqual(rp.received().filter { if case .file = $0.kind { return true }; return false }.count, 1)
        await waitUntil(5, "delivered") { ids.allSatisfy { ra.last($0)?.summary == .delivered } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.path), "nothing owed: the file goes")
        p.stop(); a.stop()
    }

    func testEveryoneKeepsOnlyThoseStillWaiting() async throws {
        let dir = tempDir("outbox-everyone"), outbox = dir.appendingPathComponent("outbox.json")
        var (a, ra) = await sender(outbox, partners: [b, c])
        let (pc, rc) = phone("C", device: "device-cccc", secret: ac, port: ra.port)
        await waitUntil(5, "C connected") { ra.connected("device-cccc") }
        let h = a.send(text: "to everyone", to: nil)
        await waitUntil(5, "C has it") { rc.received().count == 1 }
        await waitUntil(5, "saved for B only") { Hub.loadOutbox(outbox).first?.to == ["device-bbbb"] }
        a.stop()

        (a, ra) = await sender(outbox, partners: [b, c])
        await waitUntil(5, "C back") { ra.connected("device-cccc") || rc.connects("device-aaaa") > 0 }
        let (pb, rb) = phone("B", device: "device-bbbb", secret: ab, port: ra.port)
        await waitUntil(10, "B gets it after the restart") { rb.received().count == 1 }
        XCTAssertEqual(texts(rb), ["to everyone"])
        XCTAssertEqual(ra.last(h.id)?.to, ["device-bbbb"])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rc.received().count, 1, "C isn't sent a second copy")
        pb.stop(); pc.stop(); a.stop()
    }

    func testAFileGoneSinceIsShownFailedNotSent() async throws {
        let dir = tempDir("outbox-gone"), outbox = dir.appendingPathComponent("outbox.json")
        let file = dir.appendingPathComponent("gone.png")
        try Data(repeating: 1, count: 1000).write(to: file)
        var (a, _) = await sender(outbox, partners: [b])
        a.send(file: file, to: "device-bbbb")
        await waitUntil(5, "saved") { Hub.loadOutbox(outbox).count == 1 }
        a.stop()
        let id = Hub.loadOutbox(outbox)[0].id
        try FileManager.default.removeItem(at: file)

        let ra: HubRecorder
        (a, ra) = await sender(outbox, partners: [b])
        await waitUntil(5, "shown failed") { ra.last(id) != nil }
        XCTAssertEqual(ra.last(id)?.summary, .failed("it's no longer there"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.path))
        a.stop()
    }

    func testForgettingAPartnerDropsWhatWasOwedToIt() async throws {
        let dir = tempDir("outbox-forget"), outbox = dir.appendingPathComponent("outbox.json")
        let (a, _) = await sender(outbox, partners: [b, c])
        a.send(text: "for both", to: nil)
        await waitUntil(5, "saved") { Hub.loadOutbox(outbox).first?.to.count == 2 }
        a.remove("device-bbbb")
        await waitUntil(5, "only C left") { Hub.loadOutbox(outbox).first?.to == ["device-cccc"] }
        a.remove("device-cccc")
        await waitUntil(5, "nothing left") { !FileManager.default.fileExists(atPath: outbox.path) }
        a.stop()
    }

    /// Pairing again (or the partner moving) replaces its Session: what was queued goes to the new one.
    func testReplacedSessionKeepsTheQueue() async throws {
        let dir = tempDir("outbox-replace"), outbox = dir.appendingPathComponent("outbox.json")
        let (a, ra) = await sender(outbox, partners: [b])
        a.send(text: "queued before", to: "device-bbbb")
        await waitUntil(5, "saved") { Hub.loadOutbox(outbox).count == 1 }
        a.add(b, pairing: false)
        let (p, rp) = phone("B", device: "device-bbbb", secret: ab, port: ra.port)
        await waitUntil(10, "arrives through the new Session") { rp.received().count == 1 }
        XCTAssertEqual(texts(rp), ["queued before"])
        p.stop(); a.stop()
    }

    /// The answer to an item can come back before `send` returns (a fast LAN): it must still reach the item, or the row
    /// stays "waiting" for ever and the outbox sends it again after a restart. Seen once on the PC (2026-11-26); this
    /// doesn't force that timing every run: the hub registering routes before handing items over rules it out.
    func testFastAnswersAreNeverLost() async throws {
        let dir = tempDir("outbox-fast"), outbox = dir.appendingPathComponent("outbox.json")
        let (a, ra) = await sender(outbox, partners: [b])
        let (p, rp) = phone("B", device: "device-bbbb", secret: ab, port: ra.port)
        await waitUntil(5, "B connected") { ra.connected("device-bbbb") }
        let sent = (0..<200).map { a.send(text: "n\($0)", to: "device-bbbb").id }
        await waitUntil(10, "all arrive") { rp.received().count == 200 }
        await waitUntil(5, "every row says delivered") { sent.allSatisfy { ra.last($0)?.summary == .delivered } }
        await waitUntil(5, "nothing owed") { !FileManager.default.fileExists(atPath: outbox.path) }
        p.stop(); a.stop()
    }

        /// Review (beta.11): an item fully sent but not yet answered counts as delivered. Quitting, or replacing the partner's
    /// Session, resets it to "waiting" inside the Session; that must not put it in the outbox or send it again.
    func testUnansweredItemIsNotSavedOrSentAgain() async throws {
        let dir = tempDir("outbox-unacked"), outbox = dir.appendingPathComponent("outbox.json")
        let (a, ra) = await sender(outbox, partners: [b])
        let rb = HubRecorder()
        var cb = hubConfig("B", device: "device-bbbb")
        cb.tune = { s in s.backoff = [0.2, 0.4]; s.dialTimeout = 2; s.holdTextAcksForTests = true }
        let pb = Hub(config: cb, partners: [Partner(id: "device-aaaa", name: "A", secret: ab, role: "connect", hosts: ["127.0.0.1"], port: ra.port)]) { rb.add($0) }
        pb.start()
        await waitUntil(5, "B connected") { ra.connected("device-bbbb") }
        let h = a.send(text: "once", to: "device-bbbb")
        await waitUntil(5, "B has it") { rb.received().count == 1 }
        await waitUntil(5, "sent, not answered") { ra.last(h.id)?.summary == .sent }
        await waitUntil(5, "not owed") { !FileManager.default.fileExists(atPath: outbox.path) }

        a.add(b, pairing: false)   // the partner's Session is replaced (as when it moves address)
        await waitUntil(10, "B back") { rb.connects("device-aaaa") >= 2 }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rb.received().count, 1, "not sent a second time")

        a.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.path), "quitting didn't put it in the outbox")
        pb.stop()
    }

    /// Review (beta.11): re-pairing pairs under a new id, forgets the older pairing, then renames the new one to the
    /// same device id. What the older pairing was owed must go on, not be dropped with it.
    func testRePairingKeepsWhatWasOwed() async throws {
        let dir = tempDir("outbox-repair"), outbox = dir.appendingPathComponent("outbox.json")
        let (a, ra) = await sender(outbox, partners: [b])
        a.send(text: "before re-pairing", to: "device-bbbb")
        await waitUntil(5, "saved") { Hub.loadOutbox(outbox).count == 1 }
        let fresh = Secrets.newToken()
        a.add(Partner(id: "pairing-1", name: "B", secret: fresh, role: "listen", hosts: []), pairing: false)
        a.remove("device-bbbb")
        a.rename(partner: "pairing-1", to: "device-bbbb")
        await waitUntil(5, "still owed after the re-pair") { Hub.loadOutbox(outbox).first?.to == ["device-bbbb"] }
        let (p, rp) = phone("B", device: "device-bbbb", secret: fresh, port: ra.port)
        await waitUntil(10, "arrives") { rp.received().count == 1 }
        XCTAssertEqual(texts(rp), ["before re-pairing"])
        p.stop(); a.stop()
    }

    func testSweepKeepsWhatTheOutboxNeeds() throws {
        let dir = tempDir("outbox-sweep"), pasted = dir.appendingPathComponent("Pasted", isDirectory: true)
        try FileManager.default.createDirectory(at: pasted, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-3 * 86_400)
        func make(_ name: String, at: Date) throws -> URL {
            let u = pasted.appendingPathComponent(name)
            try Data([1]).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: u.path)
            return u
        }
        let oldUnneeded = try make("a.png", at: old), oldNeeded = try make("b.png", at: old), recent = try make("c.png", at: Date())
        let sub = pasted.appendingPathComponent("UUID-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([2]).write(to: sub.appendingPathComponent("photo.heic"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: sub.path)
        let outbox = dir.appendingPathComponent("outbox.json")
        let entries = [Hub.OutboxEntry(id: "1", kind: "file", path: oldNeeded.path, to: ["x"], at: old),
                       Hub.OutboxEntry(id: "2", kind: "file", path: sub.appendingPathComponent("photo.heic").path, to: ["x"], at: old)]
        try Hub.outboxEncoder().encode(entries).write(to: outbox)
        XCTAssertEqual(Hub.sweepUnsent(pasted, outbox: outbox, olderThan: 86_400), 1)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: oldUnneeded.path))
        XCTAssertTrue(fm.fileExists(atPath: oldNeeded.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertTrue(fm.fileExists(atPath: sub.path), "a copy's folder stays while its file is owed")
    }
}
