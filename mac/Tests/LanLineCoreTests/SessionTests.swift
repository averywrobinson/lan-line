import XCTest
import CryptoKit
@testable import LanLineCore

final class SessionTests: XCTestCase {

    // hello and bad token
    func testHelloOK() async throws {
        let (srv, rec, port) = await startListener("hello")
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        let reply = try await c.hello()
        XCTAssertEqual(reply?.type, "hello_ok")
        XCTAssertEqual(reply?.name, "hello")
        await waitUntil(5, "connected") { rec.connectedCount == 1 }
    }

    func testProtocolPingIsAnswered() async throws {
        let (srv, _, port) = await startListener("ping")
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        let err: Error? = await withCheckedContinuation { k in c.task.sendPing { k.resume(returning: $0) } }
        XCTAssertNil(err, "URLSession's ping should get a pong")
    }

    func testBadTokenIsClosed() async throws {
        let (srv, rec, port) = await startListener("badtoken")
        defer { srv.stop() }
        for bad in [String(repeating: "cd", count: 32), "short", ""] {
            let c = RawClient(port: port)
            try? await c.send(.hello(token: bad, name: "evil"))
            let reply = await c.next(timeout: 5)
            XCTAssertNil(reply, "socket should close, got \(String(describing: reply))")
            c.close()
        }
        // a non-hello first frame is also refused
        let c = RawClient(port: port)
        try? await c.send(.text(id: "x", text: "hi"))
        let reply = await c.next(timeout: 5)
        XCTAssertNil(reply)
        XCTAssertEqual(rec.connectedCount, 0)
        XCTAssertTrue(rec.received.isEmpty)
    }

    func testHelloTimeout() async throws {
        let clock = FakeClock()
        var cfg = makeConfig("hellotimeout"); cfg.tickInterval = 0
        let (srv, _, port) = await startListener("hellotimeout", config: cfg, clock: clock)
        defer { srv.stop() }
        let c = RawClient(port: port)
        try await Task.sleep(nanoseconds: 300_000_000)   // let the connection be accepted
        clock.advance(11)
        srv.tick()
        let reply = await c.next(timeout: 5)
        XCTAssertNil(reply, "silent client should be dropped after 10 s")
    }

    // text both ways
    func testTextBothWays() async throws {
        let (srv, srec, port) = await startListener("textsrv")
        defer { srv.stop() }
        let (cli, crec) = startDialer("textcli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "both connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }

        let a = cli.send(text: "hello Mac\nline two")
        let b = srv.send(text: "hello PC 👋")
        await waitUntil(5, "texts arrive") { srec.received.count == 1 && crec.received.count == 1 }
        XCTAssertEqual(srec.received.first?.kind, .text("hello Mac\nline two"))
        XCTAssertEqual(crec.received.first?.kind, .text("hello PC 👋"))
        await waitUntil(5, "acks") { crec.lastState(a.id) == .delivered && srec.lastState(b.id) == .delivered }
    }

    func testDuplicateIdDeliveredOnce() async throws {
        let (srv, rec, port) = await startListener("dup")
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        try await c.send(.text(id: "same", text: "once"))
        let r1 = await c.nextNonBeat()
        XCTAssertEqual(r1?.type, "ack")
        try await c.send(.text(id: "same", text: "once"))
        let ack2 = await c.nextNonBeat()
        XCTAssertEqual(ack2?.type, "ack"); XCTAssertEqual(ack2?.ok, true)
        await waitUntil(2, "received") { rec.received.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rec.received.count, 1)
    }

