import XCTest
@testable import LanLineCore

/// The iPhone share sheet's queue and its knocks to the app (beta.10).
final class ShareQueueTests: XCTestCase {
    private func file(_ dir: URL, _ name: String, _ text: String = "hello") -> URL {
        let u = dir.appendingPathComponent(name)
        try? Data(text.utf8).write(to: u)
        return u
    }

    func testTextAndFilesWaitInOrder() throws {
        let q = ShareQueue(dir: tempDir("shareq"))
        let src = tempDir("shareq-src")
        let a = try q.add(text: "first", to: nil)
        let b = try q.add(file: file(src, "photo.jpg", "jpegbytes"), to: ["pc"])
        let folder = src.appendingPathComponent("Trip"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = file(folder, "a.txt")
        let c = try q.add(file: folder, to: nil)
        let all = q.pending()
        XCTAssertEqual(all.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(all.map(\.kind), ["text", "file", "folder"])
        XCTAssertNil(q.payload(all[0]))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(q.payload(all[1]))), "jpegbytes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("photo.jpg").path), "copied, not moved")
    }

    /// Twenty things shared in one go keep their order (the times on disk keep fractions of a second).
    func testManyAtOnceKeepTheirOrder() throws {
        let q = ShareQueue(dir: tempDir("shareq-many"))
        let ids = try (0..<20).map { try q.add(text: "item \($0)", to: nil).id }
        XCTAssertEqual(q.pending().map(\.id), ids)
        XCTAssertEqual(q.pending().compactMap(\.text), (0..<20).map { "item \($0)" })
    }

    /// A draft (the sheet is still asking who gets it) is never handed to anyone to send. Saying "send" makes it
    /// a normal job; one left unanswered is thrown away with its file.
    func testDraftsAreNeverSentAndAreSweptWhenAbandoned() throws {
        let q = ShareQueue(dir: tempDir("shareq-draft"))
        var photo = try q.add(file: file(tempDir("shareq-draft-src"), "private.jpg"), to: nil, draft: true)
        let note = try q.add(text: "abandoned", to: nil, draft: true)
        XCTAssertTrue(q.pending().isEmpty, "nothing to send while it is a draft")
        XCTAssertThrowsError(try { guard let j = q.pending().first else { throw CocoaError(.fileNoSuchFile) }; _ = try q.claim(j, into: tempDir("x")) }())
        photo.draft = nil; photo.to = ["pc"]; q.update(photo)   // the user picked and pressed Send
        XCTAssertEqual(q.pending().map(\.id), [photo.id])
        XCTAssertEqual(q.pending().first?.to, ["pc"])
        q.sweep(now: Date().addingTimeInterval(600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.dir.appendingPathComponent(note.id).path), "a few minutes old: the sheet may still be open")
        q.sweep(now: Date().addingTimeInterval(2 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.dir.appendingPathComponent(note.id).path), "abandoned: gone")
        XCTAssertEqual(q.pending().map(\.id), [photo.id], "the real job is untouched")
    }

    func testMoveTakesTheFile() throws {
        let q = ShareQueue(dir: tempDir("shareq-mv"))
        let src = file(tempDir("shareq-mv-src"), "clip.mov")
        let j = try q.add(file: src, to: nil, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(q.payload(j)).path))
    }

    func testLongTextIsCut() throws {
        let q = ShareQueue(dir: tempDir("shareq-long"))
        _ = try q.add(text: String(repeating: "x", count: ShareQueue.maxText + 50), to: nil)
        XCTAssertEqual(q.pending().first?.text?.count, ShareQueue.maxText)
    }

