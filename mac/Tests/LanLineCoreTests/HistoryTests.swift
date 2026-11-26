import XCTest
@testable import LanLineCore

/// History and search (beta.10); the PC runs the same cases ("history and search").
final class HistoryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_764_000_000)
    func text(_ id: String, _ t: String, at s: Double = 0, who: String = "Studio PC") -> HistoryEntry {
        HistoryEntry(id: id, incoming: true, kind: "text", text: t, at: t0 + s, who: who, state: "received")
    }
    func file(_ id: String, _ n: String, kind: String = "file", at s: Double = 0) -> HistoryEntry {
        HistoryEntry(id: id, incoming: false, kind: kind, name: n, size: 10, path: "/tmp/\(n)", at: t0 + s, who: "Studio PC", state: "delivered")
    }

    func testRoundTripDedupeOrderAndBadLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(History.fileName)
        XCTAssertEqual(History.load(from: url), [])
        try History.append(text("b", "second", at: 2), to: url)
        try History.append(text("a", "first", at: 1), to: url)
        var failed = file("c", "x.zip", at: 3); failed.state = "failed"; failed.error = "no space"
        try History.append(failed, to: url)
        var again = text("b", "second, edited", at: 2)
        again.state = "received"
        try History.append(again, to: url)
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("not json\n{}\n".utf8)); try h.close()
        let back = History.load(from: url)
        XCTAssertEqual(back.map(\.id), ["a", "b", "c"], "oldest first, one per id")
        XCTAssertEqual(back[1].text, "second, edited", "the last line for an id wins")
        XCTAssertEqual(back[2].error, "no space")
    }

    func testCapAndCompactAndLongText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(History.fileName)
        let many = (0..<(History.cap + 25)).map { text("i\($0)", "n\($0)", at: Double($0)) }
        try History.compact(many, to: url)
        let back = History.load(from: url)
        XCTAssertEqual(back.count, History.cap)
        XCTAssertEqual(back.first?.id, "i25", "the oldest drop off")
        try History.append(text("long", String(repeating: "x", count: 30_000), at: 5_000), to: url)
        XCTAssertEqual(History.load(from: url).last?.text?.count, History.maxText)
        History.clear(url)
        XCTAssertEqual(History.load(from: url), [])
    }

    func testSearchWordsAccentsCase() {
        let e = text("1", "Le Résumé is in the Q4 folder", who: "Studio PC")
        XCTAssertTrue(History.matches(e, query: "resume q4", filter: .all))
        XCTAssertTrue(History.matches(e, query: "  RÉSUMÉ  ", filter: .all))
        XCTAssertTrue(History.matches(e, query: "studio", filter: .all), "the computer's name counts")
        XCTAssertFalse(History.matches(e, query: "resume q5", filter: .all), "every word must match")
        XCTAssertTrue(History.matches(file("2", "Café Menu.PDF"), query: "cafe pdf", filter: .all))
        XCTAssertTrue(History.matches(e, query: "", filter: .all))
    }

    func testFilters() {
        let t = text("1", "hello"), link = text("2", "see https://example.com/a?b=1"), www = text("3", "try www.example.org")
        let pic = file("4", "IMG_2041.HEIC"), pdf = file("5", "plan.pdf"), dir = file("6", "Shoot", kind: "folder")
        let all = [t, link, www, pic, pdf, dir]
        func ids(_ f: HistoryFilter) -> [String] { all.filter { History.matches($0, query: "", filter: f) }.map(\.id) }
        XCTAssertEqual(ids(.all), ["1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(ids(.text), ["1", "2", "3"])
        XCTAssertEqual(ids(.links), ["2", "3"])
        XCTAssertEqual(ids(.pictures), ["4"])
        XCTAssertEqual(ids(.files), ["4", "5", "6"])
        XCTAssertEqual(HistoryFilter.allCases.map(\.title), ["All", "Text", "Pictures", "Files", "Links"])
    }

    func testSetting() {
        XCTAssertTrue(StorageSettings().keepHistoryValue)
    }
}
