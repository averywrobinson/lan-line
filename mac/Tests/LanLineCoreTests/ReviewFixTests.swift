import XCTest
import CryptoKit
@testable import LanLineCore

/// Cases from the beta.10 code review (2026-11-25); the PC runs the same ones ("review: …").
final class ReviewFixTests: XCTestCase {
    private func cfg(_ tag: String) -> SessionConfig {
        var c = makeConfig(tag)
        c.progressInterval = 0.01
        c.progressDelay = 0
        return c
    }

    private func incoming(_ r: Recorder, _ id: String) -> [ItemState] {
        r.all.compactMap { if case .incoming(let i) = $0, i.id == id { return i.state }; return nil }
    }

    /// The folder setting changes while a file is arriving (to a folder that doesn't exist yet): the file
    /// finishes where it started, and the next one goes to the new folder.
    func testFileFinishesWhereItStartedWhenTheFolderChanges() async throws {
        let (srv, srec, port) = await startListener("dir-srv", config: cfg("dir-srv"))
        defer { srv.stop() }
        let (cli, crec) = startDialer("dir-cli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        let old = srv.config.downloadDir
        let new = tempDir("dir-new").appendingPathComponent("Studio PC")   // not created
        let once = Recorder()
        srec.hook = { e in
            if case .incoming(let i) = e, case .receiving(let p) = i.state, p > 0.2, once.all.isEmpty { once.add(.status("x")); srv.setDownloadDir(new) }
        }
        let f = cli.send(file: try randomFile(tempDir("dir-src"), name: "big.bin", bytes: 40 << 20))
        await waitUntil(30, "delivered") { crec.lastState(f.id) == .delivered }
        XCTAssertFalse(once.all.isEmpty, "the folder was switched mid-transfer")
        guard case .file(_, _, let saved)? = srec.received.first?.kind else { return XCTFail("not received") }
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL.path, old.standardizedFileURL.path)
        XCTAssertEqual(srec.receiveFailures, [])
        let g = cli.send(file: try randomFile(tempDir("dir-src2"), name: "next.bin", bytes: 1 << 20))
        await waitUntil(10, "the next one") { crec.lastState(g.id) == .delivered }
        guard case .file(_, _, let second)? = srec.received.last?.kind else { return XCTFail() }
        XCTAssertEqual(second.deletingLastPathComponent().standardizedFileURL.path, new.standardizedFileURL.path)
    }

    /// The same for a folder: it is built and saved where it started.
    func testFolderFinishesWhereItStartedWhenTheFolderChanges() async throws {
        let (srv, srec, port) = await startListener("fdir-srv", config: cfg("fdir-srv"))
        defer { srv.stop() }
        let (cli, crec) = startDialer("fdir-cli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        let old = srv.config.downloadDir, new = tempDir("fdir-new").appendingPathComponent("Other")
        let root = tempDir("fdir-src").appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<4 { _ = try randomFile(root, name: "p\(i).bin", bytes: 8 << 20) }
        let once = Recorder()
        srec.hook = { e in
            if case .incoming(let i) = e, case .receiving(let p) = i.state, p > 0.2, once.all.isEmpty { once.add(.status("x")); srv.setDownloadDir(new) }
        }
        let f = cli.send(folder: root)
        await waitUntil(30, "delivered") { crec.lastState(f.id) == .delivered }
        XCTAssertFalse(once.all.isEmpty)
        guard case .folder(_, _, _, let saved)? = srec.received.first?.kind else { return XCTFail("not received") }
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL.path, old.standardizedFileURL.path)
        XCTAssertEqual(srec.receiveFailures, [])
    }

