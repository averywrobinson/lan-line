import XCTest
@testable import LanLineCore

final class UnitTests: XCTestCase {
    /// beta.11: a photo or video handed over with a machine-made name gets a readable one; a chosen name is kept.
    func testReadableMediaNames() {
        let at = Date(timeIntervalSince1970: 1795706841)   // 2026-11-26 15:27:21 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Names.readableMedia("AE54C04B-B03D-4001-9031-43ABB62B1F37.MP4", at: at, timeZone: utc), "Video 2026-11-26 at 15.27.21.MP4")
        XCTAssertEqual(Names.readableMedia("trim.6F1C2A90-1B2C-4D3E-8F90-0A1B2C3D4E5F.MOV", at: at, timeZone: utc), "Video 2026-11-26 at 15.27.21.MOV")
        XCTAssertEqual(Names.readableMedia("9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d.heic", at: at, timeZone: utc), "Photo 2026-11-26 at 15.27.21.heic")
        XCTAssertEqual(Names.readableMedia("IMG_0042.HEIC", at: at, timeZone: utc), "IMG_0042.HEIC")
        XCTAssertEqual(Names.readableMedia("holiday.jpg", at: at, timeZone: utc), "holiday.jpg")
        XCTAssertEqual(Names.readableMedia("cafe.mov", at: at, timeZone: utc), "cafe.mov", "short hex-looking words stay")
        XCTAssertEqual(Names.readableMedia("AE54C04B-B03D-4001-9031-43ABB62B1F37.pdf", at: at, timeZone: utc),
                       "AE54C04B-B03D-4001-9031-43ABB62B1F37.pdf", "only photos and videos are renamed")
        XCTAssertFalse(Names.readableMedia("AE54C04B-B03D-4001-9031-43ABB62B1F37.MP4", at: at).contains(":"))
    }

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
        let c = LanLineConfig(token: "ABCDE12345", hosts: ["10.0.0.2"], role: "connect")
        try c.save(to: url)
        XCTAssertEqual(try LanLineConfig.load(from: url), c)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(c.connects)
        XCTAssertFalse(LanLineConfig(token: "t").connects)
    }
}

final class StorageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func file(_ name: String, daysAgo: Double, gb: Double) -> ReceivedFile {
        ReceivedFile(path: "/x/\(name)", size: Int64(gb * 1_000_000_000), receivedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testDefaultsDeleteNothingAndWarnAt80Percent() {
        let s = StorageSettings()
        XCTAssertEqual(s.retentionDays, 0); XCTAssertEqual(s.limitGB, 10); XCTAssertEqual(s.overLimit, "warn"); XCTAssertFalse(s.confirmed)
        let p = Cleanup.plan([file("a", daysAgo: 400, gb: 5), file("b", daysAgo: 1, gb: 3.5)], settings: s, now: now)
        XCTAssertTrue(p.toTrash.isEmpty)
        XCTAssertEqual(p.level, 1)   // 8.5 of 10 GB
        let over = Cleanup.plan([file("a", daysAgo: 2, gb: 7), file("b", daysAgo: 1, gb: 4)], settings: s, now: now)
        XCTAssertTrue(over.toTrash.isEmpty); XCTAssertEqual(over.level, 2)
    }

    func testRetentionMovesOnlyOldFiles() {
        var s = StorageSettings(); s.retentionDays = 30; s.limitGB = 0
        let p = Cleanup.plan([file("old", daysAgo: 31, gb: 1), file("edge", daysAgo: 30, gb: 1), file("new", daysAgo: 29, gb: 1)], settings: s, now: now)
        XCTAssertEqual(p.expired.map(\.path), ["/x/old", "/x/edge"])
        XCTAssertEqual(p.level, 0)
    }

    func testTrashModeMovesOldestUntilUnderLimitButKeepsNewest() {
        var s = StorageSettings(); s.limitGB = 10; s.overLimit = "trash"
        let p = Cleanup.plan([file("c", daysAgo: 1, gb: 4), file("a", daysAgo: 3, gb: 4), file("b", daysAgo: 2, gb: 4)], settings: s, now: now)
        XCTAssertEqual(p.overLimit.map(\.path), ["/x/a"])
        XCTAssertEqual(p.usageBytes, 8_000_000_000); XCTAssertEqual(p.level, 1)
        let huge = Cleanup.plan([file("big", daysAgo: 0, gb: 30)], settings: s, now: now)
        XCTAssertTrue(huge.overLimit.isEmpty); XCTAssertEqual(huge.level, 2)
    }

    func testQuietWarnings() {
        var s = StorageSettings()
        XCTAssertTrue(Cleanup.shouldWarnLimit(s, level: 1, now: now))
        XCTAssertFalse(Cleanup.shouldWarnLimit(s, level: 0, now: now))
        s.lastLimitWarning = now.addingTimeInterval(-3_600)
        XCTAssertFalse(Cleanup.shouldWarnLimit(s, level: 2, now: now))
        XCTAssertTrue(Cleanup.shouldRemindTrash(s, movedSomething: true, now: now))
        XCTAssertFalse(Cleanup.shouldRemindTrash(s, movedSomething: false, now: now))
        s.lastTrashReminder = now.addingTimeInterval(-13 * 86_400)
        XCTAssertFalse(Cleanup.shouldRemindTrash(s, movedSomething: true, now: now))
        s.lastTrashReminder = nil; s.trashReminder = false
        XCTAssertFalse(Cleanup.shouldRemindTrash(s, movedSomething: true, now: now))
    }

    func testSettingsAndLogRoundTrip() throws {
        let d = tempDir("store")
        var s = StorageSettings(); s.retentionDays = 60; s.confirmed = true; s.lastTrashReminder = now
        try s.save(to: d.appendingPathComponent("settings.json"))
        XCTAssertEqual(StorageSettings.load(from: d.appendingPathComponent("settings.json")), s)
        XCTAssertEqual(StorageSettings.load(from: d.appendingPathComponent("missing.json")), StorageSettings())
        let files = [file("a", daysAgo: 1, gb: 1)]
        try ReceivedLog.save(files, to: d.appendingPathComponent("received.json"))
        XCTAssertEqual(ReceivedLog.load(from: d.appendingPathComponent("received.json")), files)
    }
}
