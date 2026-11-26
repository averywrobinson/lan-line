import XCTest
@testable import LanLineCore

/// Live progress for incoming items and cancelling from either side (beta.10). The PC runs the same cases
/// ("progress and cancel …" in LanLine.Tests), and the cross-machine selftests cover Mac ↔ PC.
/// Hooks run on the session queue and cancel right there: a queued cancel would land after a loopback transfer
/// has already finished.
final class TransferTests: XCTestCase {
    private func cfg(_ tag: String, cancelCap: Bool = true) -> SessionConfig {
        var c = makeConfig(tag)
        c.progressDelay = 0; c.progressInterval = 0.02
        if !cancelCap { c.caps = ["sha_end", "folders", "multi"] }   // a beta.6–beta.9 peer
        return c
    }

    private func pair(_ tag: String, receiverCancelCap: Bool = true) async -> (Session, Recorder, Session, Recorder) {
        let (srv, srec, port) = await startListener("\(tag)-srv", config: cfg("\(tag)-srv", cancelCap: receiverCancelCap))
        let (cli, crec) = startDialer("\(tag)-cli", port: port, config: cfg("\(tag)-cli"))
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        return (srv, srec, cli, crec)
    }

    private func incoming(_ r: Recorder, _ id: String) -> [ItemState] {
        r.all.compactMap { if case .incoming(let i) = $0, i.id == id { return i.state }; return nil }
    }