    /// A resumed file needs room for the rest. If the disk filled up while the link was down, the receiver says
    /// so at once and throws the part away, instead of writing until the disk is full.
    func testResumeIsRefusedWhenThereIsNoRoomForTheRest() async throws {
        let (srv, srec, port) = await startListener("room-srv", config: cfg("room-srv"))
        defer { srv.stop() }
        let crec = Recorder()
        let cli = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: cfg("room-cli")) { crec.add($0) }
        cli.start()
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let dropped = Recorder()
        crec.hook = { e in
            guard case .outgoing(let i) = e, case .sending(let p) = i.state, dropped.all.isEmpty, p > 0.4 else { return }
            dropped.add(.status("x"))
            srv.setFreeSpaceForTests(1 << 20)   // 1 MiB left: not enough for the other 60 %
            cli.dropLink()
        }
        let f = cli.send(file: try randomFile(tempDir("room-src"), name: "big.bin", bytes: 60 << 20))
        await waitUntil(30, "refused after the reconnect") { if case .failed = crec.lastState(f.id) { return true }; return false }
        guard case .failed(let why)? = crec.lastState(f.id) else { return XCTFail() }
        XCTAssertTrue(why.contains("not enough disk space"), why)
        XCTAssertTrue(srec.receiveFailures.contains { $0.contains("not enough disk space") })
        XCTAssertEqual(srec.receiveFailureIDs, [f.id], "the failure names the item")
        XCTAssertTrue(srec.received.isEmpty)
        let parts = try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(parts, [], "the part is thrown away")
        let after = cli.send(text: "still talking")
        await waitUntil(10, "the link carries on") { crec.lastState(after.id) == .delivered }
    }

    /// Parts left by a run that ended without cleaning up are removed at the next start; nothing else is touched.
    func testOrphanPartsAreSwept() throws {
        let dir = tempDir("orphans")
        let fm = FileManager.default
        func make(_ name: String, hoursOld: Double, folder: Bool = false) throws {
            let u = dir.appendingPathComponent(name)
            if folder { try fm.createDirectory(at: u, withIntermediateDirectories: true); try Data("x".utf8).write(to: u.appendingPathComponent("inner.bin")) }
            else { try Data("x".utf8).write(to: u) }
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-hoursOld * 3600)], ofItemAtPath: u.path)
        }
        try make(".movie.mov.1A2B3C4D.part", hoursOld: 5)
        try make(".Trip photos.0F0F0F0F.part", hoursOld: 30, folder: true)
        try make(".fresh.bin.AAAAAAAA.part", hoursOld: 0.5)        // may still be resumed
        try make("notes.part", hoursOld: 50)                         // not ours: not hidden
        try make(".hidden.part", hoursOld: 50)                       // not ours: no id
        try make(".x.GGGGGGGG.part", hoursOld: 50)                   // not ours: not hex
        try make("visible.1A2B3C4D.part", hoursOld: 50)              // not ours: not hidden
        try make(".movie.mov.1A2B3C4D.partial", hoursOld: 50)
        try make("keep.jpg", hoursOld: 50)
        XCTAssertEqual(Session.sweepOrphans(in: dir, olderThan: 2 * 3600 + 600), 2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(),
                       [".fresh.bin.AAAAAAAA.part", ".hidden.part", ".movie.mov.1A2B3C4D.partial", ".x.GGGGGGGG.part", "keep.jpg", "notes.part", "visible.1A2B3C4D.part"])
        XCTAssertEqual(Session.sweepOrphans(in: dir.appendingPathComponent("missing"), olderThan: 1), 0)
        for (n, ok) in [(".a.1A2B3C4D.part", true), (".a.b.c.00000000.part", true), ("..1A2B3C4D.part", false), (".1A2B3C4D.part", false), (".a.1A2B3C4.part", false), (".a.１２３４５６７８.part", false)] {
            XCTAssertEqual(Session.isPartName(n), ok, n)
        }
    }

    /// The Hub swaps a partner's Session when its address changes. A half-received file survives the swap: the
    /// new Session carries on from where the old one stopped, in the folder the file started in.
    func testKeptPartialSurvivesASessionSwap() async throws {
        let (a, arec, port) = await startListener("swap-a", config: cfg("swap-a"))
        let crec = Recorder()
        let cli = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: cfg("swap-cli")) { crec.add($0) }
        cli.start()
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let original = try randomFile(tempDir("swap-src"), name: "big.bin", bytes: 60 << 20)
        let dropped = Recorder(), after = Recorder()
        crec.hook = { e in
            guard case .outgoing(let i) = e, case .sending(let p) = i.state else { return }
            if dropped.all.isEmpty, p > 0.4 { dropped.add(.status("x")); cli.hold() }
            else if !dropped.all.isEmpty, crec.connectedCount >= 2, after.all.isEmpty { after.add(.status("\(p)")) }
        }
        let f = cli.send(file: original)
        await waitUntil(30, "cut off") { arec.disconnects.count == 1 }
        let kept = a.stopKeepingPartials()
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(kept.values.first).part.path), "the part outlives the old Session")
        let brec = Recorder()
        let b = Session(role: .listener(port: port, bindHost: "127.0.0.1"), config: cfg("swap-b")) { brec.add($0) }
        b.adopt(partials: kept)
        b.start()
        defer { b.stop() }
        await waitUntil(5, "B listening") { brec.port != nil }
        cli.redialNow()
        await waitUntil(60, "delivered through the new Session") { crec.lastState(f.id) == .delivered }
        let first: Double? = after.all.first.flatMap { if case .status(let s) = $0 { return Double(s) }; return nil }
        XCTAssertGreaterThan(first ?? 0, 0.3, "carried on, not from the start (first progress after the swap: \(first ?? -1))")
        guard case .file(_, _, let saved)? = brec.received.first?.kind else { return XCTFail("not received") }
        XCTAssertEqual(try Hashing.sha256(of: saved), try Hashing.sha256(of: original), "byte-identical")
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL.path, a.config.downloadDir.standardizedFileURL.path, "where it started")
    }

    /// A plain stop (quitting) still throws kept parts away.
    func testStopDeletesKeptPartials() async throws {
        let (srv, srec, port) = await startListener("quit-srv", config: cfg("quit-srv"))
        let crec = Recorder()
        let cli = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: cfg("quit-cli")) { crec.add($0) }
        cli.start()
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let dropped = Recorder()
        crec.hook = { e in
            if case .outgoing(let i) = e, case .sending(let p) = i.state, dropped.all.isEmpty, p > 0.4 { dropped.add(.status("x")); cli.hold() }
        }
        _ = cli.send(file: try randomFile(tempDir("quit-src"), name: "big.bin", bytes: 60 << 20))
        await waitUntil(30, "cut off") { srec.disconnects.count == 1 }
        let dir = srv.config.downloadDir
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }.count, 1)
        srv.stop()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }, [])
    }

    /// The sender never saw our ack, so it sends a saved item again. It is acked and thrown away without a
    /// progress card: the card of the item already in the window must not go back to "receiving" and stay there.
    func testResendOfASavedItemShowsNoCard() async throws {
        let (srv, rec, port) = await startListener("resend", config: cfg("resend"))
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        let body = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sha = Data(SHA256.hash(data: body)).hex
        func sendOnce() async throws -> Frame? {
            try await c.send(Frame.fileBegin(id: "same-id", name: "report.pdf", size: Int64(body.count), sha256: nil))
            var off = 0
            while off < body.count { let n = min(256 << 10, body.count - off); try await c.send(body.subdata(in: off..<off + n)); off += n; try await Task.sleep(nanoseconds: 3_000_000) }
            try await c.send(Frame.fileEnd(id: "same-id", sha256: sha))
            while true { let f = await c.nextNonBeat(); if f?.type == "ack" || f == nil || f?.type == "timeout" { return f } }
        }
        let first = try await sendOnce()
        XCTAssertEqual(first?.ok, true)
        XCTAssertEqual(rec.received.count, 1)
        let cardsBefore = incoming(rec, "same-id").count
        let second = try await sendOnce()
        XCTAssertEqual(second?.ok, true, "the resend is acked")
        XCTAssertEqual(rec.received.count, 1, "and not delivered twice")
        XCTAssertEqual(incoming(rec, "same-id").count, cardsBefore, "no progress card for the resend")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path).sorted(), ["report.pdf"])
    }

    /// A failure names its item, so a window can match it to that item's card and to nothing else.
    func testReceiveFailuresNameTheirItem() async throws {
        var small = cfg("ids-srv")
        small.freeSpaceOverride = 1 << 20
        let (srv, srec, port) = await startListener("ids-srv", config: small)
        defer { srv.stop() }
        let (cli, crec) = startDialer("ids-cli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        let f = cli.send(file: try randomFile(tempDir("ids-src"), name: "report.pdf", bytes: 4 << 20))
        await waitUntil(10, "refused") { if case .failed = crec.lastState(f.id) { return true }; return false }
        XCTAssertEqual(srec.receiveFailureIDs, [f.id])
    }
}