    // 50 MB file both ways, sha must match
    func testLargeFileBothWays() async throws {
        let (srv, srec, port) = await startListener("bigsrv")
        defer { srv.stop() }
        let (cli, crec) = startDialer("bigcli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }

        let src = tempDir("bigsrc")
        let up = try randomFile(src, name: "up.bin", bytes: 50 << 20)
        let down = try randomFile(src, name: "down.bin", bytes: 50 << 20)
        let a = cli.send(file: up)
        let b = srv.send(file: down)
        await waitUntil(60, "files delivered") {
            crec.lastState(a.id) == .delivered && srec.lastState(b.id) == .delivered
        }
        guard case .file(let n1, let s1, let u1)? = srec.received.first?.kind,
              case .file(let n2, let s2, let u2)? = crec.received.first?.kind else {
            return XCTFail("no file received")
        }
        XCTAssertEqual(n1, "up.bin"); XCTAssertEqual(n2, "down.bin")
        XCTAssertEqual(s1, 50 << 20); XCTAssertEqual(s2, 50 << 20)
        XCTAssertEqual(try Hashing.sha256(of: u1), try Hashing.sha256(of: up))
        XCTAssertEqual(try Hashing.sha256(of: u2), try Hashing.sha256(of: down))
        // progress events were reported, and no .part files are left behind
        XCTAssertTrue(crec.all.contains { if case .outgoing(let i) = $0, i.id == a.id, case .sending = i.state { return true }; return false })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(leftovers, [])
    }

    func testSameNameTwiceGetsSuffix() async throws {
        let (srv, srec, port) = await startListener("samename")
        defer { srv.stop() }
        let (cli, crec) = startDialer("samenamecli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let src = tempDir("samesrc")
        let f = try randomFile(src, name: "note.txt", bytes: 1000)
        cli.send(file: f); cli.send(file: f)
        await waitUntil(10, "two files") { srec.received.count == 2 }
        let names = srec.received.compactMap { if case .file(let n, _, _) = $0.kind { return n }; return nil }
        XCTAssertEqual(names, ["note.txt", "note (2).txt"])
    }

    // bad name and sha mismatch
    func testBadNameIsSanitized() async throws {
        let (srv, rec, port) = await startListener("badname")
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        let body = Data("not really a passwd file".utf8)
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        try await c.send(.fileBegin(id: "f1", name: "../../../etc/..\\passwd", size: Int64(body.count), sha256: sha))
        try await c.send(body)
        try await c.send(.fileEnd(id: "f1"))
        let ack = await c.nextNonBeat()
        XCTAssertEqual(ack?.ok, true)
        await waitUntil(5, "saved") { rec.received.count == 1 }
        guard case .file(let name, _, let url)? = rec.received.first?.kind else { return XCTFail() }
        XCTAssertEqual(name, "passwd")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, srv.config.downloadDir.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), body)
    }

