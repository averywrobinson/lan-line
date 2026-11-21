import XCTest
@testable import FerryCore

final class UnitTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(Names.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(Names.sanitize("..\\..\\Windows\\win.ini"), "win.ini")
        XCTAssertEqual(Names.sanitize(".."), "file")
        XCTAssertEqual(Names.sanitize(""), "file")
        XCTAssertEqual(Names.sanitize(".hidden"), "hidden")
        XCTAssertEqual(Names.sanitize("a..b.txt"), "a.b.txt")
        XCTAssertEqual(Names.sanitize("con<>:\"|?*trol\u{0007}.png"), "control.png")
        XCTAssertEqual(Names.sanitize("photo 1.jpg"), "photo 1.jpg")
        XCTAssertEqual(Names.sanitize("trailing. "), "trailing")
        XCTAssertLessThanOrEqual(Names.sanitize(String(repeating: "x", count: 500) + ".txt").count, 200)
        XCTAssertTrue(Names.sanitize(String(repeating: "x", count: 500) + ".txt").hasSuffix(".txt"))
    }

    func testUniqueNames() throws {
        let d = tempDir("unique")
        XCTAssertEqual(Names.unique("a.txt", in: d).lastPathComponent, "a.txt")
        FileManager.default.createFile(atPath: d.appendingPathComponent("a.txt").path, contents: Data())
        XCTAssertEqual(Names.unique("a.txt", in: d).lastPathComponent, "a (2).txt")
        FileManager.default.createFile(atPath: d.appendingPathComponent("a (2).txt").path, contents: Data())
        XCTAssertEqual(Names.unique("a.txt", in: d).lastPathComponent, "a (3).txt")
        FileManager.default.createFile(atPath: d.appendingPathComponent("noext").path, contents: Data())
        XCTAssertEqual(Names.unique("noext", in: d).lastPathComponent, "noext (2)")
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(Secrets.equal(testToken, testToken))
        XCTAssertFalse(Secrets.equal(testToken, String(testToken.dropLast()) + "c"))
        XCTAssertFalse(Secrets.equal(testToken, String(testToken.dropLast())))
        XCTAssertFalse(Secrets.equal("", testToken))
        let t = Secrets.newToken()
        XCTAssertEqual(t.count, 64)
        XCTAssertTrue(t.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(t, Secrets.newToken())
    }

    func testFrameRoundTrip() {
        let f = Frame.fileBegin(id: "1", name: "a.txt", size: 5, sha256: "00")
        XCTAssertEqual(Frame.decode(f.json), f)
        XCTAssertFalse(Frame.beat.json.contains("null"))
        XCTAssertNil(Frame.decode("not json"))
    }
}

final class PairingTests: XCTestCase {
    func testPairCodes() {
        let c = PairCode.generate()
        XCTAssertEqual(c.count, 10)
        XCTAssertEqual(PairCode.normalize(c), c)
        XCTAssertNotEqual(c, PairCode.generate())
        XCTAssertEqual(PairCode.display("ABCDE12345"), "ABCDE-12345")
        XCTAssertEqual(PairCode.normalize(" abcde-12345 "), "ABCDE12345")
        XCTAssertEqual(PairCode.normalize("oil0o-ILLIO"), "01100111" + "10")
        XCTAssertNil(PairCode.normalize("ABCDE-1234"))      // too short
        XCTAssertNil(PairCode.normalize("ABCDE-123456"))    // too long
        XCTAssertNil(PairCode.normalize("ABCDE-1234U"))     // U is not in the alphabet
        XCTAssertEqual(PairCode.pairID(token: "x").count, 8)
        XCTAssertEqual(PairCode.pairID(token: "x"), PairCode.pairID(token: "x"))
        XCTAssertNotEqual(PairCode.pairID(token: "x"), PairCode.pairID(token: "y"))
    }

    func testDiscoveryReplyRoundTrip() {
        let d = Discovery.reply(name: "Studio PC", port: 47830, pairID: "abcd1234")
        XCTAssertEqual(Discovery.parse(d, from: "10.0.0.5"), DiscoveredPeer(name: "Studio PC", host: "10.0.0.5", port: 47830, pairID: "abcd1234"))
        XCTAssertNil(Discovery.parse(Data("{\"lanline\":2}".utf8), from: "x"))
        XCTAssertNil(Discovery.parse(Data("junk".utf8), from: "x"))
        XCTAssertNil(Discovery.parse(Data("{\"lanline\":1,\"name\":\"a\",\"port\":70000,\"pair\":\"p\"}".utf8), from: "x"))
    }

    func testDiscoveryOverLoopback() throws {
        let q = DispatchQueue(label: "disc-test")
        let port: UInt16 = 47911
        let r = try DiscoveryResponder(port: port, name: "Test Mac", pairID: "feedbeef", queue: q)
        defer { r.close() }
        let done = expectation(description: "found")
        Discovery.search(port: port, timeout: 0.6, targets: ["127.0.0.1"], queue: q) { peers in
            XCTAssertEqual(peers, [DiscoveredPeer(name: "Test Mac", host: "127.0.0.1", port: port, pairID: "feedbeef")])
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    func testConfigSaveIsPrivateAndRoundTrips() throws {
        let url = tempDir("cfg").appendingPathComponent("config.json")
        let c = FerryConfig(token: "ABCDE12345", hosts: ["10.0.0.2"], role: "connect")
        try c.save(to: url)
        XCTAssertEqual(try FerryConfig.load(from: url), c)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(c.connects)
        XCTAssertFalse(FerryConfig(token: "t").connects)
    }
}