    private func leftovers(_ s: Session) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: s.config.downloadDir.path).filter { $0.hasSuffix(".part") }
    }

    func testIncomingProgressThenReceived() async throws {
        let (srv, srec, cli, crec) = await pair("prog")
        defer { srv.stop(); cli.stop() }
        let url = try randomFile(tempDir("prog-src"), name: "big.bin", bytes: 40 << 20)
        let f = cli.send(file: url)
        await waitUntil(60, "delivered") { crec.lastState(f.id) == .delivered }
        let states = incoming(srec, f.id)
        let fractions = states.compactMap { if case .receiving(let x) = $0 { return x }; return nil }
        XCTAssertGreaterThan(fractions.count, 1, "progress while arriving")
        XCTAssertEqual(fractions, fractions.sorted(), "never goes backwards")
        XCTAssertLessThanOrEqual(fractions.last ?? 2, 1)
        XCTAssertEqual(srec.received.map(\.id), [f.id], "then the file itself, same id")
        guard case .file(_, let size, _)? = states.isEmpty ? nil : srec.all.compactMap({ if case .incoming(let i) = $0 { return i.kind }; return nil }).first else { return XCTFail() }
        XCTAssertEqual(size, 40 << 20)
    }

    func testSmallFileGetsNoProgressCard() async throws {
        let (srv, srec, port) = await startListener("small-srv")   // default progressDelay (0.3 s)
        let (cli, crec) = startDialer("small-cli", port: port)
        defer { srv.stop(); cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        let f = cli.send(file: try randomFile(tempDir("small-src"), name: "s.bin", bytes: 200_000))
        await waitUntil(10, "delivered") { crec.lastState(f.id) == .delivered }
        XCTAssertEqual(incoming(srec, f.id), [])
    }

    /// The sender stops mid-file: `cancel` to a beta.10 receiver, which drops the part file quietly.
    func testSenderCancelsMidFile() async throws {
        let (srv, srec, cli, crec) = await pair("scan")
        defer { srv.stop(); cli.stop() }
        let url = try randomFile(tempDir("scan-src"), name: "stop.bin", bytes: 60 << 20)
        let once = Recorder()
        crec.hook = { e in
            if case .outgoing(let i) = e, case .sending(let p) = i.state, p > 0.1, once.all.isEmpty { once.add(.error("x")); cli.cancelOnQueue(i.id) }
        }
        let f = cli.send(file: url)
        await waitUntil(30, "cancelled") { crec.lastState(f.id) == .cancelled }
        let after = cli.send(text: "after")
        await waitUntil(10, "next item") { crec.lastState(after.id) == .delivered }
        await waitUntil(5, "receiver card cancelled") { self.incoming(srec, f.id).last == .cancelled }
        XCTAssertEqual(srec.received.map(\.id), [after.id])
        XCTAssertEqual(srec.receiveFailures, [], "a cancel isn't a failure")
        XCTAssertEqual(try leftovers(srv), [])
    }

    /// The same against a beta.6–beta.9 receiver: an early file_end, which it refuses as a size mismatch.
    func testSenderCancelsMidFileOldReceiver() async throws {
        let (srv, srec, cli, crec) = await pair("sold", receiverCancelCap: false)
        defer { srv.stop(); cli.stop() }
        let url = try randomFile(tempDir("sold-src"), name: "stop.bin", bytes: 60 << 20)
        let once = Recorder()
        crec.hook = { e in
            if case .outgoing(let i) = e, case .sending(let p) = i.state, p > 0.1, once.all.isEmpty { once.add(.error("x")); cli.cancelOnQueue(i.id) }
        }
        let f = cli.send(file: url)
        await waitUntil(30, "cancelled") { crec.lastState(f.id) == .cancelled }
        let after = cli.send(text: "after")
        await waitUntil(10, "next item") { crec.lastState(after.id) == .delivered }
        XCTAssertEqual(srec.received.map(\.id), [after.id])
        XCTAssertEqual(srec.receiveFailures, ["size mismatch"])
        XCTAssertEqual(try leftovers(srv), [])
        XCTAssertEqual(crec.lastState(f.id), .cancelled, "the late ack doesn't change it")
    }

    /// The receiver stops it: the same ack ok:false a full disk gives; the sender shows it as cancelled.
    func testReceiverCancelsMidFile() async throws {
        let (srv, srec, cli, crec) = await pair("rcan")
        defer { srv.stop(); cli.stop() }
        let url = try randomFile(tempDir("rcan-src"), name: "nope.bin", bytes: 60 << 20)
        let once = Recorder()
        srec.hook = { e in
            if case .incoming(let i) = e, case .receiving(let p) = i.state, p > 0.1, once.all.isEmpty { once.add(.error("x")); srv.cancelIncomingOnQueue(i.id) }
        }
        let f = cli.send(file: url)
        await waitUntil(30, "sender sees it cancelled") { crec.lastState(f.id) == .cancelled }
        XCTAssertEqual(incoming(srec, f.id).last, .cancelled)
        let after = cli.send(text: "after")
        await waitUntil(10, "next item") { crec.lastState(after.id) == .delivered }
        XCTAssertEqual(srec.received.map(\.id), [after.id])
        XCTAssertEqual(srec.receiveFailures, [])
        XCTAssertEqual(try leftovers(srv), [])
    }

    func testCancelQueuedItem() async throws {
        let (srv, srec, cli, crec) = await pair("queued")
        defer { srv.stop(); cli.stop() }
        let src = tempDir("queued-src")
        let big = cli.send(file: try randomFile(src, name: "first.bin", bytes: 40 << 20))
        let later = cli.send(file: try randomFile(src, name: "later.bin", bytes: 1 << 20))
        cli.cancel(later.id)
        await waitUntil(60, "first delivered") { crec.lastState(big.id) == .delivered }
        XCTAssertEqual(crec.lastState(later.id), .cancelled)
        XCTAssertEqual(srec.received.map(\.id), [big.id])
    }

    /// Cancelling a folder between two of its files (most of the time, with thousands of empty files) must hand
    /// the line to exactly one next item. Two files queued behind it both arrive whole, one after the other.
    func testFolderCancelledBetweenFilesStartsOnlyOneNextItem() async throws {
        for round in 0..<3 {
            let (srv, srec, cli, crec) = await pair("gap\(round)")
            let root = tempDir("gap-src").appendingPathComponent("Empties")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for i in 0..<3000 { FileManager.default.createFile(atPath: root.appendingPathComponent("e\(i)").path, contents: nil) }
            let b = try randomFile(tempDir("gap-b"), name: "b.bin", bytes: 6 << 20)
            let c = try randomFile(tempDir("gap-c"), name: "c.bin", bytes: 6 << 20)
            let folder = cli.send(folder: root)
            let sb = cli.send(file: b), sc = cli.send(file: c)
            try await Task.sleep(nanoseconds: UInt64(20_000_000 + round * 15_000_000))
            cli.cancel(folder.id)
            await waitUntil(20, "both files behind it arrive (round \(round))") {
                crec.lastState(sb.id) == .delivered && crec.lastState(sc.id) == .delivered
            }
            XCTAssertEqual(srec.received.compactMap { i -> String? in if case .file(let n, _, _) = i.kind { return n }; return nil }, ["b.bin", "c.bin"])
            XCTAssertEqual(try leftovers(srv), [])
            srv.stop(); cli.stop()
        }
    }

    func testFolderCancelledEitherSide() async throws {
        for receiverStops in [false, true] {
            let (srv, srec, cli, crec) = await pair(receiverStops ? "fr" : "fs")
            let root = tempDir("fold-src").appendingPathComponent("Shoot")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
            for i in 0..<6 { _ = try randomFile(root.appendingPathComponent(i < 3 ? "raw" : ""), name: "p\(i).bin", bytes: 10 << 20) }
            let once = Recorder()
            if receiverStops {
                srec.hook = { e in
                    if case .incoming(let i) = e, case .receiving(let p) = i.state, p > 0.3, once.all.isEmpty { once.add(.error("x")); srv.cancelIncomingOnQueue(i.id) }
                }
            } else {
                crec.hook = { e in
                    if case .outgoing(let i) = e, case .sending(let p) = i.state, p > 0.3, once.all.isEmpty { once.add(.error("x")); cli.cancelOnQueue(i.id) }
                }
            }
            let f = cli.send(folder: root)
            await waitUntil(30, "cancelled") { crec.lastState(f.id) == .cancelled }
            let after = cli.send(text: "after")
            await waitUntil(10, "next item") { crec.lastState(after.id) == .delivered }
            await waitUntil(5, "receiver card cancelled") { self.incoming(srec, f.id).last == .cancelled }
            XCTAssertEqual(srec.received.map(\.id), [after.id], "no folder lands")
            let names = try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path)
            XCTAssertEqual(names, [], "no folder and no hidden part folder: \(names)")
            srv.stop(); cli.stop()
        }
    }
}
