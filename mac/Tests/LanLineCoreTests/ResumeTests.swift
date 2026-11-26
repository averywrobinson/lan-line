import XCTest
@testable import LanLineCore

/// Resume after a dropped link (beta.10, "resume" cap); the PC runs the same cases ("resume …").
final class ResumeTests: XCTestCase {
    private func cfg(_ tag: String, resume: Bool = true) -> SessionConfig {
        var c = makeConfig(tag)
        c.progressInterval = 0.02
        if !resume { c.caps = ["sha_end", "folders", "multi", "cancel", "clip"] }
        return c
    }

    /// Drop the link from inside the handler once progress passes `at`; returns the first progress seen after
    /// the reconnect.
    private func dropAndResend(_ tag: String, receiverResume: Bool, senderResume: Bool = true, size: Int = 60 << 20)
        async throws -> (first: Double?, srec: Recorder, srv: Session, original: URL) {
        let (srv, srec, port) = await startListener("\(tag)-srv", config: cfg("\(tag)-srv", resume: receiverResume))
        let crec = Recorder()
        let cli = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: cfg("\(tag)-cli", resume: senderResume)) { crec.add($0) }
        cli.start()
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let url = try randomFile(tempDir("\(tag)-src"), name: "big.bin", bytes: size)
        let dropped = Recorder(), after = Recorder()
        crec.hook = { e in
            guard case .outgoing(let i) = e, case .sending(let p) = i.state else { return }
            if dropped.all.isEmpty, p > 0.4 { dropped.add(.status("\(p)")); cli.dropLink() }
            else if !dropped.all.isEmpty, crec.connectedCount >= 2, after.all.isEmpty { after.add(.status("\(p)")) }
        }
        let f = cli.send(file: url)
        await waitUntil(60, "delivered after reconnect") { crec.lastState(f.id) == .delivered }
        cli.stop()
        let first: Double? = after.all.first.flatMap { if case .status(let s) = $0 { return Double(s) }; return nil }
        return (first, srec, srv, url)
    }

    func testResumesFromWhereItStopped() async throws {
        let r = try await dropAndResend("res", receiverResume: true)
        defer { r.srv.stop() }
        XCTAssertGreaterThan(r.first ?? 0, 0.3, "carried on from where the link dropped (first progress after reconnect: \(r.first ?? -1))")
        XCTAssertEqual(r.srec.received.count, 1)
        guard case .file(_, _, let saved)? = r.srec.received.first?.kind else { return XCTFail() }
        XCTAssertEqual(try Hashing.sha256(of: saved), try Hashing.sha256(of: r.original), "byte-identical")
        let parts = try FileManager.default.contentsOfDirectory(atPath: r.srv.config.downloadDir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(parts, [])
    }

    func testOlderReceiverStartsOver() async throws {
        let r = try await dropAndResend("res-old", receiverResume: false)
        defer { r.srv.stop() }
        XCTAssertLessThan(r.first ?? 1, 0.3, "no resume cap: from the start")
        guard case .file(_, _, let saved)? = r.srec.received.first?.kind else { return XCTFail() }
        XCTAssertEqual(try Hashing.sha256(of: saved), try Hashing.sha256(of: r.original))
    }

    func testOlderSenderStartsOver() async throws {
        let r = try await dropAndResend("res-oldsend", receiverResume: true, senderResume: false)
        defer { r.srv.stop() }
        XCTAssertLessThan(r.first ?? 1, 0.3, "the sender doesn't offer: from the start")
        guard case .file(_, _, let saved)? = r.srec.received.first?.kind else { return XCTFail() }
        XCTAssertEqual(try Hashing.sha256(of: saved), try Hashing.sha256(of: r.original))
        let parts = try FileManager.default.contentsOfDirectory(atPath: r.srv.config.downloadDir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(parts, [], "no partial kept for a sender that can't resume")
    }

    func testDamagedPartialIsCaughtByTheHash() async throws {
        // Corrupt the kept partial while the link is down: the whole-file hash must refuse the result.
        let (srv, srec, port) = await startListener("res-bad-srv", config: cfg("res-bad-srv"))
        defer { srv.stop() }
        let crec = Recorder()
        let cli = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: cfg("res-bad-cli")) { crec.add($0) }
        cli.start()
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let url = try randomFile(tempDir("res-bad-src"), name: "big.bin", bytes: 60 << 20)
        let dropped = Recorder()
        let dir = srv.config.downloadDir
        crec.hook = { e in
            guard case .outgoing(let i) = e, case .sending(let p) = i.state, dropped.all.isEmpty, p > 0.4 else { return }
            dropped.add(.status("x")); cli.dropLink()
        }
        let f = cli.send(file: url)
        await waitUntil(10, "dropped") { !dropped.all.isEmpty && srec.disconnects.count >= 1 }
        if let part = try FileManager.default.contentsOfDirectory(atPath: dir.path).first(where: { $0.hasSuffix(".part") }) {
            let h = try FileHandle(forWritingTo: dir.appendingPathComponent(part))
            try h.seek(toOffset: 1000); try h.write(contentsOf: Data(repeating: 0xEE, count: 64)); try h.close()
        } else { XCTFail("no partial kept") }
        await waitUntil(60, "finished") { if case .failed = crec.lastState(f.id) { return true }; return crec.lastState(f.id) == .delivered }
        XCTAssertEqual(crec.lastState(f.id), .failed("sha256 mismatch"))
        XCTAssertEqual(srec.received.count, 0, "nothing damaged lands")
    }
}
