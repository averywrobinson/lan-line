import XCTest
import CryptoKit
import Darwin
@testable import LanLineCore

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

/// Shared with windows/LanLine.Tests (same inputs, same outputs). K_mac, MACs, Z and keys were checked
/// against Python's hashlib/hmac and OpenSSL's ECDH, independently of CryptoKit.
enum Vectors {
    static let secret = String(repeating: "0123456789abcdef", count: 4)
    static let dpriv = "96d378741622987330bc9c86cf6320db2a8d8b03ca1b41952d2b4f88afec9d87"   // SHA256("lan-line test dialer")
    static let spriv = "9766ee84697f1f685124f912fc0af0a138b71c7ba914c975f8e25cac1e15060d"   // SHA256("lan-line test listener")
    static let nonceC = Data(0..<32), nonceS = Data(32..<64)
    static let epkC = "043cdfbbfa399ce91b063c6c9a04886ac1c1052555919764e99558fc8d7acf6910a6e23a2bde6e33b5bbb83d3f0e126d66d1dec6c3c59795601fae93d55984a10d"
    static let epkS = "0474f4d2ce524a51341efdbcb8967d7507a2a9ec51ddf2eb03ccee3da2a5b15843d7883ec3b1667e24ac2a4f1b72fde364c4171d203eef7b671d59dc25a23918e9"
    static let kmac = "56369e54a9d7137a62150b0f8f7c0d06371df6e4913e6595b0b15905abf5a341"
    static let mac1 = "37379b5a9644fcdbb65e45a8e17b878f014b2a40d7d1671230e6b63f5d74cfd7"
    static let mac2 = "7a561db236359efc855431b3b296a7ba6f95b78b95fac0064399a71f1058179b"
    static let z = "6c976a76036dbc925297e872860722a812f6065d2ffcec403b86fcb95bb6e906"
    static let d2l = "103c2289e2ff41e4283a542ab18132c0d0fd5d0c595dd0adaf79652a4fd05056"
    static let l2d = "a875fa75ca95485fbc9bf0d903a7b7a63a6fe971bf5482b66cff7560f45346a8"
    /// Dialer → listener: message 0 = control `{"type":"beat"}`, message 1 = chunk 01 02 03.
    static let seal0 = "d63d5b918c65f89780b319df55d6430f8209dc095c73bc222e5fbccfb9e79b5a"
    static let seal1 = "d83d3bcc0edbe97cc896b0cde40d93f1024f8dcf"
}

final class CryptoTests: XCTestCase {
    private func keys() throws -> (P256.KeyAgreement.PrivateKey, P256.KeyAgreement.PrivateKey) {
        (try .init(rawRepresentation: unhex(Vectors.dpriv)), try .init(rawRepresentation: unhex(Vectors.spriv)))
    }

