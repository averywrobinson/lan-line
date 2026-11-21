import XCTest
@testable import LanLineCore

final class UpdateTests: XCTestCase {
    func testVersionParseAndOrder() {
        for good in ["0.9.0-beta.6", "1.0.0", "0.10.2", "12.0.0-beta.10", "0.0.0"] { XCTAssertNotNil(LanLineVersion(good), good) }
        for bad in ["v1.0.0", "1.0", "1.0.0.0", "1.0.0-rc.1", "1.0.0-beta.", "1.0.0-beta", "01.0.0", "1.0.0-beta.06", " 1.0.0",
                    "1.0.0 ", "1.0.0\n", "1.0.0-beta.6+x", "1234567.0.0", "１.0.0", "", "-1.0.0", "1..0", "1.0.0-BETA.1"] {
            XCTAssertNil(LanLineVersion(bad), "should refuse \(bad.debugDescription)")
        }
        let order = ["0.9.0-beta.5", "0.9.0-beta.6", "0.9.0-beta.10", "0.9.0", "0.9.1-beta.1", "0.10.0", "1.0.0"].map { LanLineVersion($0)! }
        XCTAssertEqual(order, order.sorted())
        for (a, b) in zip(order, order.dropFirst()) { XCTAssertLessThan(a, b); XCTAssertFalse(b < a) }
        XCTAssertEqual(LanLineVersion("0.9.0-beta.6")?.description, "0.9.0-beta.6")
    }

    func testURLAllowlist() {
        for ok in ["https://averywrobinson.com/lan-line/", "https://averywrobinson.com/lan-line/#download",
                   "https://github.com/averywrobinson/lan-line/releases/tag/v0.9.0-beta.6", "https://github.com/averywrobinson/lan-line/releases"] {
            XCTAssertTrue(Updates.isAllowedURL(ok), ok)
        }
        for bad in ["http://averywrobinson.com/lan-line/", "https://averywrobinson.com/lan-line", "https://averywrobinson.com/",
                    "https://averywrobinson.com.evil.com/lan-line/", "https://evil.com/https://averywrobinson.com/lan-line/",
                    "https://averywrobinson.com/lan-line/../evil", "https://averywrobinson.com/lan-line//evil.com",
                    "https://github.com/averywrobinson/lan-line-evil/", "https://github.com/evil/lan-line/",
                    "https://github.com/averywrobinson/lan-line/@evil.com", "https://github.com/averywrobinson/lan-line/x?y=1",
                    "https://github.com/averywrobinson/lan-line/x y", "https://github.com/averywrobinson/lan-line/\nx",
                    "javascript:alert(1)", "HTTPS://averywrobinson.com/lan-line/", "https://averywrobinson.com/lan-line/ä",
                    "https://averywrobinson.com/lan-line/" + String(repeating: "a", count: 300), ""] {
            XCTAssertFalse(Updates.isAllowedURL(bad), "should refuse \(bad.debugDescription)")
        }
    }

    func testVersionJSON() {
        let good = #"{"version":"0.9.1","released":"2026-12-01","url":"https://github.com/averywrobinson/lan-line/releases/tag/v0.9.1","notes_url":"https://averywrobinson.com/lan-line/"}"#
        XCTAssertEqual(Updates.parse(versionJSON: Data(good.utf8))?.version, LanLineVersion("0.9.1"))
        XCTAssertNil(Updates.parse(versionJSON: Data(good.replacingOccurrences(of: "github.com", with: "evil.com").utf8)))
        XCTAssertNil(Updates.parse(versionJSON: Data(good.replacingOccurrences(of: "0.9.1\"", with: "v0.9.1\"").utf8)))
        XCTAssertNil(Updates.parse(versionJSON: Data("<html>".utf8)))
        XCTAssertNil(Updates.parse(versionJSON: Data(count: 70_000)))
    }

    /// No network, a refused port, a bad file: always `.failed`, and an automatic check says nothing.
    func testFailedChecksAreQuiet() async {
        let r = await Updates.fetchLatest(current: "0.9.0-beta.6", from: URL(string: "http://127.0.0.1:9/lan-line/version.json")!)
        XCTAssertEqual(r, .failed)
        let r2 = await Updates.fetchLatest(current: "not-a-version")   // returns before any network use
        XCTAssertEqual(r2, .failed)
        XCTAssertNil(Updates.message(.failed, manual: false))
        XCTAssertNil(Updates.message(.upToDate(LanLineVersion("1.0.0")!), manual: false))
        XCTAssertNotNil(Updates.message(.failed, manual: true))
        XCTAssertEqual(Updates.message(.available(.init(version: LanLineVersion("1.0.0")!, url: "https://averywrobinson.com/lan-line/")), manual: false),
                       "Lan-Line 1.0.0 is available")
    }