    func testDeliveredCrossesOffEachComputer() throws {
        let q = ShareQueue(dir: tempDir("shareq-del"))
        var j = try q.add(file: file(tempDir("shareq-del-src"), "doc.pdf"), to: nil)
        j.to = ["mac", "pc"]; q.update(j)
        XCTAssertEqual(q.pending().first?.to, ["mac", "pc"])
        XCTAssertFalse(q.delivered(j, to: "mac"))
        let left = try XCTUnwrap(q.pending().first)
        XCTAssertEqual(left.to, ["pc"])
        let kept = try XCTUnwrap(q.payload(left))
        XCTAssertTrue(q.delivered(left, to: "pc"))
        XCTAssertTrue(q.pending().isEmpty, "finished: no longer waiting")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "the file stays for the history until the sweep")
    }

    func testClaimMovesTheFileAndOnlyOneWins() throws {
        let q = ShareQueue(dir: tempDir("shareq-claim"))
        let j = try q.add(file: file(tempDir("shareq-claim-src"), "notes.txt", "abc"), to: nil)
        let t = try q.add(text: "a link", to: nil)
        let out = tempDir("shareq-outbox")
        let got = try XCTUnwrap(q.claim(j, into: out))
        XCTAssertEqual(got.lastPathComponent, "notes.txt")
        XCTAssertEqual(try String(contentsOf: got), "abc")
        XCTAssertThrowsError(try q.claim(j, into: out), "the second claim loses")
        XCTAssertNil(try q.claim(t, into: out), "text has no file")
        XCTAssertTrue(q.pending().isEmpty)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: q.dir.path)) ?? []).isEmpty, "nothing left behind")
    }

    func testDamagedAndOddEntriesAreSkipped() throws {
        let q = ShareQueue(dir: tempDir("shareq-bad"))
        let good = try q.add(text: "ok", to: nil)
        let fm = FileManager.default
        try fm.createDirectory(at: q.dir.appendingPathComponent("not json"), withIntermediateDirectories: true)
        let bad = q.dir.appendingPathComponent("11111111-2222"); try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("job.json"))
        let lost = try q.add(file: file(tempDir("shareq-bad-src"), "gone.bin"), to: nil)   // its file disappears
        try fm.removeItem(at: XCTUnwrap(q.payload(lost)))
        let other = q.dir.appendingPathComponent("AAAA-BBBB"); try fm.createDirectory(at: other, withIntermediateDirectories: true)   // id inside doesn't match its folder
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(ShareJob(id: "CCCC", kind: "text", text: "x", to: nil)).write(to: other.appendingPathComponent("job.json"))
        var escape = ShareJob(kind: "file", name: "../config.json", to: nil)
        XCTAssertNil(q.payload(escape), "a name can't climb out of the job's folder")
        escape.name = ".."; XCTAssertNil(q.payload(escape))
        XCTAssertEqual(q.pending().map(\.id), [good.id])
    }

    func testSweepRemovesOnlyOldFinishedJobs() throws {
        let q = ShareQueue(dir: tempDir("shareq-sweep"))
        let done = try q.add(file: file(tempDir("shareq-sweep-src"), "old.jpg"), to: ["pc"])
        let waiting = try q.add(text: "still waiting", to: nil)
        XCTAssertTrue(q.delivered(done, to: "pc"))
        q.sweep(now: Date().addingTimeInterval(86_400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.dir.appendingPathComponent(done.id).path), "a day old: kept")
        q.sweep(now: Date().addingTimeInterval(8 * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q.dir.appendingPathComponent(done.id).path), "a week old: gone")
        XCTAssertEqual(q.pending().map(\.id), [waiting.id], "waiting jobs are never swept")
    }

    func testMigrateMovesAnEarlierBuildsFilesOnce() throws {
        let old = tempDir("sharehome-old"), new = tempDir("sharehome-new").appendingPathComponent("Lan-Line")
        try Data("{\"a\":1}".utf8).write(to: old.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: old.appendingPathComponent("settings.json"))
        XCTAssertTrue(SharedHome.migrate(from: old, to: new))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("config.json")), "{\"a\":1}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("config.json").path))
        try Data("{\"b\":2}".utf8).write(to: old.appendingPathComponent("config.json"))
        XCTAssertFalse(SharedHome.migrate(from: old, to: new), "never over an existing pairing")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("config.json")), "{\"a\":1}")
        XCTAssertFalse(SharedHome.migrate(from: new, to: new))
    }

    func testSignalReachesItsListener() async throws {
        let name = "com.avery.lan-line.test.\(UUID().uuidString)"
        let hit = Recorder()
        let s = ShareSignal(name, queue: .global()) { hit.add(.status("knock")) }
        ShareSignal.post(name)
        await waitUntil(5, "the knock") { hit.all.count == 1 }
        withExtendedLifetime(s) {}
    }
}
