import Foundation
import LanLineCore

/// `--headless` (optionally `--echo`) and `--selftest`: the same Session the window uses, without a window.
enum Headless {
    static func run(_ o: Options) -> Never {
        let cfg = o.loadConfig()
        let downloads = o.value("--downloads").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-headless-\(getpid())")
        var sc = SessionConfig(token: cfg.token, name: o.name, downloadDir: downloads)
        sc.chunkSize = (o.value("--chunk").flatMap(Int.init) ?? 256) * 1024   // KiB per binary frame
        sc.rekeyOnPair = o.flag("--rekey-on-pair")
        sc.appVersion = o.value("--app-version") ?? AppInfo.version   // tests: pretend to be another version   // tests: act as the code-showing side of a pairing
        if case .listener = o.role(cfg) { sc.advertise = Discovery.localAddresses() }
        let state = HeadlessState(selftest: o.flag("--selftest"), echo: o.flag("--echo"),
                                  sizeMB: o.value("--size").flatMap(Int.init) ?? 50)
        let session = Session(role: o.role(cfg), config: sc) { state.handle($0) }
        state.session = session
        state.sendText = o.value("--send-text")
        state.sendFile = o.value("--send-file").map { URL(fileURLWithPath: $0) }
        state.sendFolder = o.value("--send-folder").map { URL(fileURLWithPath: $0) }
        state.sendClip = o.value("--send-clip")
        state.dropAt = o.value("--drop-at").flatMap(Double.init)   // beta.10 checks: cut the link once mid-file (resume)
        state.cancelAt = o.value("--cancel-at").flatMap(Double.init)              // beta.10 checks: stop our own send at this fraction
        state.stopIncomingAt = o.value("--stop-incoming-at").flatMap(Double.init) // … or refuse an incoming one
        state.withFolder = o.flag("--with-folder")   // selftest: also round-trip a test folder (needs a beta.6 peer)
        state.log("start", ["mode": o.flag("--selftest") ? "selftest" : (o.flag("--echo") ? "echo" : "headless"),
                            "downloads": downloads.path])
        if state.selftest {
            do { try state.prepareFile(); if state.withFolder { try state.prepareFolder() } } catch { state.finish(false, "cannot make test file: \(error)") }
            let timeout = o.value("--timeout").flatMap(Double.init) ?? 180
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { state.finish(false, "timeout after \(Int(timeout)) s") }
        }
        if let d = o.value("--duration").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { state.summary(); exit(state.disconnects == 0 ? 0 : 1) }
        }
        signal(SIGINT) { _ in exit(130) }
        session.start()
        while true { RunLoop.main.run() }   // main-queue blocks then run on the main thread
    }
}

/// Mutated only from the Session's queue (its handler), apart from `finish`, which exits.
final class HeadlessState: @unchecked Sendable {
    let selftest: Bool, echo: Bool, sizeMB: Int
    var session: Session?
    var testFile: URL?
    var testSha = ""
    let testText = "lan-line selftest \(UUID().uuidString)\nline two ✓"
    var started = false, gotText = false, gotFile = false
    var connects = 0, disconnects = 0
    var sendText: String?          // --send-text: send once on connect, exit when delivered
    var sendFile: URL?             // --send-file: same, for a file
    var sendFolder: URL?           // --send-folder: same, for a folder
    var withFolder = false, gotFolder = false
    var cancelAt: Double?, stopIncomingAt: Double?
    var sendClip: String?
    var dropAt: Double?
    private var dropped = false, loggedAfterDrop = false
    private var cancelSent = false, stopSent = false
    var testFolder: URL?
    var testTree: [String: String] = [:]
    private var oneShot: Set<String> = []
    let t0 = Date()
    private let out = NSLock()