    func testAutoCheckOffByDefault() throws {
        let now = Date()
        XCTAssertFalse(Updates.dueForAutoCheck(StorageSettings(), now: now), "off unless turned on")
        // a beta.5 settings file (no update keys) keeps its values and stays off
        let old = #"{"confirmed":true,"limitGB":25,"overLimit":"trash","retentionDays":30,"trashReminder":false}"#
        let url = tempDir("upd").appendingPathComponent("settings.json")
        try Data(old.utf8).write(to: url)
        let s = StorageSettings.load(from: url)
        XCTAssertEqual(s.retentionDays, 30); XCTAssertTrue(s.confirmed)
        XCTAssertFalse(Updates.dueForAutoCheck(s, now: now))
        var on = StorageSettings(); on.autoUpdateCheck = true
        XCTAssertTrue(Updates.dueForAutoCheck(on, now: now))
        on.lastUpdateCheck = now.addingTimeInterval(-3600)
        XCTAssertFalse(Updates.dueForAutoCheck(on, now: now), "once a day at most")
        on.lastUpdateCheck = now.addingTimeInterval(-25 * 3600)
        XCTAssertTrue(Updates.dueForAutoCheck(on, now: now))
    }

    private func updates(_ r: Recorder) -> [String] {
        r.all.compactMap { if case .updateAvailable(let v, let u) = $0 { return "\(v) \(u)" }; return nil }
    }

    /// The older side hears about the newer one's version, and about what the newer side knows of.
    func testPeerRelay() async throws {
        var lc = makeConfig("rel-l"); lc.appVersion = "0.9.0-beta.6"
        lc.latestKnown = .init(version: LanLineVersion("0.9.1")!, url: "https://averywrobinson.com/lan-line/")
        var dc = makeConfig("rel-d"); dc.appVersion = "0.9.0-beta.5"
        let (srv, srec, cli, crec) = await connectedPair("rel", listener: lc, dialer: dc)
        defer { srv.stop(); cli.stop() }
        await waitUntil(5, "dialer told") { self.updates(crec).contains("0.9.1 https://averywrobinson.com/lan-line/") }
        XCTAssertTrue(updates(srec).isEmpty, "the newer side hears nothing new")
        // a check on the dialer finds something newer still: the listener hears about it through the link
        cli.noteLatest(.init(version: LanLineVersion("0.9.2")!, url: "https://github.com/averywrobinson/lan-line/releases/tag/v0.9.2"))
        await waitUntil(5, "relayed") { self.updates(srec).contains("0.9.2 https://github.com/averywrobinson/lan-line/releases/tag/v0.9.2") }
    }

    func testPeerVersionAloneLinksReleasePage() async throws {
        var lc = makeConfig("pv-l"); lc.appVersion = "0.9.0-beta.7"
        var dc = makeConfig("pv-d"); dc.appVersion = "0.9.0-beta.6"
        let (srv, _, cli, crec) = await connectedPair("pv", listener: lc, dialer: dc)
        defer { srv.stop(); cli.stop() }
        await waitUntil(5, "told") { self.updates(crec) == ["0.9.0-beta.7 https://github.com/averywrobinson/lan-line/releases/tag/v0.9.0-beta.7"] }
    }

    /// A peer can't push an arbitrary link or a malformed version.
    func testPeerCantPushBadLinks() async throws {
        var cfg = makeConfig("bad-l"); cfg.appVersion = "0.9.0-beta.6"
        let (srv, rec, port) = await startListener("bad-l", config: cfg)
        defer { srv.stop() }
        let c = RawClient(port: port)
        defer { c.close() }
        _ = try await c.hello()
        for (v, u) in [("9.9.9", "https://evil.com/lan-line/"), ("9.9.9", "https://averywrobinson.com/lan-line/../../evil"),
                       ("v9.9.9", "https://averywrobinson.com/lan-line/"), ("9.9.9 ", "https://averywrobinson.com/lan-line/")] {
            try await c.send(Frame.versionInfo("0.9.0-beta.5", latest: .init(version: v, url: u)))
        }
        var f = Frame(type: "version"); f.version = "9.9.9\nclick https://evil.com"
        try await c.send(f)
        try await c.send(.text(id: "after", text: "done"))
        await waitUntil(5, "text after") { !rec.received.isEmpty }
        XCTAssertTrue(updates(rec).isEmpty, "nothing shown: \(updates(rec))")
    }

    /// site/version.json (what the apps fetch) must parse and name the version in VERSION.
    func testSiteVersionFileMatchesVERSION() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardizedFileURL
        let file = try Data(contentsOf: root.appendingPathComponent("site/version.json"))
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let a = try XCTUnwrap(Updates.parse(versionJSON: file))
        XCTAssertEqual(a.version.description, version)
        XCTAssertTrue(a.url.hasSuffix("/v\(version)"))
    }
}
