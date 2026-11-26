import XCTest
@testable import LanLineCore

/// Clipboard sharing (beta.10); the PC runs the same cases ("clipboard sharing").
final class ClipTests: XCTestCase {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    func testRules() {
        let t = ClipContent.text("hello")
        XCTAssertTrue(ClipRules.shouldSend(t, types: ["public.utf8-plain-text"], enabled: true, paused: false, pictures: true, lastFingerprint: nil))
        XCTAssertFalse(ClipRules.shouldSend(t, types: [], enabled: false, paused: false, pictures: true, lastFingerprint: nil), "off")
        XCTAssertFalse(ClipRules.shouldSend(t, types: [], enabled: true, paused: true, pictures: true, lastFingerprint: nil), "paused")
        XCTAssertFalse(ClipRules.shouldSend(t, types: ["org.nspasteboard.ConcealedType"], enabled: true, paused: false, pictures: true, lastFingerprint: nil), "a password")
        XCTAssertFalse(ClipRules.shouldSend(t, types: [], enabled: true, paused: false, pictures: true, lastFingerprint: ClipRules.fingerprint(t)), "same again / the echo")
        XCTAssertFalse(ClipRules.shouldSend(.png(png), types: [], enabled: true, paused: false, pictures: false, lastFingerprint: nil), "pictures off")
        XCTAssertTrue(ClipRules.shouldSend(.png(png), types: [], enabled: true, paused: false, pictures: true, lastFingerprint: nil))
        XCTAssertFalse(ClipRules.fits(.text("")))
        XCTAssertFalse(ClipRules.fits(.text(String(repeating: "x", count: ClipRules.maxText + 1))))
        XCTAssertFalse(ClipRules.fits(.png(Data([1, 2, 3]))), "not a PNG")
        XCTAssertEqual(ClipRules.fingerprint(.text("hello")), "t:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "the same on Windows")
    }

    func testRoundTripAndNeverQueued() async throws {
        let (srv, srec, port) = await startListener("clip-srv")
        defer { srv.stop() }
        // not connected yet: dropped, not queued
        let early = Recorder()
        srv.sendClip(.text("too early")) { ok in early.add(.status(ok ? "sent" : "dropped")) }
        await waitUntil(5, "answer") { !early.all.isEmpty }
        XCTAssertEqual(early.all, [.status("dropped")])
        let (cli, crec) = startDialer("clip-cli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        cli.sendClip(.text("päste me ✓"))
        cli.sendClip(.png(png))
        srv.sendClip(.text("back"))
        await waitUntil(5, "clips") {
            srec.all.contains(.clipboard(.text("päste me ✓"))) && srec.all.contains(.clipboard(.png(self.png))) && crec.all.contains(.clipboard(.text("back")))
        }
        XCTAssertFalse(crec.all.contains(.clipboard(.text("too early"))))
        XCTAssertEqual(srec.received, [], "clips are not items")
    }

    func testOldPartnerGetsNothing() async throws {
        var old = makeConfig("clip-old"); old.caps = ["sha_end", "folders", "multi", "cancel"]   // a beta.6–9 side
        let (srv, srec, port) = await startListener("clip-old", config: old)
        defer { srv.stop() }
        let (cli, crec) = startDialer("clip-new", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        let r = Recorder()
        cli.sendClip(.text("x")) { ok in r.add(.status(ok ? "sent" : "dropped")) }
        cli.peerTakesClips { t in r.add(.status("takes \(t.map(String.init) ?? "nil")")) }
        await waitUntil(5, "answers") { r.all.count == 2 }
        XCTAssertEqual(r.all, [.status("dropped"), .status("takes false")])
    }

    func testClipArrivesDuringAFileTransfer() async throws {
        let (srv, srec, port) = await startListener("clip-mid")
        defer { srv.stop() }
        let (cli, crec) = startDialer("clip-mid-cli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let url = try randomFile(tempDir("clip-mid-src"), name: "big.bin", bytes: 30 << 20)
        let once = Recorder()
        crec.hook = { e in   // a clipboard change in the middle of a file
            if case .outgoing(let i) = e, case .sending(let p) = i.state, p > 0.2, once.all.isEmpty { once.add(.error("x")); cli.sendClip(.text("mid-file")) }
        }
        let f = cli.send(file: url)
        await waitUntil(30, "delivered") { crec.lastState(f.id) == .delivered }
        XCTAssertTrue(srec.all.contains(.clipboard(.text("mid-file"))))
        guard case .file(_, _, let saved)? = srec.received.first?.kind else { return XCTFail() }
        XCTAssertEqual(try Hashing.sha256(of: saved), try Hashing.sha256(of: url), "the file is intact around it")
    }
}