    func testShaMismatchRejected() async throws {
        let (srv, rec, port) = await startListener("badsha")
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        let body = Data(repeating: 7, count: 300_000)
        try await c.send(.fileBegin(id: "f2", name: "x.bin", size: Int64(body.count), sha256: String(repeating: "0", count: 64)))
        try await c.send(body.prefix(200_000))
        try await c.send(body.suffix(100_000))
        try await c.send(.fileEnd(id: "f2"))
        let ack = await c.nextNonBeat()
        XCTAssertEqual(ack?.type, "ack"); XCTAssertEqual(ack?.ok, false); XCTAssertEqual(ack?.err, "sha256 mismatch")
        XCTAssertTrue(rec.received.isEmpty)
        await waitUntil(2, "failure event") { rec.receiveFailures == ["sha256 mismatch"] }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path), [])
    }

    func testOversizeAndShortFilesRejected() async throws {
        let (srv, _, port) = await startListener("size")
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        let sha = String(repeating: "a", count: 64)
        try await c.send(.fileBegin(id: "big", name: "big.bin", size: (1 << 40) + 1, sha256: sha))
        try await c.send(.fileEnd(id: "big"))
        let r2 = await c.nextNonBeat()
        XCTAssertEqual(r2?.ok, false)
        try await c.send(.fileBegin(id: "short", name: "s.bin", size: 10, sha256: sha))
        try await c.send(Data(count: 5))
        try await c.send(.fileEnd(id: "short"))
        let ack = await c.nextNonBeat()
        XCTAssertEqual(ack?.ok, false); XCTAssertEqual(ack?.err, "size mismatch")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path), [])
    }

    func testNotEnoughDiskSpaceRejected() async throws {
        var cfg = makeConfig("disk"); cfg.freeSpaceOverride = 100_000
        let (srv, _, port) = await startListener("disk", config: cfg)
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        try await c.send(.fileBegin(id: "f", name: "f.bin", size: 200_000, sha256: String(repeating: "a", count: 64)))
        try await c.send(.fileEnd(id: "f"))
        let ack = await c.nextNonBeat()
        XCTAssertEqual(ack?.ok, false)
        XCTAssertTrue(ack?.err?.hasPrefix("not enough disk space") ?? false, ack?.err ?? "nil")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path), [])
    }

    // 45 s dead link, with an injected clock
    func testDeadLinkAfter45s() async throws {
        let clock = FakeClock()
        var cfg = makeConfig("dead"); cfg.tickInterval = 0
        let (srv, rec, port) = await startListener("dead", config: cfg, clock: clock)
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        await waitUntil(5, "connected") { rec.connectedCount == 1 }

        clock.advance(16); srv.tick()                     // 16 s: a beat goes out, still alive
        let r3 = await c.next()
        XCTAssertEqual(r3?.type, "beat")
        clock.advance(28); srv.tick()                     // 44 s of silence: still alive
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(rec.disconnects.isEmpty)
        try await c.send(.beat)                           // the peer speaks: silence resets
        try await Task.sleep(nanoseconds: 200_000_000)
        clock.advance(30); srv.tick()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(rec.disconnects.isEmpty)
        clock.advance(16); srv.tick()                     // 46 s since the peer's beat: dead
        await waitUntil(5, "dead link") { !rec.disconnects.isEmpty }
        XCTAssertTrue(rec.disconnects.first?.contains("dead link") ?? false, "\(rec.disconnects)")
        XCTAssertFalse(srv.isConnected)
    }

    // offline queue drained after a reconnect
    func testQueuedBeforeFirstConnect() async throws {
        // learn a free port, then close it again
        let (probe, _, port) = await startListener("probe")
        probe.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        let (cli, crec) = startDialer("offline", port: port)
        defer { cli.stop() }
        let a = cli.send(text: "sent while offline")
        try await Task.sleep(nanoseconds: 700_000_000)     // a few failed dials
        XCTAssertEqual(crec.lastState(a.id), .waiting)

        var cfg = makeConfig("offlinesrv")
        cfg.tickInterval = 1
        let rec = Recorder()
        let srv = Session(role: .listener(port: port, bindHost: "127.0.0.1"), config: cfg) { rec.add($0) }
        srv.start()
        defer { srv.stop() }
        await waitUntil(10, "delivered after connect") { crec.lastState(a.id) == .delivered }
        XCTAssertEqual(rec.received.map(\.kind), [.text("sent while offline")])
    }

    func testQueueDrainedAfterReconnect() async throws {
        let (srv, srec, port) = await startListener("recsrv")
        defer { srv.stop() }
        let (cli, crec) = startDialer("reccli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }

        srv.dropLink()
        await waitUntil(5, "client sees the drop") { !crec.disconnects.isEmpty }
        let a = cli.send(text: "during outage 1")
        let src = tempDir("recsrc")
        let f = cli.send(file: try randomFile(src, name: "queued.bin", bytes: 3 << 20))
        let b = cli.send(text: "during outage 2")
        await waitUntil(10, "reconnected and drained") {
            crec.connectedCount == 2 && [a, f, b].allSatisfy { crec.lastState($0.id) == .delivered }
        }
        let kinds = srec.received.map { item -> String in
            switch item.kind { case .text(let t): return t; case .file(let n, _, _): return n }
        }
        XCTAssertEqual(kinds, ["during outage 1", "queued.bin", "during outage 2"], "in order, exactly once")
    }

    func testDropMidFileResendsCleanly() async throws {
        let (srv, srec, port) = await startListener("midsrv")
        defer { srv.stop() }
        let (cli, crec) = startDialer("midcli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let src = tempDir("midsrc")
        let url = try randomFile(src, name: "mid.bin", bytes: 40 << 20)
        // Cut the link from inside the handler the moment progress passes 10 %, so the drop is mid-file
        // however fast the machine is (a polling test can miss the whole transfer).
        let dropped = Recorder()
        crec.hook = { e in
            if case .outgoing(let i) = e, case .sending(let p) = i.state, p > 0.1, dropped.all.isEmpty {
                dropped.add(.error("dropped")); cli.dropLink()
            }
        }
        let f = cli.send(file: url)
        await waitUntil(30, "delivered after reconnect") { crec.lastState(f.id) == .delivered }
        XCTAssertEqual(dropped.all.count, 1)
        XCTAssertEqual(crec.disconnects.count, 1)
        XCTAssertEqual(crec.connectedCount, 2)
        XCTAssertEqual(srec.received.count, 1)
        guard case .file(let name, _, let saved)? = srec.received.first?.kind else { return XCTFail() }
        XCTAssertEqual(name, "mid.bin")
        XCTAssertEqual(try Hashing.sha256(of: saved), try Hashing.sha256(of: url))
        let parts = try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(parts, [])
    }

    func testNewPeerReplacesOld() async throws {
        let (srv, rec, port) = await startListener("replace")
        defer { srv.stop() }
        let c1 = RawClient(port: port)
        _ = try await c1.hello()
        let c2 = RawClient(port: port)
        defer { c2.close() }
        let r4 = try await c2.hello()
        XCTAssertEqual(r4?.type, "hello_ok")
        await waitUntil(5, "two connects") { rec.connectedCount == 2 }
        let r5 = await c1.nextNonBeat(timeout: 5)
        XCTAssertNil(r5, "the old peer is closed")
        XCTAssertTrue(srv.isConnected)
    }
}

final class RekeyTests: XCTestCase {
    private func rekeys(_ r: Recorder) -> [String] { r.all.compactMap { if case .rekeyed(let t) = $0 { return t }; return nil } }

    /// Pairing: the dialer presents the short code; both sides switch to the same fresh 64-hex secret.
    func testPairingCodeIsSwappedForLongSecret() async throws {
        var lc = makeConfig("rk-l"); lc.token = "ABCDE12345"; lc.rekeyOnPair = true
        let (srv, srec, port) = await startListener("rk-l", config: lc)
        defer { srv.stop() }
        var dc = makeConfig("rk-d"); dc.token = "ABCDE12345"
        let drec = Recorder()
        let dialer = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: dc) { drec.add($0) }
        dialer.start()
        defer { dialer.stop() }
        await waitUntil(5, "connected") { drec.connectedCount == 1 && srec.connectedCount == 1 }
        XCTAssertEqual(rekeys(srec).count, 1)
        XCTAssertEqual(rekeys(srec), rekeys(drec))
        XCTAssertEqual(rekeys(srec).first?.count, 64)
    }

    /// After the swap the new secret works, the code still works until restart, and a wrong code fails.
    func testNewSecretAndCodeAcceptedAfterRekey() async throws {
        var lc = makeConfig("rk2"); lc.token = "ABCDE12345"; lc.rekeyOnPair = true
        let (srv, _, port) = await startListener("rk2", config: lc)
        defer { srv.stop() }
        let c = RawClient(port: port)
        let ok = try await c.hello(token: "ABCDE12345")
        c.close()
        let newTok = try XCTUnwrap(ok?.rekey)
        XCTAssertEqual(newTok.count, 64)
        let c2 = RawClient(port: port); defer { c2.close() }
        let ok2 = try await c2.hello(token: newTok)
        XCTAssertEqual(ok2?.type, "hello_ok"); XCTAssertNil(ok2?.rekey)   // only one rekey per pairing
        let c3 = RawClient(port: port); defer { c3.close() }
        let ok3 = try await c3.hello(token: "ABCDE12345")
        XCTAssertEqual(ok3?.type, "hello_ok")
        let c4 = RawClient(port: port); defer { c4.close() }
        let bad = try? await c4.hello(token: "ZZZZZ99999")
        XCTAssertNotEqual((bad ?? nil)?.type, "hello_ok")
    }
}
