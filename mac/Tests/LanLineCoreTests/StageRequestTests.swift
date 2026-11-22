import XCTest
@testable import LanLineCore

final class StageRequestTests: XCTestCase {
    func testRoundTripWithUnicodeAndSpaces() throws {
        let dir = tempDir("stage")
        let f = dir.appendingPathComponent("Q4 plan & notes ✓.pdf"); FileManager.default.createFile(atPath: f.path, contents: Data("x".utf8))
        let folder = dir.appendingPathComponent("Ünïcødé 📁"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r = StageRequest(paths: [f.path, folder.path], texts: ["https://example.com/a?b=1&c=2", "two\nlines #tag"])
        let back = try XCTUnwrap(StageRequest(url: try XCTUnwrap(r.url)))
        XCTAssertEqual(back, r)
    }

    func testRefusesWhatItShouldNot() {
        let ok: (String) -> Bool = { _ in true }
        XCTAssertNil(StageRequest(url: URL(string: "https://stage?p=/tmp/x")!, fileExists: ok), "other scheme")
        XCTAssertNil(StageRequest(url: URL(string: "lanline://send?p=/tmp/x")!, fileExists: ok), "only 'stage'")
        XCTAssertNil(StageRequest(url: URL(string: "lanline://stage")!, fileExists: ok), "nothing to stage")
        let r = StageRequest(url: URL(string: "lanline://stage?p=relative/x&p=/a/../etc/passwd&p=/missing&p=/ok&p=/ok&t=")!,
                             fileExists: { $0 != "/missing" })
        XCTAssertEqual(r?.paths, ["/ok"], "relative, '..', missing and duplicate paths dropped")
        XCTAssertNil(StageRequest(url: URL(string: "lanline://stage?p=/missing")!, fileExists: { _ in false }))
        var c = URLComponents(string: "lanline://stage")!
        c.queryItems = (0..<300).map { URLQueryItem(name: "p", value: "/f\($0)") } + [URLQueryItem(name: "t", value: String(repeating: "x", count: 100_001))]
        let big = StageRequest(url: c.url!, fileExists: ok)
        XCTAssertEqual(big?.paths.count, StageRequest.maxPaths); XCTAssertEqual(big?.texts, [])
    }
}