    init(selftest: Bool, echo: Bool, sizeMB: Int) { self.selftest = selftest; self.echo = echo; self.sizeMB = sizeMB }

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var d = fields
        d["event"] = event
        d["t"] = String(format: "%.1f", Date().timeIntervalSince(t0))
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        out.lock(); FileHandle.standardOutput.write(data + Data("\n".utf8)); out.unlock()
    }

    func prepareFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-selftest-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("selftest-\(sizeMB)MB.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        var g = SystemRandomNumberGenerator()
        for _ in 0..<sizeMB {
            var d = Data(count: 1 << 20)
            d.withUnsafeMutableBytes { b in for i in 0..<(1 << 17) { b.storeBytes(of: g.next(), toByteOffset: i * 8, as: UInt64.self) } }
            try h.write(contentsOf: d)
        }
        try h.close()
        testFile = url
        testSha = try Hashing.sha256(of: url)
    }

    /// Nested folders, an empty one, unicode names, 200 small files and one 8 MB file.
    func prepareFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-selftest-\(getpid())/Selftest Ünïcødé 📁")
        let fm = FileManager.default
        func put(_ rel: String, _ d: Data) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
        }
        try put("readme.txt", Data("top".utf8))
        try put("日本/ファイル.txt", Data("日本語".utf8))
        for i in 0..<200 { try put("d\(i % 7)/sub\(i % 3)/f\(i).txt", Data("file \(i)".utf8)) }
        var big = Data(count: 8 << 20); big.withUnsafeMutableBytes { b in for i in 0..<(1 << 20) { b.storeBytes(of: UInt64.random(in: 0...UInt64.max), toByteOffset: i * 8, as: UInt64.self) } }
        try put("a/b/c/big.bin", big)
        try fm.createDirectory(at: root.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)
        testFolder = root
        testTree = Self.manifest(root)
    }

    /// relative path → SHA-256 hex, or "dir".
    static func manifest(_ root: URL) -> [String: String] {
        var m: [String: String] = [:]
        let base = root.standardizedFileURL.pathComponents.count
        for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) ?? .init() {
            let rel = u.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            m[rel] = isDir ? "dir" : ((try? Hashing.sha256(of: u)) ?? "?")
        }
        return m
    }

    func handle(_ e: SessionEvent) {
        switch e {
        case .listening(let p): log("listening", ["port": Int(p)])
        case .connected(let peer):
            connects += 1
            log("connected", ["peer": peer])
            if let t = sendClip {   // beta.10 checks: one clipboard text, then exit when it went out
                let c = ClipContent.text(t)
                log("clip_fingerprint", ["fingerprint": ClipRules.fingerprint(c)])
                session?.sendClip(c) { ok in self.log(ok ? "clip_sent" : "clip_not_sent"); exit(ok ? 0 : 1) }
            }
            if !started, sendText != nil || sendFile != nil {
                started = true
                if let t = sendText, let id = session?.send(text: t).id { oneShot.insert(id) }
                if let f = sendFile, let id = session?.send(file: f).id { oneShot.insert(id) }
                if let f = sendFolder, let id = session?.send(folder: f).id { oneShot.insert(id) }
            }
            if selftest, !started, let f = testFile {
                started = true
                session?.send(text: testText)
                session?.send(file: f)
                if let d = testFolder { session?.send(folder: d) }
            }
        case .disconnected(let r): disconnects += 1; log("disconnected", ["reason": r])
        case .received(let item):
            switch item.kind {
            case .text(let t):
                log("received_text", ["chars": t.count])
                if echo { session?.send(text: t) }
                if selftest, t == testText { gotText = true; log("selftest_text_ok") }
            case .file(let name, let size, let url):
                let sha = (try? Hashing.sha256(of: url)) ?? "?"
                log("received_file", ["name": name, "size": size, "sha256": sha])
                if echo { session?.send(file: url) }
                if selftest, sha == testSha, size == Int64(sizeMB) << 20 { gotFile = true; log("selftest_file_ok", ["sha256": sha]) }
            case .folder(let name, let count, let size, let url):
                let same = withFolder && Self.manifest(url) == testTree
                log("received_folder", ["name": name, "count": count, "size": size, "identical": same])
                if echo { session?.send(folder: url) }
                if selftest, same { gotFolder = true; log("selftest_folder_ok") }
            }
            if selftest, gotText, gotFile, gotFolder || !withFolder {
                finish(true, "text and \(sizeMB) MB file\(withFolder ? " and a \(testTree.count)-entry folder" : "") came back intact")
            }
        case .outgoing(let item):
            switch item.state {
            case .delivered:
                log("delivered", ["id": item.id])
                if oneShot.remove(item.id) != nil, oneShot.isEmpty { log("sent_all"); exit(0) }
            case .failed(let why): log("send_failed", ["id": item.id, "why": why]); if selftest { finish(false, why) }
            case .sending(let p):
                if let at = dropAt, p >= at, !dropped { dropped = true; log("drop_link", ["at": p]); session?.dropLink() }
                else if dropped, connects >= 2, !loggedAfterDrop { loggedAfterDrop = true; log("first_progress_after_reconnect", ["at": p]) }
                if let at = cancelAt, p >= at, !cancelSent { cancelSent = true; log("cancel_sent", ["id": item.id, "at": p]); session?.cancel(item.id) }
            case .cancelled:
                log("cancelled", ["id": item.id])
                if oneShot.remove(item.id) != nil, let s = session {   // then prove the link is still in step
                    oneShot.insert(s.send(text: "after-cancel").id)
                }
            default: break
            }
        case .clipboard(let c):
            switch c {
            case .text(let t): log("clipboard_text", ["chars": t.count, "fingerprint": ClipRules.fingerprint(c)])
            case .png(let d): log("clipboard_png", ["bytes": d.count, "fingerprint": ClipRules.fingerprint(c)])
            }
        case .incoming(let item):
            log("incoming", ["id": item.id, "state": "\(item.state)"])
            if case .receiving(let p) = item.state, let at = stopIncomingAt, p >= at, !stopSent {
                stopSent = true; log("stop_incoming", ["id": item.id, "at": p]); session?.cancelIncoming(item.id)
            }
        case .receiveFailed(let name, let r, _): log("receive_failed", ["name": name, "reason": r]); if selftest { finish(false, r) }
        case .error(let s): log("error", ["message": s])
        case .status(let s): log("status", ["text": s])
        case .rekeyed: log("rekeyed", [:])
        case .peerAddresses(let a): log("peer_addresses", ["count": "\(a.count)"])
        case .updateAvailable(let v, let u): log("update_available", ["version": v, "url": u])
        case .peerDevice(let d): log("peer_device", ["device": d])
        }
    }

    func summary() { log("summary", ["connects": connects, "disconnects": disconnects]) }

    func finish(_ ok: Bool, _ why: String) {
        log(ok ? "SELFTEST PASS" : "SELFTEST FAIL", ["detail": why])
        if let f = testFile { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        exit(ok ? 0 : 1)
    }
}
