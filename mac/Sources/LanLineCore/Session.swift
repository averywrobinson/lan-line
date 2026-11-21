import Foundation
import CryptoKit

public enum Role: Sendable, Equatable {
    /// Listen for one peer (the Mac). `bindHost` nil = all interfaces.
    case listener(port: UInt16, bindHost: String? = nil)
    /// Dial the listener, trying each host in turn (the PC, or a Mac test peer).
    case dialer(hosts: [String], port: UInt16)
}

public struct SessionConfig: Sendable {
    public var token: String
    public var name: String
    public var downloadDir: URL
    public var beatInterval: TimeInterval = 15
    public var deadAfter: TimeInterval = 45
    public var helloTimeout: TimeInterval = 10
    public var dialTimeout: TimeInterval = 4
    public var backoff: [TimeInterval] = [1, 2, 4, 8, 10]
    public var chunkSize = 256 * 1024
    /// A sanity bound on the size field, not a practical limit: the real limit is free disk space.
    public var maxFileSize: Int64 = 1 << 40
    /// Keep this much free on the receiving disk after a file lands.
    public var diskReserve: Int64 = 64 << 20
    /// Tests: pretend the download disk has this many bytes free.
    public var freeSpaceOverride: Int64?
    /// Seconds between liveness ticks. 0 = no timer (tests call `tick()` themselves).
    public var tickInterval: TimeInterval = 1
    /// Listener, while pairing: answer the first good hello with a fresh 32-byte secret (`rekey`) and switch to
    /// it, so the short on-screen code is never the long-term secret. The code stays accepted until restart.
    public var rekeyOnPair = false
    /// Listener: addresses to tell an authenticated dialer about (its fallbacks if one stops working).
    public var advertise: [String] = []

    public init(token: String, name: String, downloadDir: URL) {
        self.token = token; self.name = name; self.downloadDir = downloadDir
    }
}

public enum ItemKind: Sendable, Equatable {
    case text(String)
    case file(name: String, size: Int64, url: URL)
}

public enum ItemState: Sendable, Equatable {
    case waiting            // queued, not yet on the wire (or link down)
    case sending(Double)    // file bytes going out, 0...1
    case sent               // fully written, waiting for the ack
    case delivered          // acked ok
    case failed(String)     // acked not ok, or could not be read
    case received           // incoming item
}

public struct Item: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: ItemKind
    public let incoming: Bool
    public var state: ItemState

    public init(id: String, kind: ItemKind, incoming: Bool, state: ItemState) {
        self.id = id; self.kind = kind; self.incoming = incoming; self.state = state
    }
}

public enum SessionEvent: Sendable, Equatable {
    case listening(port: UInt16)
    case connected(peer: String)
    case disconnected(reason: String)
    /// An incoming text, or a file now saved in the download folder.
    case received(Item)
    /// An outgoing item changed state.
    case outgoing(Item)
    /// An incoming file was rejected (bad sha, size, too big, disk error).
    case receiveFailed(name: String, reason: String)
    case error(String)
    /// Diagnostics while not connected (which host is being dialed, why a dial failed).
    case status(String)
    /// The pairing code was swapped for this long-term secret (both sides); save it in the config.
    case rekeyed(token: String)
    /// Dialer: the listener's addresses (from hello_ok); keep them as fallback hosts.
    case peerAddresses([String])
}

/// The one Lan-Line session object. The window, the headless mode and the tests all drive this.
/// All state lives on `queue`; the handler is called on `queue` too, so a UI must hop to main itself (once).
public final class Session: @unchecked Sendable {
    public let role: Role
    public let config: SessionConfig
    private var token: String          // current secret (starts as config.token)
    private var oldToken: String?      // the pairing code, still accepted after a rekey until restart
    private var rekeyOnPair: Bool
    public let queue: DispatchQueue
    private let handler: @Sendable (SessionEvent) -> Void
    private let now: @Sendable () -> Date

    private struct Out {
        var item: Item
        var sha: String?
        var onWire = false
        var hashFailed: String?
    }
    private struct InFile {
        let id: String
        let name: String
        let size: Int64
        let sha: String
        var part: URL?
        var handle: FileHandle?
        var hasher = SHA256()
        var received: Int64 = 0
        var reject: String?
    }

    private var listener: SocketListener?
    private var pending: [ObjectIdentifier: Link] = [:]   // accepted, waiting for hello
    private var link: Link?
    private var linkUp = false
    private var peerName = ""
    private var dialing: Link?
    private var hostIndex = 0
    private var attempt = 0
    private var reconnect: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var stopped = false