/// Folder per computer: the folder is named after what the computer calls itself, as soon as it says so.
final class ReviewHubTests: XCTestCase {
    func testFolderPerComputerFollowsThePartnersName() async throws {
        let secret = Secrets.newToken()
        let ra = HubRecorder(), rb = HubRecorder()
        let a = Hub(config: hubConfig("Mac", device: "device-aaaa"), partners: [
            Partner(id: "device-bbbb", name: "New computer", secret: secret, role: "listen", hosts: [])]) { ra.add($0) }
        let base = tempDir("per-base")
        a.setDownloads(base: base, perComputer: true)
        a.start()
        defer { a.stop() }
        await waitUntil(5, "listening") { ra.port != nil }
        let b = Hub(config: hubConfig("Studio PC", device: "device-bbbb"), partners: [
            Partner(id: "device-aaaa", name: "Mac", secret: secret, role: "connect", hosts: ["127.0.0.1"], port: ra.port)]) { rb.add($0) }
        b.start()
        defer { b.stop() }
        await waitUntil(10, "connected") { ra.connected("device-bbbb") && rb.connected("device-aaaa") }
        func receivedFiles() -> [URL] { ra.all.compactMap { if case .received(_, let i) = $0, case .file(_, _, let u) = i.kind { return u }; return nil } }
        _ = b.send(file: try randomFile(tempDir("per-src"), name: "one.bin", bytes: 1 << 20), to: nil)
        await waitUntil(10, "first file") { receivedFiles().count == 1 }
        XCTAssertEqual(receivedFiles()[0].deletingLastPathComponent().lastPathComponent, "Studio PC", "not \"New computer\"")
        a.setName(partner: "device-bbbb", "Desk PC")   // renamed here
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = b.send(file: try randomFile(tempDir("per-src2"), name: "two.bin", bytes: 1 << 20), to: nil)
        await waitUntil(10, "second file") { receivedFiles().count == 2 }
        XCTAssertEqual(receivedFiles()[1].deletingLastPathComponent().lastPathComponent, "Desk PC")
    }
}
