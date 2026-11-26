import XCTest
@testable import LanLineCore

/// Where received files go and what happens after (beta.10); the PC runs the same cases ("receive options").
final class ReceiveOptionsTests: XCTestCase {
    func testFolders() {
        let base = URL(fileURLWithPath: "/Users/x/Downloads/Lan-Line", isDirectory: true)
        XCTAssertEqual(ReceiveOptions.folder(base: base, perComputer: false, partner: "Studio PC").path, "/Users/x/Downloads/Lan-Line")
        XCTAssertEqual(ReceiveOptions.folder(base: base, perComputer: true, partner: "Studio PC").path, "/Users/x/Downloads/Lan-Line/Studio PC")
        XCTAssertEqual(ReceiveOptions.folder(base: base, perComputer: true, partner: "../Evil/PC").lastPathComponent, "PC", "a name can't climb out (base name only)")
    }

    func testActions() {
        func a(_ s: AfterReceive, _ n: String, folder: Bool = false, opens: Int = 0) -> AfterReceive {
            ReceiveOptions.action(s, name: n, isFolder: folder, opensSoFar: opens)
        }
        XCTAssertEqual(a(.nothing, "x.png"), .nothing)
        XCTAssertEqual(a(.reveal, "setup.exe"), .reveal)
        XCTAssertEqual(a(.open, "Photo.HEIC"), .open)
        XCTAssertEqual(a(.open, "plan.pdf"), .open)
        XCTAssertEqual(a(.open, "clip.mov"), .open)
        for risky in ["setup.exe", "run.sh", "App.dmg", "tool.app", "x.ps1", "deck.docm", "a.zip", "noext"] {
            XCTAssertEqual(a(.open, risky), .reveal, risky)
        }
        XCTAssertEqual(a(.open, "Shoot", folder: true), .reveal, "folders are shown, not opened")
        XCTAssertEqual(a(.open, "4.png", opens: 3), .reveal, "at most 3 opens in a burst")
        XCTAssertEqual(AfterReceive.allCases.map(\.rawValue), ["nothing", "reveal", "open"])
    }

    /// A long stream of arrivals opens three files and shows the folder once; the count starts again only
    /// after a real quiet gap (measured from the last arrival, not the last open).
    func testBurstCapsOpensAndReveals() {
        var b = ArrivalBurst()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var did: [AfterReceive] = []
        for i in 0..<60 { did.append(b.next(.open, name: "p\(i).jpg", isFolder: false, at: t0.addingTimeInterval(Double(i)))) }   // one a second for a minute
        XCTAssertEqual(did.filter { $0 == .open }.count, 3)
        XCTAssertEqual(did.filter { $0 == .reveal }.count, 1)
        XCTAssertEqual(Array(did.prefix(5)), [.open, .open, .open, .reveal, .nothing])
        XCTAssertEqual(b.next(.open, name: "later.jpg", isFolder: false, at: t0.addingTimeInterval(59 + 4)), .nothing, "still the same burst")
        XCTAssertEqual(b.next(.open, name: "next.jpg", isFolder: false, at: t0.addingTimeInterval(63 + 6)), .open, "after a quiet gap it starts again")
        var r = ArrivalBurst()
        let shown = (0..<40).map { r.next(.reveal, name: "f\($0).zip", isFolder: false, at: t0.addingTimeInterval(Double($0) * 0.2)) }
        XCTAssertEqual(shown.filter { $0 == .reveal }.count, 1, "the folder comes forward once")
        XCTAssertEqual(r.next(.nothing, name: "x.jpg", isFolder: false, at: t0), .nothing)
        var e = ArrivalBurst()
        XCTAssertEqual(e.next(.open, name: "setup.exe", isFolder: false, at: t0), .reveal, "never opens what could run")
    }

    func testSettings() {
        var s = StorageSettings()
        XCTAssertNil(s.downloadFolderURL); XCTAssertFalse(s.folderPerComputerValue); XCTAssertEqual(s.afterReceiveValue, .nothing)
        s.downloadFolder = "/Users/x/Desktop"; s.afterReceive = "open"
        XCTAssertEqual(s.downloadFolderURL?.path, "/Users/x/Desktop"); XCTAssertEqual(s.afterReceiveValue, .open)
        s.afterReceive = "bogus"; s.downloadFolder = ""
        XCTAssertEqual(s.afterReceiveValue, .nothing); XCTAssertNil(s.downloadFolderURL)
    }

    func testSessionSwitchesFolder() async throws {
        let (srv, srec, port) = await startListener("folder-srv")
        defer { srv.stop() }
        let (cli, crec) = startDialer("folder-cli", port: port)
        defer { cli.stop() }
        await waitUntil(5, "connected") { crec.connectedCount == 1 }
        let src = tempDir("folder-src")
        let a = cli.send(file: try randomFile(src, name: "first.bin", bytes: 1000))
        await waitUntil(10, "first") { crec.lastState(a.id) == .delivered }
        let newDir = tempDir("folder-new").appendingPathComponent("Studio PC", isDirectory: true)
        srv.setDownloadDir(newDir)
        let b = cli.send(file: try randomFile(src, name: "second.bin", bytes: 1000))
        await waitUntil(10, "second") { crec.lastState(b.id) == .delivered }
        guard case .file(_, _, let u1)? = srec.received.first?.kind, case .file(_, _, let u2)? = srec.received.last?.kind else { return XCTFail() }
        XCTAssertNotEqual(u1.deletingLastPathComponent().path, newDir.path)
        XCTAssertEqual(u2.deletingLastPathComponent().standardizedFileURL.path, newDir.standardizedFileURL.path, "created on demand, used from then on")
    }
}