    func testVectors() throws {
        let (dc, ds) = try keys()
        XCTAssertEqual(hex(dc.publicKey.x963Representation), Vectors.epkC)
        XCTAssertEqual(hex(ds.publicKey.x963Representation), Vectors.epkS)
        XCTAssertEqual(hex(LL2.macKey(Vectors.secret).withUnsafeBytes { Data($0) }), Vectors.kmac)
        let hs = DialerHandshake(secret: Vectors.secret, name: "mac", priv: dc, nonce: Vectors.nonceC)
        XCTAssertEqual(hex(Data(base64Encoded: hs.hello.mac!)!), Vectors.mac1)
        let a = try XCTUnwrap(ListenerHandshake.answer(hs.hello, secrets: [Vectors.secret], name: "pc", priv: ds, nonce: Vectors.nonceS))
        XCTAssertEqual(hex(Data(base64Encoded: a.ok.mac!)!), Vectors.mac2)
        XCTAssertEqual(hex(LL2.z(dc, unhex(Vectors.epkS))!), Vectors.z)
        let t1 = LL2.t1(name: "mac", nonce: Vectors.nonceC, epk: unhex(Vectors.epkC))
        let k = LL2.sessionKeys(z: unhex(Vectors.z), secret: Vectors.secret, t2: LL2.t2(t1: t1, name: "pc", nonce: Vectors.nonceS, epk: unhex(Vectors.epkS)))
        XCTAssertEqual(hex(k.d2l), Vectors.d2l); XCTAssertEqual(hex(k.l2d), Vectors.l2d)
        let ch = try XCTUnwrap(hs.finish(a.ok))
        XCTAssertEqual(hex(ch.seal(.control, Data(#"{"type":"beat"}"#.utf8))!), Vectors.seal0)
        XCTAssertEqual(hex(ch.seal(.chunk, Data([1, 2, 3]))!), Vectors.seal1)
        // the listener's channel opens them in order
        XCTAssertEqual(a.channel.open(unhex(Vectors.seal0))?.1, Data(#"{"type":"beat"}"#.utf8))
        let second = a.channel.open(unhex(Vectors.seal1))
        XCTAssertEqual(second?.0, .chunk); XCTAssertEqual(second?.1, Data([1, 2, 3]))
    }

    func testHandshakeRefusals() throws {
        let s = Vectors.secret
        let hs = DialerHandshake(secret: s, name: "mac")
        XCTAssertNil(ListenerHandshake.answer(hs.hello, secrets: [String(repeating: "f", count: 64)], name: "pc"), "wrong secret")
        XCTAssertNil(ListenerHandshake.answer(hs.hello, secrets: [], name: "pc"))
        var e = hs.hello; e.epk = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        XCTAssertNil(ListenerHandshake.answer(e, secrets: [s], name: "pc"), "swapped epk (man in the middle)")
        var n = hs.hello; n.nonce = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertNil(ListenerHandshake.answer(n, secrets: [s], name: "pc"), "changed nonce")
        var nm = hs.hello; nm.name = "evil"
        XCTAssertNil(ListenerHandshake.answer(nm, secrets: [s], name: "pc"), "changed name")
        var v1 = hs.hello; v1.v = 1
        XCTAssertNil(ListenerHandshake.answer(v1, secrets: [s], name: "pc"))
        var junk = hs.hello; junk.epk = Data(repeating: 4, count: 65).base64EncodedString()
        XCTAssertNil(ListenerHandshake.answer(junk, secrets: [s], name: "pc"), "not a curve point")

        // the previous secret still matches and says so; a fake listener without the secret is refused
        let old = "ABCDE12345"
        let hs2 = DialerHandshake(secret: old, name: "mac")
        let a = try XCTUnwrap(ListenerHandshake.answer(hs2.hello, secrets: [s, old], name: "pc"))
        XCTAssertEqual(a.secretIndex, 1)
        XCTAssertNotNil(hs2.finish(a.ok))
        let fake = try XCTUnwrap(ListenerHandshake.answer(DialerHandshake(secret: "other", name: "x").hello, secrets: ["other"], name: "pc"))
        XCTAssertNil(hs2.finish(fake.ok), "hello_ok made without our secret")
        var tamperedOK = a.ok; tamperedOK.epk = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        XCTAssertNil(hs2.finish(tamperedOK))
    }

    func testChannelRejectsTamperReplayAndReorder() throws {
        let hs = DialerHandshake(secret: Vectors.secret, name: "mac")
        let a = try XCTUnwrap(ListenerHandshake.answer(hs.hello, secrets: [Vectors.secret], name: "pc"))
        let d = try XCTUnwrap(hs.finish(a.ok))
        let m0 = d.seal(.control, Data("zero".utf8))!, m1 = d.seal(.control, Data("one".utf8))!
        var flipped = m0; flipped[3] ^= 0x01
        let l1 = Channel(sendKey: Data(count: 32), recvKey: Data(count: 32))   // wrong keys
        XCTAssertNil(l1.open(m0))
        XCTAssertNil(a.channel.open(flipped), "bit flip")
        XCTAssertNil(a.channel.open(m1), "out of order: message 1 before 0")
        XCTAssertEqual(a.channel.open(m0)?.1, Data("zero".utf8))
        XCTAssertNil(a.channel.open(m0), "replay")
        XCTAssertEqual(a.channel.open(m1)?.1, Data("one".utf8))
        XCTAssertNil(d.open(m0), "a direction's key doesn't open the other direction")
        let back = a.channel.seal(.chunk, Data([9]))!
        XCTAssertEqual(d.open(back)?.1, Data([9]), "each direction counts from 0")
        XCTAssertNil(a.channel.open(Data(count: 10)), "too short")
    }
}

/// A TCP relay that records every byte both ways: what someone on the network would see.
final class TapProxy: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var bytes = Data()
    private let fd: Int32
    var captured: Data { lock.lock(); defer { lock.unlock() }; return bytes }

    init(target: UInt16) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        fd = s
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(s, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        port = UInt16(bigEndian: a.sin_port)
        run(target)
    }

    private func run(_ target: UInt16) {
        let lfd = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { return }
                let u = socket(AF_INET, SOCK_STREAM, 0)
                var t = sockaddr_in(); t.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); t.sin_family = sa_family_t(AF_INET)
                t.sin_port = target.bigEndian; t.sin_addr.s_addr = inet_addr("127.0.0.1")
                let rc = withUnsafePointer(to: &t) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(u, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                if rc != 0 { close(c); close(u); continue }
                pipe(c, u); pipe(u, c)
            }
        }
    }

    private func pipe(_ from: Int32, _ to: Int32) {
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(from, &buf, buf.count)
                if n <= 0 { shutdown(to, SHUT_WR); return }
                lock.lock(); bytes.append(contentsOf: buf[0..<n]); lock.unlock()
                var off = 0
                while off < n { let w = buf[off..<n].withUnsafeBytes { write(to, $0.baseAddress, n - off) }; if w <= 0 { return }; off += w }
            }
        }
    }

    func stop() { close(fd) }
}

final class WireTests: XCTestCase {
    /// Pair through the tap, send a marker text and a patterned file: none of it, and neither secret, is on the wire.
    func testNothingReadableOnTheWire() async throws {
        let code = "QWERT67890"
        var lc = makeConfig("wire-l"); lc.token = code; lc.rekeyOnPair = true; lc.advertise = ["10.9.8.7"]
        let (srv, srec, port) = await startListener("wire-l", config: lc)
        defer { srv.stop() }
        let tap = try TapProxy(target: port)
        defer { tap.stop() }
        var dc = makeConfig("wire-d"); dc.token = code
        let (cli, crec) = startDialer("wire-d", port: tap.port, config: dc)
        defer { cli.stop() }
        await waitUntil(5, "connected through the tap") { srec.connectedCount == 1 && crec.connectedCount == 1 }
        let secret = try XCTUnwrap(srec.all.compactMap { if case .rekeyed(let t) = $0 { return t }; return nil }.first)
        await waitUntil(5, "dialer got the secret") { crec.all.contains(.rekeyed(token: secret)) }
        await waitUntil(5, "dialer got the addresses") { crec.all.contains(.peerAddresses(["10.9.8.7"])) }

        let marker = "MARKER-\(UUID().uuidString)"
        let t = cli.send(text: marker)
        let dir = tempDir("wire-src")
        let pattern = Data(String(repeating: "LANLINE-PATTERN-", count: 40_000).utf8)   // 640 KB, three chunks
        let url = dir.appendingPathComponent("secret-plans.txt")
        try pattern.write(to: url)
        let f = cli.send(file: url)
        // also listener → dialer: those frames are unmasked, so masking alone can't hide anything there
        let t2 = srv.send(text: marker)
        let f2 = srv.send(file: url)
        await waitUntil(10, "delivered") {
            crec.lastState(t.id) == .delivered && crec.lastState(f.id) == .delivered &&
            srec.lastState(t2.id) == .delivered && srec.lastState(f2.id) == .delivered
        }

        let wire = tap.captured
        XCTAssertGreaterThan(wire.count, pattern.count, "the tap saw the transfer")
        XCTAssertNotNil(wire.range(of: Data("\"hello_ok\"".utf8)), "sanity: the tap does see plaintext (the listener's handshake)")
        for (what, needle) in [("marker", marker), ("file content", "LANLINE-PATTERN"), ("file name", "secret-plans"),
                               ("pairing code", code), ("long-term secret", secret), ("address", "10.9.8.7")] {
            XCTAssertNil(wire.range(of: Data(needle.utf8)), "\(what) is readable on the wire")
        }
    }

