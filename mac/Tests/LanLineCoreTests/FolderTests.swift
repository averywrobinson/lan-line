import XCTest
import CryptoKit
@testable import LanLineCore

/// A connected listener + dialer pair on loopback.
func connectedPair(_ tag: String, listener lc: SessionConfig? = nil, dialer dc: SessionConfig? = nil) async -> (Session, Recorder, Session, Recorder) {
    let (srv, srec, port) = await startListener("\(tag)-l", config: lc)
    let (cli, crec) = startDialer("\(tag)-d", port: port, config: dc)
    await waitUntil(5, "connected") { srec.connectedCount == 1 && crec.connectedCount == 1 }
    return (srv, srec, cli, crec)
}

/// Every file and folder under `root`, as relative path → SHA-256 hex ("dir" for folders).
func tree(_ root: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    let base = root.standardizedFileURL.path
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
    for case let u as URL in e {
        let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
        let isDir = (try u.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
        out[rel] = isDir ? "dir" : try Hashing.sha256(of: u)
    }
    return out
}

func write(_ s: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(s.utf8).write(to: url)
}

/// A test folder: nested, an empty folder, unicode names, a 3 MB file.
func sampleFolder(_ tag: String, name: String = "Project Ünïcødé 📁") throws -> URL {
    let root = tempDir(tag).appendingPathComponent(name)
    try write("top", root.appendingPathComponent("readme.txt"))
    try write("deep", root.appendingPathComponent("a/b/c/deep.txt"))
    try write("日本語", root.appendingPathComponent("日本/ファイル.txt"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("empty/inner-empty"), withIntermediateDirectories: true)
    _ = try randomFile(root.appendingPathComponent("a"), name: "big.bin", bytes: 3 << 20)
    return root
}

private func sparseFile(_ dir: URL, name: String, size: UInt64) throws -> URL {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: size)
    try h.close()
    return url
}

final class TooBigTests: XCTestCase {
    /// The receiver refuses at file_begin; the sender doesn't hash a 200 GB file first (that would take minutes).
    func testTooBigRefusedBeforeHashing() async throws {
        var lc = makeConfig("big-l"); lc.freeSpaceOverride = 10 << 30   // 10 GB free
        let (srv, srec, cli, crec) = await connectedPair("big", listener: lc)
        defer { srv.stop(); cli.stop() }
        let huge = try sparseFile(tempDir("big-src"), name: "huge.bin", size: 200_000_000_000)
        let start = Date()
        let item = cli.send(file: huge)
        await waitUntil(5, "refused") { if case .failed = crec.lastState(item.id) { return true }; return false }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard case .failed(let why)? = crec.lastState(item.id) else { return XCTFail() }
        XCTAssertTrue(why.contains("not enough disk space"), why)
        XCTAssertTrue(why.contains("200"), "says how big: \(why)")
        await waitUntil(5, "receiver noted it") { !srec.receiveFailures.isEmpty }
        XCTAssertTrue(srec.receiveFailures.first?.contains("not enough disk space") ?? false)
        // the link is still usable afterwards
        let t = cli.send(text: "still here")
        await waitUntil(5, "text after refusal") { crec.lastState(t.id) == .delivered }
    }

    /// The sanity bound (1 TiB) is also checked up front.
    func testOverSanityBoundRefused() async throws {
        let (srv, _, cli, crec) = await connectedPair("bound")
        defer { srv.stop(); cli.stop() }
        let huge = try sparseFile(tempDir("bound-src"), name: "2tb.bin", size: 2 << 40)
        let item = cli.send(file: huge)
        await waitUntil(5, "refused") { if case .failed = crec.lastState(item.id) { return true }; return false }
    }

    /// beta.5 peers (no caps) still exchange files both ways, the old way (hash first, sha in file_begin).
    func testOldPeersStillWork() async throws {
        var old = makeConfig("old"); old.caps = []
        for (lc, dc) in [(old, makeConfig("new")), (makeConfig("new"), old)] {
            let (srv, srec, cli, crec) = await connectedPair("compat", listener: lc, dialer: dc)
            let src = try randomFile(tempDir("compat-src"), name: "c.bin", bytes: 700_000)
            let a = cli.send(file: src), b = srv.send(file: src)
            await waitUntil(10, "delivered both ways") { crec.lastState(a.id) == .delivered && srec.lastState(b.id) == .delivered }
            guard case .file(_, _, let got)? = srec.received.first?.kind else { return XCTFail() }
            XCTAssertEqual(try Hashing.sha256(of: got), try Hashing.sha256(of: src))
            srv.stop(); cli.stop()
        }
    }
}

final class FolderTests: XCTestCase {
    private func folders(_ r: Recorder) -> [(name: String, count: Int, size: Int64, url: URL)] {
        r.received.compactMap { if case .folder(let n, let c, let s, let u) = $0.kind { return (n, c, s, u) }; return nil }
    }

    func testFolderBothWaysAndClash() async throws {
        let (srv, srec, cli, crec) = await connectedPair("fold")
        defer { srv.stop(); cli.stop() }
        let src = try sampleFolder("fold-src")
        let want = try tree(src)
        let a = cli.send(folder: src)
        guard case .folder(let name, let count, let size, _) = a.kind else { return XCTFail() }
        XCTAssertEqual(name, "Project Ünïcødé 📁"); XCTAssertEqual(count, 4); XCTAssertEqual(size, Int64(3 << 20) + 3 + 4 + 9)
        let b = srv.send(folder: src)
        await waitUntil(15, "delivered both ways") { crec.lastState(a.id) == .delivered && srec.lastState(b.id) == .delivered }
        let gotL = try XCTUnwrap(folders(srec).first), gotD = try XCTUnwrap(folders(crec).first)
        XCTAssertEqual(gotL.count, 4); XCTAssertEqual(gotL.size, size)
        XCTAssertEqual(try tree(gotL.url), want, "listener copy identical, empty folders included")
        XCTAssertEqual(try tree(gotD.url), want, "dialer copy identical")
        XCTAssertEqual(gotL.url.lastPathComponent, "Project Ünïcødé 📁")
        // the same folder again lands next to it as "… (2)"; no staging folders are left behind
        let c = cli.send(folder: src)
        await waitUntil(15, "second copy") { crec.lastState(c.id) == .delivered }
        XCTAssertEqual(folders(srec).last?.url.lastPathComponent, "Project Ünïcødé 📁 (2)")
        let left = try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(left, [])
    }

    func testLargeTree() async throws {
        let (srv, srec, cli, crec) = await connectedPair("tree")
        defer { srv.stop(); cli.stop() }
        let root = tempDir("tree-src").appendingPathComponent("many")
        for i in 0..<300 { try write("file \(i)", root.appendingPathComponent("d\(i % 12)/sub\(i % 5)/f\(i).txt")) }
        _ = try randomFile(root, name: "large.bin", bytes: 20 << 20)
        let item = cli.send(folder: root)
        await waitUntil(30, "delivered") { crec.lastState(item.id) == .delivered }
        XCTAssertEqual(try tree(try XCTUnwrap(folders(srec).first).url), try tree(root))
        XCTAssertEqual(folders(srec).first?.count, 301)
    }

    /// Symlinks are never followed: one pointing out of the tree (and one inside it) are left out, and the chip says so.
    func testSymlinksAreSkipped() async throws {
        let (srv, srec, cli, crec) = await connectedPair("link")
        defer { srv.stop(); cli.stop() }
        let outside = tempDir("link-secret").appendingPathComponent("secret.txt")
        try write("do not send", outside)
        let root = tempDir("link-src").appendingPathComponent("withlinks")
        try write("ok", root.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("up"), withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside.txt"), withDestinationURL: root.appendingPathComponent("real.txt"))
        let item = cli.send(folder: root)
        await waitUntil(10, "delivered") { crec.lastState(item.id) == .delivered }
        XCTAssertEqual(try tree(try XCTUnwrap(folders(srec).first).url), ["real.txt": try Hashing.sha256(of: root.appendingPathComponent("real.txt"))])
        XCTAssertEqual(Session.scanFolder(root).skipped, 3)
    }

    func testFolderTooBigRefusedUpFront() async throws {
        var lc = makeConfig("ftb-l"); lc.freeSpaceOverride = 2 << 20
        let (srv, srec, cli, crec) = await connectedPair("ftb", listener: lc)
        defer { srv.stop(); cli.stop() }
        let item = cli.send(folder: try sampleFolder("ftb-src"))
        await waitUntil(5, "refused") { if case .failed(let w) = crec.lastState(item.id) { return w.contains("not enough disk space") }; return false }
        await waitUntil(5, "receiver noted it") { !srec.receiveFailures.isEmpty }
        XCTAssertTrue(folders(srec).isEmpty)
    }

    /// A beta.5 peer can't take folders: the sender says to update it instead of sending.
    func testFolderToOldPeerSaysUpdate() async throws {
        var old = makeConfig("fold-old-l"); old.caps = []
        let (srv, _, cli, crec) = await connectedPair("fold-old", listener: old)
        defer { srv.stop(); cli.stop() }
        let item = cli.send(folder: try sampleFolder("fold-old-src"))
        await waitUntil(5, "refused") { if case .failed(let w) = crec.lastState(item.id) { return w.contains("Update Lan-Line") }; return false }
    }

    /// A hostile peer can't write outside the received folder.
    func testPathEscapeRefused() async throws {
        let (srv, rec, port) = await startListener("escape")
        defer { srv.stop() }
        for bad in ["../evil.txt", "a/../../evil.txt", "/etc/evil.txt", "a\\..\\..\\evil.txt", "", "a//b", "."] {
            let c = RawClient(port: port)
            _ = try await c.hello()
            try await c.send(.folderBegin(id: "F", name: "x", count: 1, size: 4))
            try await c.send(.fileBegin(id: "f1", name: "evil.txt", size: 4, sha256: nil, folder: "F", path: bad))
            try await c.send(Data("evil".utf8))
            try await c.send(.fileEnd(id: "f1", sha256: Data(SHA256.hash(data: Data("evil".utf8))).hex))
            try await c.send(.folderEnd(id: "F"))
            var ack: Frame?
            repeat { ack = await c.nextNonBeat() } while ack != nil && ack?.type != "ack"
            XCTAssertEqual(ack?.ok, false, "path \(bad) must be refused")
            c.close()
        }
        let parent = srv.config.downloadDir.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("evil.txt").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: srv.config.downloadDir.path).isEmpty)
        XCTAssertTrue(rec.received.isEmpty)
    }
}