    private var out: [Out] = []
    private var busy = false            // an item is being written to the wire
    private var fileSend: FileSend?     // the file currently streaming out

    /// Up to `window` chunks in flight: enough to keep a LAN busy, bounded memory (window × chunkSize).
    private final class FileSend: @unchecked Sendable {   // confined to the session queue
        let id: String, handle: FileHandle, size: Int64, link: Link
        var inFlight = 0, sentBytes: Int64 = 0, eof = false, lastStep = -1
        init(id: String, handle: FileHandle, size: Int64, link: Link) { self.id = id; self.handle = handle; self.size = size; self.link = link }
    }
    static let window = 4
    private var inFile: InFile?
    private var done = Set<String>()    // ids already delivered to us
    private var lastHeard = Date.distantPast
    private var lastBeat = Date.distantPast

    public init(role: Role, config: SessionConfig,
                clock: @escaping @Sendable () -> Date = { Date() },
                handler: @escaping @Sendable (SessionEvent) -> Void) {
        self.role = role; self.config = config; self.handler = handler; self.now = clock
        self.token = config.token
        // A short token is a pairing code from 0.9.0-beta.1: upgrade it on the next connection too.
        self.rekeyOnPair = config.rekeyOnPair || (config.token.count < 32 && { if case .listener = role { return true }; return false }())
        self.queue = DispatchQueue(label: "lan-line.session")
    }

    // MARK: public API (any thread)

    public func start() { queue.async { self.startOnQueue() } }

    public func stop() {
        queue.sync {
            stopped = true
            reconnect?.cancel(); timer?.cancel(); timer = nil
            listener?.cancel(); listener = nil
            for l in pending.values { l.close("stopped") }
            pending.removeAll()
            dialing?.close("stopped"); dialing = nil
            if let l = link { l.close("stopped") }
        }
    }

    @discardableResult
    public func send(text: String) -> Item {
        let item = Item(id: UUID().uuidString, kind: .text(text), incoming: false, state: .waiting)
        queue.async { self.enqueue(Out(item: item, sha: "")) }
        return item
    }

