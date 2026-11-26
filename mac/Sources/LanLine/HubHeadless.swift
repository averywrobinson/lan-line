import Foundation
import LanLineCore

/// `--headless --hub` / `--selftest --hub`: the Hub (all partners in config.json's `peers`) without a window.
/// Echo sends each received item back to the partner it came from. Selftest waits for `--expect N` partners
/// (default: all), sends a text, a file (and with --with-folder a folder) to everyone, and passes when every
/// partner has sent each one back intact.
enum HubHeadless {
    static func run(_ o: Options) -> Never {
        let dev: DeviceConfig
        do { dev = try DeviceConfig.load(from: o.configURL, defaultRole: "listen") } catch {
            FileHandle.standardError.write(Data("lan-line: cannot read \(o.configURL.path): \(error)\n".utf8)); exit(2)
        }
        let downloads = o.value("--downloads").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-hub-\(getpid())")
        var hc = HubConfig(name: o.name, deviceID: dev.deviceID, downloadDir: downloads)
        hc.port = o.value("--port").flatMap(UInt16.init) ?? dev.port
        hc.bindHost = o.value("--bind")
        hc.appVersion = o.value("--app-version") ?? AppInfo.version
        let to = o.value("--to")   // selftest: send to this partner id only (default: everyone)
        let expect = o.value("--expect").flatMap(Int.init) ?? (to == nil ? dev.peers.count : 1)
        let st = HubRun(selftest: o.flag("--selftest"), echo: o.flag("--echo"), expect: expect,
                        need: o.value("--need").flatMap(Int.init) ?? (to == nil ? dev.peers.count : 1), to: to,
                        names: Dictionary(uniqueKeysWithValues: dev.peers.map { ($0.id, $0.name) }))
        if st.selftest {
            let h = HeadlessState(selftest: true, echo: false, sizeMB: o.value("--size").flatMap(Int.init) ?? 20)
            do { try h.prepareFile(); if o.flag("--with-folder") { try h.prepareFolder() } } catch { st.finish(false, "cannot make test files: \(error)") }
            st.files = h
            let timeout = o.value("--timeout").flatMap(Double.init) ?? 120
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { st.finish(false, "timeout after \(Int(timeout)) s: \(st.missing())") }
        }
        if let d = o.value("--duration").flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + d) { st.log("summary", [:]); exit(0) } }
        let hub = Hub(config: hc, partners: dev.peers) { st.handle($0) }
        st.hub = hub
        st.log("start", ["mode": st.selftest ? "hub-selftest" : "hub-echo", "partners": dev.peers.count])
        hub.start()
        signal(SIGINT) { _ in exit(130) }
        while true { RunLoop.main.run() }
    }
}

/// Mutated only on the Hub's queue (its handler).
final class HubRun: @unchecked Sendable {
    let selftest: Bool, echo: Bool, expect: Int, need: Int
    let to: String?
    let names: [String: String]
    var hub: Hub?
    var files: HeadlessState?
    var up = Set<String>(), started = false
    var back: [String: Set<String>] = [:]   // partner -> {"text","file","folder"}
    let t0 = Date()
    private let out = NSLock()

    /// expect: partners connected before sending; need: partners that must send everything back.
    init(selftest: Bool, echo: Bool, expect: Int, need: Int, to: String?, names: [String: String]) {
        self.selftest = selftest; self.echo = echo; self.expect = expect; self.need = need; self.to = to; self.names = names
    }

    func log(_ event: String, _ fields: [String: Any]) {
        var d = fields; d["event"] = event; d["t"] = String(format: "%.1f", Date().timeIntervalSince(t0))
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        out.lock(); FileHandle.standardOutput.write(data + Data("\n".utf8)); out.unlock()
    }

    var wants: Set<String> { files?.testFolder != nil ? ["text", "file", "folder"] : ["text", "file"] }
    func missing() -> String { up.map { "\(names[$0] ?? $0): \(wants.subtracting(back[$0] ?? []).sorted())" }.joined(separator: "; ") }

    func handle(_ e: HubEvent) {
        switch e {
        case .listening(let p): log("listening", ["port": Int(p)])
        case .connected(let p, let n):
            up.insert(p); log("connected", ["partner": names[p] ?? p, "name": n])
            if selftest, !started, up.count >= expect, let f = files, let hub, let file = f.testFile {
                started = true
                let to = self.to
                DispatchQueue.global().async {
                    hub.send(text: f.testText, to: to); hub.send(file: file, to: to)
                    if let d = f.testFolder { hub.send(folder: d, to: to) }
                }
            }
        case .disconnected(let p, let r): up.remove(p); log("disconnected", ["partner": names[p] ?? p, "reason": r])
        case .clipboard(let p, let c): log("clipboard", ["from": names[p] ?? p, "fingerprint": ClipRules.fingerprint(c)])
        case .incoming(let p, let item): log("incoming", ["from": names[p] ?? p, "id": item.id, "state": "\(item.state)"])
        case .received(let p, let item):
            let who = names[p] ?? p
            switch item.kind {
            case .text(let t):
                log("received_text", ["from": who, "chars": t.count])
                if echo { echoBack(p) { $0.send(text: t, to: p) } }
                if selftest, t == files?.testText { mark(p, "text") }
            case .file(let n, let size, let url):
                let sha = (try? Hashing.sha256(of: url)) ?? "?"
                log("received_file", ["from": who, "name": n, "size": size, "sha256": sha])
                if echo { echoBack(p) { $0.send(file: url, to: p) } }
                if selftest, sha == files?.testSha { mark(p, "file") }
            case .folder(let n, let count, _, let url):
                let same = files.map { HeadlessState.manifest(url) == $0.testTree } ?? false
                log("received_folder", ["from": who, "name": n, "count": count, "identical": same])
                if echo { echoBack(p) { $0.send(folder: url, to: p) } }
                if selftest, same { mark(p, "folder") }
            }
        case .outgoing(let h):
            if case .failed(let why) = h.summary { log("send_failed", ["why": why]); if selftest { finish(false, why) } }
        case .receiveFailed(let p, let n, let r, _): log("receive_failed", ["from": names[p] ?? p, "name": n, "reason": r]); if selftest { finish(false, r) }
        case .status(let p, let s): log("status", ["partner": names[p] ?? p, "text": s])
        case .error(let m): log("error", ["message": m])
        case .updateAvailable(let v, _): log("update_available", ["version": v])
        case .peerDevice(let p, let d): log("peer_device", ["partner": names[p] ?? p, "device": d])
        case .rekeyed, .peerAddresses: break
        }
    }

    private func echoBack(_ p: String, _ f: @escaping @Sendable (Hub) -> Void) {
        guard let hub else { return }
        DispatchQueue.global().async { f(hub) }   // send() waits on the hub queue; never call it from there
    }

    private func mark(_ p: String, _ what: String) {
        back[p, default: []].insert(what)
        log("selftest_back", ["from": names[p] ?? p, "what": what])
        let done = back.filter { wants.isSubset(of: $0.value) }.count
        if done >= need { finish(true, "\(wants.sorted().joined(separator: ", ")) came back intact from \(done) computer\(done == 1 ? "" : "s")") }
    }

    func finish(_ ok: Bool, _ why: String) {
        log(ok ? "SELFTEST PASS" : "SELFTEST FAIL", ["detail": why])
        if let f = files?.testFile { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        exit(ok ? 0 : 1)
    }
}