    /// A tampered message on a live link closes it; so does plaintext after the handshake.
    func testLiveLinkClosesOnTamperOrPlaintext() async throws {
        let (srv, rec, port) = await startListener("tamper")
        defer { srv.stop() }
        let c = RawClient(port: port)
        _ = try await c.hello()
        await waitUntil(5, "connected") { rec.connectedCount == 1 }
        try await c.sendPlainData(Data(repeating: 0x5a, count: 64))
        let r = await c.nextNonBeat(timeout: 5)
        XCTAssertNil(r, "closed")
        await waitUntil(5, "disconnect") { rec.disconnects.contains("decrypt failed") }
        c.close()

        let c2 = RawClient(port: port)
        _ = try await c2.hello()
        try await c2.sendPlain(.text(id: "p", text: "in the clear"))
        let r2 = await c2.nextNonBeat(timeout: 5)
        XCTAssertNil(r2, "closed")
        XCTAssertTrue(rec.received.isEmpty)
        c2.close()
    }

    /// A dialer with the wrong secret is refused with a clear reason and never connects.
    func testDialerWithWrongSecretIsRefused() async throws {
        let (srv, srec, port) = await startListener("wrong-l")
        defer { srv.stop() }
        var dc = makeConfig("wrong-d"); dc.token = String(repeating: "cd", count: 32)
        let (cli, crec) = startDialer("wrong-d", port: port, config: dc)
        defer { cli.stop() }
        await waitUntil(5, "refusal") { crec.all.contains(.status("Refused: the other computer doesn't know this pairing. Pair again.")) }
        XCTAssertEqual(crec.connectedCount, 0); XCTAssertEqual(srec.connectedCount, 0)
    }
}