    @discardableResult
    public func send(file url: URL) -> Item {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
        let item = Item(id: UUID().uuidString, kind: .file(name: url.lastPathComponent, size: size, url: url),
                        incoming: false, state: .waiting)
        queue.async {
            self.enqueue(Out(item: item))
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<String, Error> = Result { try Hashing.sha256(of: url) }
                self.queue.async { self.hashed(item.id, result) }
            }
        }
        return item
    }

    public var isConnected: Bool { queue.sync { linkUp } }

    /// Liveness check; the internal timer calls it every `tickInterval`. Tests call it after moving the clock.
    public func tick() { queue.async { self.tickOnQueue() } }

    /// Test hook: drop the current peer as if the network failed.
    func dropLink() { queue.async { self.link?.close("dropped") } }

    // MARK: lifecycle

    private func emit(_ e: SessionEvent) { handler(e) }

    private func startOnQueue() {
        if config.tickInterval > 0 {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + config.tickInterval, repeating: config.tickInterval)
            t.setEventHandler { [weak self] in self?.tickOnQueue() }
            t.resume()
            timer = t
        }
        switch role {
        case .listener(let port, let bindHost): listen(port: port, bindHost: bindHost)
        case .dialer: dialNext()
        }
    }

    private func listen(port: UInt16, bindHost: String?) {
        do {
            let l = try SocketListener(bindHost: bindHost, port: port, queue: queue) { [weak self] fd, peer in
                self?.accept(fd: fd, peer: peer)
            }
            listener = l
            emit(.listening(port: l.port))
        } catch {
            emit(.error("listen failed on port \(port): \(error.localizedDescription)"))
        }
    }

    private func accept(fd: Int32, peer: String) {
        guard !stopped else { close(fd); return }
        let l = Link.accepted(fd: fd, peer: peer, queue: queue, openedAt: now())
        pending[ObjectIdentifier(l)] = l
        l.start { [weak self, weak l] ev in
            guard let self, let l else { return }
            self.onLinkEvent(l, ev)
        }
    }

    private func dialNext() {
        guard !stopped, case .dialer(let hosts, let port) = role, !hosts.isEmpty else { return }
        let host = hosts[hostIndex % hosts.count]
        emit(.status("dialing \(host)"))
        let l = Link.dial(host: host, port: port, queue: queue, openedAt: now())
        dialing = l
        l.start { [weak self, weak l] ev in
            guard let self, let l else { return }
            self.onLinkEvent(l, ev)
        }
        // A stealth firewall drops SYNs silently; give up on this host after dialTimeout.
        queue.asyncAfter(deadline: .now() + config.dialTimeout) { [weak self, weak l] in
            guard let self, let l, self.dialing === l, !self.linkUp else { return }
            l.close("dial timeout (\(host))")
        }
    }

    private func scheduleRedial(afterFailure: Bool) {
        guard !stopped, case .dialer(let hosts, _) = role else { return }
        reconnect?.cancel()
        var delay: TimeInterval = 0
        if afterFailure {
            hostIndex += 1
            if hostIndex % max(hosts.count, 1) == 0 {   // every host failed once: back off
                delay = config.backoff[min(attempt, config.backoff.count - 1)]
                attempt += 1
            }
        } else {
            hostIndex = 0
            delay = config.backoff.first ?? 1
        }
        let w = DispatchWorkItem { [weak self] in self?.dialNext() }
        reconnect = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: link events

    private func onLinkEvent(_ l: Link, _ ev: LinkEvent) {
        let isActive = (l === link)
        switch ev {
        case .ready:
            if l === dialing { l.send(text: Frame.hello(token: token, name: config.name).json) }
        case .closed(let reason):
            pending[ObjectIdentifier(l)] = nil
            if l === dialing {
                dialing = nil
                emit(.status(reason))
                scheduleRedial(afterFailure: true)
            }
            if isActive { linkDown(reason) }
        case .text(let s):
            if isActive { lastHeard = now(); handleFrame(s, on: l) }
            else if pending[ObjectIdentifier(l)] != nil { handleHello(s, on: l) }
            else if l === dialing { handleHelloOK(s, on: l) }
        case .data(let d):
            if isActive { lastHeard = now(); handleChunk(d) }
            else { l.close("binary before hello") }
        }
    }

    private func handleHello(_ s: String, on l: Link) {
        pending[ObjectIdentifier(l)] = nil
        guard let f = Frame.decode(s), f.type == "hello", f.v == Frame.protocolVersion,
              let tok = f.token, Secrets.equal(tok, token) || (oldToken.map { Secrets.equal(tok, $0) } ?? false) else {
            l.close("bad hello")
            return
        }
        if let old = link {   // a new authenticated peer replaces the old one
            link = nil
            linkDown("replaced by a new connection")
            old.close("replaced")
        }
        var rekey: String?
        if rekeyOnPair && f.rekey == "?" {   // only peers that can save a new secret
            rekeyOnPair = false
            rekey = Secrets.newToken()
            oldToken = token
            token = rekey!
        }
        l.send(text: Frame.helloOK(name: config.name, rekey: rekey, addrs: config.advertise.isEmpty ? nil : config.advertise).json)
        if let rekey { emit(.rekeyed(token: rekey)) }
        becomeUp(l, peer: f.name ?? l.peerDescription)
    }

    private func handleHelloOK(_ s: String, on l: Link) {
        guard let f = Frame.decode(s), f.type == "hello_ok" else { l.close("expected hello_ok"); return }
        dialing = nil
        attempt = 0
        if let r = f.rekey, r.count == 64, r.allSatisfy(\.isHexDigit) {
            token = r
            emit(.rekeyed(token: r))
        }
        let addrs = (f.addrs ?? []).filter(Self.isIPv4).prefix(8)
        if !addrs.isEmpty { emit(.peerAddresses(Array(addrs))) }
        becomeUp(l, peer: f.name ?? l.peerDescription)
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in p.count <= 3 && Int(p).map { (0...255).contains($0) } ?? false }
    }

    private func becomeUp(_ l: Link, peer: String) {
        link = l
        linkUp = true
        peerName = peer
        lastHeard = now()
        lastBeat = now()
        emit(.connected(peer: peer))
        pump()
    }

    private func linkDown(_ reason: String) {
        guard linkUp || link != nil else { return }
        link = nil
        linkUp = false
        busy = false
        if let fs = fileSend { try? fs.handle.close(); fileSend = nil }
        if var f = inFile {    // a half-received file is thrown away; the sender will resend it
            try? f.handle?.close(); f.handle = nil
            if let p = f.part { try? FileManager.default.removeItem(at: p) }
            inFile = nil
        }
        for i in out.indices where out[i].onWire {
            out[i].onWire = false
            out[i].item.state = .waiting
            emit(.outgoing(out[i].item))
        }
        emit(.disconnected(reason: reason))
        if case .dialer = role { scheduleRedial(afterFailure: false) }
    }

    private func tickOnQueue() {
        let t = now()
        for l in pending.values where t.timeIntervalSince(l.openedAt) > config.helloTimeout {
            pending[ObjectIdentifier(l)] = nil
            l.close("no hello within \(Int(config.helloTimeout)) s")
        }
        guard linkUp, let l = link else { return }
        if t.timeIntervalSince(lastHeard) > config.deadAfter {
            l.close("dead link: nothing heard for \(Int(config.deadAfter)) s")
            return
        }
        if t.timeIntervalSince(lastBeat) >= config.beatInterval {
            lastBeat = t
            l.send(text: Frame.beat.json)
        }
    }

    // MARK: incoming

    private func handleFrame(_ s: String, on l: Link) {
        guard let f = Frame.decode(s) else { return }
        switch f.type {
        case "text":
            guard let id = f.id, let text = f.text else { return }
            if done.insert(id).inserted {
                emit(.received(Item(id: id, kind: .text(text), incoming: true, state: .received)))
            }
            l.send(text: Frame.ack(id: id, ok: true).json)
        case "file_begin":
            guard let id = f.id else { return }
            abortIncoming()
            beginFile(id: id, name: f.name ?? "file", size: f.size ?? -1, sha: (f.sha256 ?? "").lowercased())
        case "file_end":
            guard let id = f.id, let file = inFile, file.id == id else { return }
            inFile = nil
            finishFile(file, on: l)
        case "ack":
            guard let id = f.id, let i = out.firstIndex(where: { $0.item.id == id }) else { return }
            var o = out.remove(at: i)
            o.item.state = (f.ok ?? false) ? .delivered : .failed(f.err ?? "rejected")
            emit(.outgoing(o.item))
        default:
            break   // beat, or a newer frame type: liveness already noted
        }
    }

    private func freeSpace() -> Int64? {
        if let o = config.freeSpaceOverride { return o }
        try? FileManager.default.createDirectory(at: config.downloadDir, withIntermediateDirectories: true)
        let v = try? config.downloadDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    private func beginFile(id: String, name raw: String, size: Int64, sha: String) {
        let name = Names.sanitize(raw)
        var f = InFile(id: id, name: name, size: size, sha: sha)
        if size < 0 || size > config.maxFileSize {
            f.reject = "too big or bad size"
        } else if let free = freeSpace(), size + config.diskReserve > free {
            f.reject = "not enough disk space (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free)"
        } else if sha.count != 64 || !sha.allSatisfy(\.isHexDigit) {
            f.reject = "bad sha256"
        } else {
            do {
                try FileManager.default.createDirectory(at: config.downloadDir, withIntermediateDirectories: true)
                let part = config.downloadDir.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8)).part")
                FileManager.default.createFile(atPath: part.path, contents: nil)
                f.handle = try FileHandle(forWritingTo: part)
                f.part = part
            } catch {
                f.reject = "cannot write: \(error.localizedDescription)"
            }
        }
        inFile = f
    }

    private func handleChunk(_ d: Data) {
        guard var f = inFile else { return }
        defer { inFile = f }
        guard f.reject == nil else { return }
        f.received += Int64(d.count)
        if f.received > f.size { f.reject = "size mismatch"; dropPart(&f); return }
        do {
            try f.handle?.write(contentsOf: d)
            f.hasher.update(data: d)
        } catch {
            f.reject = "write failed: \(error.localizedDescription)"
            dropPart(&f)
        }
    }

    private func dropPart(_ f: inout InFile) {
        try? f.handle?.close(); f.handle = nil
        if let p = f.part { try? FileManager.default.removeItem(at: p) }
        f.part = nil
    }

    private func abortIncoming() {
        guard var f = inFile else { return }
        dropPart(&f)
        inFile = nil
    }

    private func finishFile(_ file: InFile, on l: Link) {
        var f = file
        var reason = f.reject
        if reason == nil, f.received != f.size { reason = "size mismatch" }
        let digest = Data(f.hasher.finalize()).hex
        if reason == nil, digest != f.sha { reason = "sha256 mismatch" }
        try? f.handle?.close(); f.handle = nil
        if let reason {
            dropPart(&f)
            l.send(text: Frame.ack(id: f.id, ok: false, err: reason).json)
            emit(.receiveFailed(name: f.name, reason: reason))
            return
        }
        guard let part = f.part else { return }
        if done.contains(f.id) {   // a resend of something we already saved
            try? FileManager.default.removeItem(at: part)
            l.send(text: Frame.ack(id: f.id, ok: true).json)
            return
        }
        let dest = Names.unique(f.name, in: config.downloadDir)
        do {
            try FileManager.default.moveItem(at: part, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: part)
            l.send(text: Frame.ack(id: f.id, ok: false, err: "save failed").json)
            emit(.receiveFailed(name: f.name, reason: "save failed: \(error.localizedDescription)"))
            return
        }
        done.insert(f.id)
        l.send(text: Frame.ack(id: f.id, ok: true).json)
        emit(.received(Item(id: f.id, kind: .file(name: dest.lastPathComponent, size: f.size, url: dest),
                            incoming: true, state: .received)))
    }

    // MARK: outgoing

    private func enqueue(_ o: Out) {
        out.append(o)
        emit(.outgoing(o.item))
        pump()
    }

    private func hashed(_ id: String, _ result: Result<String, Error>) {
        guard let i = out.firstIndex(where: { $0.item.id == id }) else { return }
        switch result {
        case .success(let sha): out[i].sha = sha
        case .failure(let e):
            var o = out.remove(at: i)
            o.item.state = .failed("cannot read: \(e.localizedDescription)")
            emit(.outgoing(o.item))
        }
        pump()
    }

    /// Put the next queued item on the wire. One item at a time, in order.
    private func pump() {
        guard linkUp, !busy, let l = link, let i = out.firstIndex(where: { !$0.onWire }) else { return }
        guard let sha = out[i].sha else { return }   // first in line is still being hashed
        out[i].onWire = true
        busy = true
        let item = out[i].item
        switch item.kind {
        case .text(let text):
            l.send(text: Frame.text(id: item.id, text: text).json) { [weak self] ok in
                self?.wrote(item.id, on: l, ok: ok)
            }
        case .file(let name, _, let url):
            do {
                let h = try FileHandle(forReadingFrom: url)
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                l.send(text: Frame.fileBegin(id: item.id, name: name, size: size, sha256: sha).json)
                let fs = FileSend(id: item.id, handle: h, size: size, link: l)
                fileSend = fs
                fillWindow(fs)
            } catch {
                out.remove(at: i)
                busy = false
                var failed = item
                failed.state = .failed("cannot read: \(error.localizedDescription)")
                emit(.outgoing(failed))
                pump()
            }
        }
    }

    private func fillWindow(_ fs: FileSend) {
        guard fileSend === fs, fs.link === link, linkUp else { return }   // link went down; resent later
        while fs.inFlight < Session.window, !fs.eof {
            let chunk: Data
            do { chunk = try fs.handle.read(upToCount: config.chunkSize) ?? Data() } catch {
                fileSend = nil
                try? fs.handle.close()
                fs.link.close("read failed mid-file")   // the peer drops the half file; we resend on reconnect
                return
            }
            if chunk.isEmpty { fs.eof = true; break }
            fs.inFlight += 1
            fs.link.send(data: chunk) { [weak self] ok in
                guard let self else { return }
                fs.inFlight -= 1
                guard ok, self.fileSend === fs else { return }
                fs.sentBytes += Int64(chunk.count)
                let step = fs.size > 0 ? Int(fs.sentBytes * 20 / fs.size) : 20     // progress events in 5 % steps
                if step != fs.lastStep, let i = self.out.firstIndex(where: { $0.item.id == fs.id }) {
                    fs.lastStep = step
                    self.out[i].item.state = .sending(Double(fs.sentBytes) / Double(max(fs.size, 1)))
                    self.emit(.outgoing(self.out[i].item))
                }
                self.fillWindow(fs)
            }
        }
        if fs.eof, fs.inFlight == 0 {
            fileSend = nil
            try? fs.handle.close()
            let id = fs.id, l = fs.link
            l.send(text: Frame.fileEnd(id: id).json) { [weak self] ok in self?.wrote(id, on: l, ok: ok) }
        }
    }

    private func wrote(_ id: String, on l: Link, ok: Bool) {
        guard l === link else { return }
        busy = false
        if ok, let i = out.firstIndex(where: { $0.item.id == id }), out[i].item.state != .delivered {
            out[i].item.state = .sent
            emit(.outgoing(out[i].item))
        }
        pump()
    }
}
