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
        sc.rekeyOnPair = o.flag("--rekey-on-pair")   // tests: act as the code-showing side of a pairing
        let state = HeadlessState(selftest: o.flag("--selftest"), echo: o.flag("--echo"),
                                  sizeMB: o.value("--size").flatMap(Int.init) ?? 50)
        let session = Session(role: o.role(cfg), config: sc) { state.handle($0) }
        state.session = session
        state.sendText = o.value("--send-text")
        state.sendFile = o.value("--send-file").map { URL(fileURLWithPath: $0) }
        state.log("start", ["mode": o.flag("--selftest") ? "selftest" : (o.flag("--echo") ? "echo" : "headless"),
                            "downloads": downloads.path])
        if state.selftest {
            do { try state.prepareFile() } catch { state.finish(false, "cannot make test file: \(error)") }
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

    func handle(_ e: SessionEvent) {
        switch e {
        case .listening(let p): log("listening", ["port": Int(p)])
        case .connected(let peer):
            connects += 1
            log("connected", ["peer": peer])
            if !started, sendText != nil || sendFile != nil {
                started = true
                if let t = sendText, let id = session?.send(text: t).id { oneShot.insert(id) }
                if let f = sendFile, let id = session?.send(file: f).id { oneShot.insert(id) }
            }
            if selftest, !started, let f = testFile {
                started = true
                session?.send(text: testText)
                session?.send(file: f)
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
            }
            if selftest, gotText, gotFile { finish(true, "text and \(sizeMB) MB file came back intact") }
        case .outgoing(let item):
            switch item.state {
            case .delivered:
                log("delivered", ["id": item.id])
                if oneShot.remove(item.id) != nil, oneShot.isEmpty { log("sent_all"); exit(0) }
            case .failed(let why): log("send_failed", ["id": item.id, "why": why]); if selftest { finish(false, why) }
            default: break
            }
        case .receiveFailed(let name, let r): log("receive_failed", ["name": name, "reason": r]); if selftest { finish(false, r) }
        case .error(let s): log("error", ["message": s])
        case .status(let s): log("status", ["text": s])
        case .rekeyed: log("rekeyed", [:])
        }
    }

    func summary() { log("summary", ["connects": connects, "disconnects": disconnects]) }

    func finish(_ ok: Bool, _ why: String) {
        log(ok ? "SELFTEST PASS" : "SELFTEST FAIL", ["detail": why])
        if let f = testFile { try? FileManager.default.removeItem(at: f) }
        exit(ok ? 0 : 1)
    }
}
