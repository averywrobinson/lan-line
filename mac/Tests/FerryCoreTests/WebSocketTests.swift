import XCTest
@testable import FerryCore

final class WebSocketTests: XCTestCase {
    func testAcceptKeyRFCExample() {
        XCTAssertEqual(WSFrame.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testRoundTripAllLengths() throws {
        for n in [0, 1, 125, 126, 127, 65535, 65536, 300_000] {
            let payload = Data((0..<n).map { UInt8($0 & 0xFF) })
            var server = WSParser(expectMasked: true, maxMessage: 1 << 20)
            XCTAssertEqual(try server.feed(WSFrame.encode(.binary, payload, maskKey: 0xA1B2C3D4)), [.binary(payload)], "masked \(n)")
            var client = WSParser(expectMasked: false, maxMessage: 1 << 20)
            XCTAssertEqual(try client.feed(WSFrame.encode(.binary, payload)), [.binary(payload)], "unmasked \(n)")
        }
    }

    func testByteByByteFeedAndTwoFramesInOneRead() throws {
        let a = WSFrame.encode(.text, Data("héllo ✓".utf8), maskKey: 7)
        let b = WSFrame.encode(.binary, Data(repeating: 9, count: 70_000), maskKey: 8)
        var p = WSParser(expectMasked: true, maxMessage: 1 << 20)
        var got: [WSEvent] = []
        for byte in a { got += try p.feed(Data([byte])) }
        XCTAssertEqual(got, [.text("héllo ✓")])
        XCTAssertEqual(try p.feed(b + a), [.binary(Data(repeating: 9, count: 70_000)), .text("héllo ✓")])
    }

    func testFragmentedMessageWithPingInside() throws {
        func frame(_ b0: UInt8, _ payload: [UInt8]) -> Data { Data([b0, UInt8(payload.count)] + payload) }   // unmasked
        var p = WSParser(expectMasked: false, maxMessage: 100)
        let parts = frame(0x01, Array("Hel".utf8)) + frame(0x89, [1, 2]) + frame(0x00, Array("lo ".utf8)) + frame(0x80, Array("you".utf8))
        XCTAssertEqual(try p.feed(parts), [.ping(Data([1, 2])), .text("Hello you")])
    }

    func testProtocolViolationsAreRejected() {
        func fails(_ d: Data, masked: Bool, code: UInt16, _ why: String) {
            var p = WSParser(expectMasked: masked, maxMessage: 1000)
            XCTAssertThrowsError(try p.feed(d), why) { XCTAssertEqual(($0 as? WSError)?.code, code, why) }
        }
        fails(WSFrame.encode(.text, Data("x".utf8)), masked: true, code: 1002, "unmasked frame to a server")
        fails(WSFrame.encode(.text, Data("x".utf8), maskKey: 1), masked: false, code: 1002, "masked frame to a client")
        fails(Data([0xC1, 0x00]), masked: false, code: 1002, "RSV1 set (no extensions negotiated)")
        fails(Data([0x83, 0x00]), masked: false, code: 1002, "unknown opcode 3")
        fails(Data([0x09, 0x00]), masked: false, code: 1002, "fragmented ping")
        fails(Data([0x89, 126, 0, 200]) + Data(count: 200), masked: false, code: 1002, "ping over 125 bytes")
        fails(Data([0x80, 0x00]), masked: false, code: 1002, "continuation without a start")
        fails(WSFrame.encode(.binary, Data(count: 1001)), masked: false, code: 1009, "message over the limit")
        fails(Data([0x81, 0x02, 0xC3, 0x28]), masked: false, code: 1007, "invalid UTF-8 text")
        fails(Data([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]), masked: false, code: 1009, "64-bit length with the top bit set")
    }

    func testHandshake() {
        let (req, key) = WSHandshake.request(host: "192.168.1.20", port: 47830)
        let parsed = WSHandshake.split(Array(req.utf8) + [1, 2, 3])!
        XCTAssertEqual(parsed.rest, [1, 2, 3])
        let resp = WSHandshake.respond(to: parsed.lines)!
        XCTAssertTrue(WSHandshake.accepts(WSHandshake.split(Array(resp.utf8))!.lines, key: key))
        XCTAssertFalse(WSHandshake.accepts(WSHandshake.split(Array(resp.utf8))!.lines, key: "other"))
        XCTAssertNil(WSHandshake.split(Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), "incomplete header block")
        XCTAssertNil(WSHandshake.respond(to: ["GET / HTTP/1.1", "Host: x"]), "plain HTTP is not an upgrade")
        XCTAssertNil(WSHandshake.respond(to: ["POST / HTTP/1.1", "Upgrade: websocket", "Connection: Upgrade",
                                             "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: abc"]), "not GET")
    }
}
