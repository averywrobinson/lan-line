import XCTest
@testable import LanLineCore

/// Arrival notifications (beta.10). The same cases run on Windows ("arrival notices" in LanLine.Tests), so both
/// apps word their notifications identically.
final class ArrivalNoticeTests: XCTestCase {
    private func text(_ id: String, _ t: String) -> Item { Item(id: id, kind: .text(t), incoming: true, state: .received) }
    private func file(_ id: String, _ name: String, _ size: Int64) -> Item {
        Item(id: id, kind: .file(name: name, size: size, url: URL(fileURLWithPath: "/tmp/dl/\(name)")), incoming: true, state: .received)
    }
    private func folder(_ id: String, _ name: String, _ n: Int, _ size: Int64) -> Item {
        Item(id: id, kind: .folder(name: name, count: n, size: size, url: URL(fileURLWithPath: "/tmp/dl/\(name)")), incoming: true, state: .received)
    }

    func testText() {
        let n = ArrivalNotices.make([("Studio PC", text("a", "  hello\n\n  there  "))])
        XCTAssertEqual(n, ArrivalNotice(title: "Studio PC", body: "hello there", actions: [.copy], itemID: "a"))
    }

    func testLongTextCutsAtAWord() {
        let words = Array(repeating: "lorem", count: 60).joined(separator: " ")   // 359 characters
        let p = ArrivalNotices.preview(words)
        XCTAssertTrue(p.hasSuffix("lorem…"), p)
        XCTAssertLessThanOrEqual(p.count, ArrivalNotices.maxPreview + 1)
        XCTAssertEqual(p.count, 156)   // 26 words + 25 spaces + "…"
        XCTAssertEqual(ArrivalNotices.preview(String(repeating: "x", count: 200)), String(repeating: "x", count: 160) + "…")
        XCTAssertEqual(ArrivalNotices.preview(" \n\t "), "(empty message)")
    }

    func testFileAndPicture() {
        let pdf = ArrivalNotices.make([("MacBook Pro", file("f", "Q4 plan.pdf", 412_000))])
        XCTAssertEqual(pdf, ArrivalNotice(title: "MacBook Pro", body: "Q4 plan.pdf · 412 KB", actions: [.open, .reveal], itemID: "f"))
        let png = ArrivalNotices.make([("MacBook Pro", file("g", "Hero.PNG", 2_400_000))])
        XCTAssertEqual(png?.body, "Hero.PNG · 2 MB")
        XCTAssertEqual(png?.imagePath, "/tmp/dl/Hero.PNG")
    }

    func testFolder() {
        XCTAssertEqual(ArrivalNotices.make([("Studio PC", folder("d", "Photos", 1, 3_500_000_000))])?.body, "Photos · 1 file, 3.5 GB")
        XCTAssertEqual(ArrivalNotices.make([("Studio PC", folder("d", "Photos", 12, 40_000_000))])?.body, "Photos · 12 files, 40 MB")
    }

    func testBurstFromOneComputer() {
        let n = ArrivalNotices.make([("Studio PC", file("1", "a.png", 10)), ("Studio PC", text("2", "hi")),
                                     ("Studio PC", file("3", "b.txt", 10)), ("Studio PC", folder("4", "F", 2, 20))])
        XCTAssertEqual(n, ArrivalNotice(title: "Studio PC", body: "Sent you 2 files, 1 folder and 1 message"))
    }

    func testBurstFromSeveralComputers() {
        let n = ArrivalNotices.make([("Studio PC", text("1", "a")), ("Intel Mac", text("2", "b")), ("Studio PC", text("3", "c"))])
        XCTAssertEqual(n, ArrivalNotice(title: "Lan-Line", body: "3 messages from Studio PC and Intel Mac"))
    }

    func testFailedAndEmpty() {
        XCTAssertEqual(ArrivalNotices.failed(from: "Studio PC", name: "big.zip", reason: "not enough disk space"),
                       ArrivalNotice(title: "Couldn't receive big.zip", body: "From Studio PC: not enough disk space"))
        XCTAssertNil(ArrivalNotices.make([]))
    }

    func testSettingsDefaultOnAndRoundTrip() throws {
        XCTAssertTrue(StorageSettings().notifyOnArrivalValue)
        XCTAssertTrue(StorageSettings().popUpOnArrivalValue)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try #"{"retentionDays":0,"limitGB":10,"overLimit":"warn","trashReminder":true,"confirmed":true,"keepRunningWhenClosed":true}"#
            .write(to: url, atomically: true, encoding: .utf8)   // a beta.9 file
        var s = StorageSettings.load(from: url)
        XCTAssertTrue(s.notifyOnArrivalValue && s.popUpOnArrivalValue)
        s.notifyOnArrival = false; s.popUpOnArrival = false
        try s.save(to: url)
        let back = StorageSettings.load(from: url)
        XCTAssertFalse(back.notifyOnArrivalValue || back.popUpOnArrivalValue)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"notifyOnArrival\" : false") && json.contains("\"popUpOnArrival\" : false"))   // same keys as Windows
    }
}
