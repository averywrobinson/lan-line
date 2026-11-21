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
    /// What this side tells its peer it can do (PROTOCOL.md "Capabilities"). Tests set [] to act like beta.5.
    public var caps: [String] = ["sha_end", "folders", "multi"]
    /// This app's version ("0.9.0-beta.6"), told to the other computer so either can say "an update is available".
    public var appVersion = ""
    /// The newest version this computer already knows of (saved by the app), passed on to the other computer.
    public var latestKnown: Updates.Available?
    /// This computer's device id, sent in hello / hello_ok (beta.7+).
    public var deviceID = ""
    /// A listener that owns no socket: the Hub accepts connections and hands this Session the ones for its partner.
    public var external = false

    public init(token: String, name: String, downloadDir: URL) {
        self.token = token; self.name = name; self.downloadDir = downloadDir
    }
}

public enum ItemKind: Sendable, Equatable {
    case text(String)
    case file(name: String, size: Int64, url: URL)
    /// A folder sent as one item: `count` files, `size` bytes in all.
    case folder(name: String, count: Int, size: Int64, url: URL)
}

/// One entry of an outgoing folder, in send order (a folder always before what's inside it).
public enum FolderEntry: Sendable, Equatable {
    case dir(String)                      // "/"-separated path inside the folder
    case file(String, URL, Int64)
}

/// What `Session.scanFolder` found: entries to send, and symlinks left out (never followed).
public struct FolderScan: Sendable {
    public var entries: [FolderEntry] = []
    public var count = 0
    public var size: Int64 = 0
    public var skipped = 0
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
    /// A newer Lan-Line exists (heard from the other computer, or from an update check): show a link, nothing more.
    case updateAvailable(version: String, url: String)
    /// The other computer's device id, from its hello / hello_ok (beta.7+).
    case peerDevice(String)
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
        var sha: String?               // files for a beta.5 peer: hashed before file_begin
        var hashing = false
        var onWire = false
        var entries: [FolderEntry] = []
    }
    private struct InFile {
        let id: String
        let name: String
        let size: Int64
        var sha: String?                // nil = it comes in file_end
        var folder: String?
        var dir: URL?                   // inside a folder: where the file goes
        var acked = false               // refused at file_begin, already answered
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
    private var dialHS: DialerHandshake?   // our half of the v2 handshake on `dialing`
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
        let id: String, itemID: String, handle: FileHandle, size: Int64, link: Link
        var hasher: SHA256?            // set when the SHA-256 goes in file_end
        let base: Int64, total: Int64  // progress across a folder
        var next: (@Sendable () -> Void)?   // inside a folder: what comes after this file
        var inFlight = 0, sentBytes: Int64 = 0, eof = false, lastStep = -1
        init(id: String, itemID: String, handle: FileHandle, size: Int64, link: Link, hasher: SHA256?, base: Int64, total: Int64) {
            self.id = id; self.itemID = itemID; self.handle = handle; self.size = size; self.link = link
            self.hasher = hasher; self.base = base; self.total = total
        }
    }
    static let window = 4
    private var inFile: InFile?
    private struct InFolder {
        let id: String, name: String, count: Int, size: Int64
        var stage: URL?
        var files = 0
        var bytes: Int64 = 0
        var reject: String?
        var acked = false
    }
    private var inFolder: InFolder?
    private var peerCaps = Set<String>()
    private var latestKnown: Updates.Available?
    private var done = Set<String>()    // ids already delivered to us
    private var lastHeard = Date.distantPast
    private var lastBeat = Date.distantPast

    public init(role: Role, config: SessionConfig, queue: DispatchQueue? = nil,
                clock: @escaping @Sendable () -> Date = { Date() },
                handler: @escaping @Sendable (SessionEvent) -> Void) {
        self.role = role; self.config = config; self.handler = handler; self.now = clock
        self.token = config.token
        // A short token is a pairing code from 0.9.0-beta.1: upgrade it on the next connection too.
        self.rekeyOnPair = config.rekeyOnPair || (config.token.count < 32 && { if case .listener = role { return true }; return false }())
        self.queue = queue ?? DispatchQueue(label: "lan-line.session")
        self.latestKnown = config.latestKnown
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
        queue.async { self.enqueue(Out(item: item)) }   // hashed while it streams (or first, for a beta.5 peer)
        return item
    }

    /// Send a whole folder as one item. Symlinks are left out (see `scanFolder`).
    @discardableResult
    public func send(folder url: URL) -> Item {
        let scan = Session.scanFolder(url)
        let item = Item(id: UUID().uuidString, kind: .folder(name: url.lastPathComponent, count: scan.count, size: scan.size, url: url),
                        incoming: false, state: .waiting)
        queue.async { self.enqueue(Out(item: item, sha: "", entries: scan.entries)) }
        return item
    }

    /// Walk a folder: every subfolder and regular file, parents first. Symlinks are never followed or sent
    /// (one could point outside the folder); they're counted in `skipped`.
    public static func scanFolder(_ root: URL) -> FolderScan {
        var scan = FolderScan()
        let base = root.standardizedFileURL.pathComponents.count
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return scan }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            let rel = u.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            if v.isSymbolicLink == true { scan.skipped += 1; continue }
            if v.isDirectory == true { scan.entries.append(.dir(rel)) }
            else if v.isRegularFile == true {
                let n = Int64(v.fileSize ?? 0)
                scan.entries.append(.file(rel, u, n)); scan.count += 1; scan.size += n
            }
        }
        return scan
    }

    public var isConnected: Bool { queue.sync { linkUp } }

    /// An update check found this: remember it, show it if it's newer, and tell the other computer.
    public func noteLatest(_ a: Updates.Available) { queue.async { self.consider(a) } }

    private func versionFrame() -> Frame {
        Frame.versionInfo(config.appVersion, latest: latestKnown.map { .init(version: $0.version.description, url: $0.url) })
    }

    /// Keep the newest version above our own; if it changed, say so and pass it on.
    private func consider(_ a: Updates.Available) {
        guard let own = LanLineVersion(config.appVersion), a.version > own, Updates.isAllowedURL(a.url) else { return }
        if let k = latestKnown, k.version >= a.version { return }
        latestKnown = a
        emit(.updateAvailable(version: a.version.description, url: a.url))
        if linkUp, let l = link { l.send(text: versionFrame().json) }
    }

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
        case .listener(let port, let bindHost): if !config.external { listen(port: port, bindHost: bindHost) }
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

    // MARK: Hub entry points (on the queue)

    /// Does this hello's MAC match this partner's secret (or the code it is replacing)?
    func matchesHello(_ f: Frame) -> Bool {
        guard !stopped, f.type == "hello", f.v == LL2.version, let n = f.nonce.flatMap({ Data(base64Encoded: $0) }),
              let e = f.epk.flatMap({ Data(base64Encoded: $0) }), let m = f.mac.flatMap({ Data(base64Encoded: $0) }) else { return false }
        let t1 = LL2.t1(name: f.name ?? "", nonce: n, epk: e)
        return ([token] + (oldToken.map { [$0] } ?? [])).contains { LL2.verify(LL2.macKey($0), t1, m) }
    }

    /// Take over a link the Hub accepted, and answer its hello.
    func adopt(_ l: Link, hello: String) {
        l.retarget { [weak self, weak l] ev in
            guard let self, let l else { return }
            self.onLinkEvent(l, ev)
        }
        handleHello(hello, on: l)
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
            if l === dialing {
                let hs = DialerHandshake(secret: token, name: config.name)
                dialHS = hs
                var hello = hs.hello
                hello.caps = config.caps   // outside the MAC: stripping it only falls back to beta.5 behaviour
                if !config.deviceID.isEmpty { hello.device = config.deviceID }
                l.send(text: hello.json)
            }
        case .closed(let reason):
            pending[ObjectIdentifier(l)] = nil
            if l === dialing {
                dialing = nil
                // A v1 listener (beta.4 or older) closes on a v2 hello without a word.
                let hint = dialHS != nil && (reason == "closed by peer" || reason.hasPrefix("receive:"))
                    ? "Can't connect: update Lan-Line on the other computer too (it may run an older version)." : reason
                dialHS = nil
                emit(.status(hint))
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
        guard let f = Frame.decode(s), f.type == "hello" else { l.close("bad hello"); return }
        guard f.v == LL2.version else {   // a beta.1…beta.4 peer: it sent the secret in the clear; tell it to update
            l.send(text: Frame.upgrade.json)
            emit(.status("The other computer runs an older Lan-Line. Update it to connect."))
            l.close("peer speaks protocol v\(f.v ?? 0)")
            return
        }
        let secrets = [token] + (oldToken.map { [$0] } ?? [])
        guard let ans = ListenerHandshake.answer(f, secrets: secrets, name: config.name) else {
            l.send(text: Frame.refused.json)
            l.close("bad hello")
            return
        }
        if let old = link {   // a new authenticated peer replaces the old one
            link = nil
            linkDown("replaced by a new connection")
            old.close("replaced")
        }
        var rekey: String?
        var fresh = false
        if rekeyOnPair {
            rekeyOnPair = false
            rekey = Secrets.newToken()
            fresh = true
            oldToken = token
            token = rekey!
        } else if ans.secretIndex == 1 {   // the dialer still has the pairing code: it missed the swap, send it again
            rekey = token
        }
        var ok = ans.ok
        ok.caps = config.caps
        if !config.deviceID.isEmpty { ok.device = config.deviceID }
        peerCaps = Set(f.caps ?? [])
        if let d = f.device, Self.isDeviceID(d) { emit(.peerDevice(d)) }
        l.send(text: ok.json)
        l.channel = ans.channel            // everything after hello_ok is sealed
        if let rekey { l.send(text: Frame.rekey(rekey).json) }
        if !config.advertise.isEmpty { l.send(text: Frame.addresses(config.advertise).json) }
        if fresh, let rekey { emit(.rekeyed(token: rekey)) }
        becomeUp(l, peer: f.name ?? l.peerDescription)
    }

    private func handleHelloOK(_ s: String, on l: Link) {
        guard let f = Frame.decode(s) else { l.close("expected hello_ok"); return }
        if f.type == "error" {
            switch f.err {
            case "upgrade": l.close("Can't connect: the other computer runs a newer Lan-Line. Update this one.")
            case "auth": l.close("Refused: the other computer doesn't know this pairing. Pair again.")
            default: l.close("Refused: \(f.err ?? "unknown error")")
            }
            dialHS = nil
            return
        }
        guard let hs = dialHS, let ch = hs.finish(f) else {
            dialHS = nil
            l.close("Refused: the other computer's reply doesn't match this pairing.")
            return
        }
        l.channel = ch
        peerCaps = Set(f.caps ?? [])
        if let d = f.device, Self.isDeviceID(d) { emit(.peerDevice(d)) }
        dialHS = nil
        dialing = nil
        attempt = 0
        becomeUp(l, peer: f.name ?? l.peerDescription)
    }

    static func isDeviceID(_ s: String) -> Bool { (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }

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
        if !config.appVersion.isEmpty { l.send(text: versionFrame().json) }   // beta.5 ignores it
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
        dropFolder()
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
            if f.folder == nil { dropFolder() }
            beginFile(id: id, name: f.name ?? "file", size: f.size ?? -1, sha: f.sha256?.lowercased(), folder: f.folder, path: f.path, on: l)
        case "file_end":
            guard let id = f.id, let file = inFile, file.id == id else { return }
            inFile = nil
            finishFile(file, endSha: f.sha256?.lowercased(), on: l)
        case "folder_begin":
            guard let id = f.id else { return }
            abortIncoming(); dropFolder()
            beginFolder(id: id, name: f.name ?? "folder", count: f.count ?? -1, size: f.size ?? -1, on: l)
        case "mkdir":
            guard var d = inFolder, d.id == f.folder, d.reject == nil, let stage = d.stage else { return }
            if let comps = Names.safePath(f.path ?? "") {
                var url = stage
                for c in comps { url.appendPathComponent(c) }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { d.reject = "bad folder entry" }
                else if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) == nil { d.reject = "cannot write" }
            } else { d.reject = "bad path in folder" }
            inFolder = d
        case "folder_end":
            guard let id = f.id, let d = inFolder, d.id == id else { return }
            abortIncoming()
            inFolder = nil
            finishFolder(d, on: l)
        case "rekey":   // listener → dialer only, inside the encrypted channel
            guard case .dialer = role, let r = f.token, r.count == 64, r.allSatisfy(\.isHexDigit) else { return }
            if r != token { token = r; emit(.rekeyed(token: r)) }
        case "addrs":
            guard case .dialer = role else { return }
            let addrs = (f.addrs ?? []).filter(Self.isIPv4).prefix(8)
            if !addrs.isEmpty { emit(.peerAddresses(Array(addrs))) }
        case "version":   // the peer's version and the newest it knows of; strict parse, allowlisted links only
            if let v = f.version.flatMap(LanLineVersion.init) { consider(.init(version: v, url: Updates.releasePage(v))) }
            if let k = f.latestKnown, let v = LanLineVersion(k.version), Updates.isAllowedURL(k.url) { consider(.init(version: v, url: k.url)) }
        case "ack":
            guard let id = f.id, let i = out.firstIndex(where: { $0.item.id == id }) else { return }
            var o = out.remove(at: i)
            o.item.state = (f.ok ?? false) ? .delivered : .failed(f.err ?? "rejected")
            emit(.outgoing(o.item))
            if let fs = fileSend, fs.itemID == id {   // refused while streaming (too big): stop now
                fileSend = nil
                try? fs.handle.close()
                busy = false
                pump()
            }
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

    private func noSpace(_ size: Int64) -> String? {
        guard let free = freeSpace(), size + config.diskReserve > free else { return nil }
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "not enough disk space on \(config.name) (needs \(fmt(size)), \(fmt(max(free - config.diskReserve, 0))) free)"
    }

    /// A refusal the receiver can give at once, before any bytes: the sender stops and both windows say why.
    private func refuseNow(id: String, name: String, reason: String, on l: Link) {
        l.send(text: Frame.ack(id: id, ok: false, err: reason).json)
        emit(.receiveFailed(name: name, reason: reason))
    }

    private func beginFile(id: String, name raw: String, size: Int64, sha: String?, folder: String?, path: String?, on l: Link) {
        let name = Names.sanitize(raw)
        var f = InFile(id: id, name: name, size: size, sha: sha, folder: folder)
        if let folder {   // a file inside the folder being received
            guard var d = inFolder, d.id == folder, d.reject == nil, let stage = d.stage else {
                f.reject = "not in a folder"; inFile = f; return
            }
            d.bytes += max(size, 0)
            if size < 0 || d.bytes > d.size { d.reject = "folder bigger than announced" }
            else if let comps = Names.safePath(path ?? "") {
                var dir = stage
                for c in comps.dropLast() { dir.appendPathComponent(c) }
                f = InFile(id: id, name: comps.last!, size: size, sha: sha, folder: folder, dir: dir)
            } else { d.reject = "bad path in folder" }
            inFolder = d
            if let r = d.reject { f.reject = r; inFile = f; return }
        } else if size < 0 || size > config.maxFileSize {
            f.reject = "too big or bad size"
        } else if let r = noSpace(size) {
            f.reject = r
        }
        if f.reject == nil, let sha, sha.count != 64 || !sha.allSatisfy(\.isHexDigit) { f.reject = "bad sha256" }
        if f.reject == nil {
            do {
                let dir = f.dir ?? config.downloadDir
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let part = dir.appendingPathComponent(".\(f.name).\(UUID().uuidString.prefix(8)).part")
                FileManager.default.createFile(atPath: part.path, contents: nil)
                f.handle = try FileHandle(forWritingTo: part)
                f.part = part
            } catch {
                f.reject = "cannot write: \(error.localizedDescription)"
            }
        }
        if let r = f.reject, folder == nil {   // answer now: the sender stops instead of streaming it all
            refuseNow(id: id, name: name, reason: r, on: l)
            f.acked = true
        }
        inFile = f
    }

    private func beginFolder(id: String, name raw: String, count: Int, size: Int64, on l: Link) {
        let name = Names.sanitize(raw)
        var d = InFolder(id: id, name: name, count: count, size: size)
        if count < 0 || count > 1_000_000 || size < 0 || size > config.maxFileSize { d.reject = "too big or bad size" }
        else if let r = noSpace(size) { d.reject = r }
        else {
            let stage = config.downloadDir.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8)).part")
            if (try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)) != nil { d.stage = stage }
            else { d.reject = "cannot write" }
        }
        if let r = d.reject { refuseNow(id: id, name: name, reason: r, on: l); d.acked = true }
        inFolder = d
    }

    private func dropFolder() {
        if let st = inFolder?.stage { try? FileManager.default.removeItem(at: st) }
        inFolder = nil
    }

    private func finishFolder(_ folder: InFolder, on l: Link) {
        var d = folder
        if d.reject == nil, d.files != d.count { d.reject = "folder incomplete" }
        if let r = d.reject {
            if let st = d.stage { try? FileManager.default.removeItem(at: st) }
            if !d.acked { refuseNow(id: d.id, name: d.name, reason: r, on: l) }
            return
        }
        guard let stage = d.stage else { return }
        if done.contains(d.id) {
            try? FileManager.default.removeItem(at: stage)
            l.send(text: Frame.ack(id: d.id, ok: true).json)
            return
        }
        let dest = Names.unique(d.name, in: config.downloadDir)
        do { try FileManager.default.moveItem(at: stage, to: dest) } catch {
            try? FileManager.default.removeItem(at: stage)
            refuseNow(id: d.id, name: d.name, reason: "save failed", on: l)
            return
        }
        done.insert(d.id)
        l.send(text: Frame.ack(id: d.id, ok: true).json)
        emit(.received(Item(id: d.id, kind: .folder(name: dest.lastPathComponent, count: d.count, size: d.size, url: dest),
                            incoming: true, state: .received)))
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

    private func finishFile(_ file: InFile, endSha: String?, on l: Link) {
        var f = file
        var reason = f.reject
        if reason == nil, f.received != f.size { reason = "size mismatch" }
        let digest = Data(f.hasher.finalize()).hex
        if reason == nil, digest != (f.sha ?? endSha) { reason = "sha256 mismatch" }
        try? f.handle?.close(); f.handle = nil
        if let reason {
            dropPart(&f)
            if f.folder != nil {   // the whole folder fails; folder_end answers
                if inFolder?.id == f.folder, inFolder?.reject == nil { inFolder?.reject = "\(f.name): \(reason)" }
                return
            }
            if !f.acked {
                l.send(text: Frame.ack(id: f.id, ok: false, err: reason).json)
                emit(.receiveFailed(name: f.name, reason: reason))
            }
            return
        }
        guard let part = f.part else { return }
        if let dir = f.dir {       // inside a folder: put it in place, count it
            let dest = Names.unique(f.name, in: dir)
            if (try? FileManager.default.moveItem(at: part, to: dest)) == nil {
                try? FileManager.default.removeItem(at: part)
                inFolder?.reject = "save failed"
            } else { inFolder?.files += 1 }
            return
        }
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
        out[i].hashing = false
        switch result {
        case .success(let sha): out[i].sha = sha
        case .failure(let e):
            var o = out.remove(at: i)
            o.item.state = .failed("cannot read: \(e.localizedDescription)")
            emit(.outgoing(o.item))
        }
        pump()
    }

    private func fail(_ id: String, _ reason: String) {
        if let i = out.firstIndex(where: { $0.item.id == id }) {
            var o = out.remove(at: i)
            o.item.state = .failed(reason)
            emit(.outgoing(o.item))
        }
        busy = false
        pump()
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Put the next queued item on the wire. One item at a time, in order.
    private func pump() {
        guard linkUp, !busy, let l = link, let i = out.firstIndex(where: { !$0.onWire }) else { return }
        let item = out[i].item
        let shaEnd = peerCaps.contains("sha_end")
        if case .file(_, _, let url) = item.kind, !shaEnd, out[i].sha == nil {   // a beta.5 peer wants the hash first
            if !out[i].hashing {
                out[i].hashing = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<String, Error> = Result { try Hashing.sha256(of: url) }
                    self.queue.async { self.hashed(item.id, result) }
                }
            }
            return
        }
        out[i].onWire = true
        busy = true
        switch item.kind {
        case .text(let text):
            l.send(text: Frame.text(id: item.id, text: text).json) { [weak self] ok in
                self?.wrote(item.id, on: l, ok: ok)
            }
        case .file(let name, _, let url):
            do {
                let h = try FileHandle(forReadingFrom: url)
                let size = fileSize(url)
                l.send(text: Frame.fileBegin(id: item.id, name: name, size: size, sha256: shaEnd ? nil : out[i].sha).json)
                let fs = FileSend(id: item.id, itemID: item.id, handle: h, size: size, link: l, hasher: shaEnd ? SHA256() : nil, base: 0, total: size)
                fileSend = fs
                fillWindow(fs)
            } catch {
                fail(item.id, "cannot read: \(error.localizedDescription)")
            }
        case .folder(let name, let count, let size, _):
            guard peerCaps.contains("folders") else {
                fail(item.id, "Update Lan-Line on \(peerName) to send folders")
                return
            }
            l.send(text: Frame.folderBegin(id: item.id, name: name, count: count, size: size).json)
            folderStep(item.id, out[i].entries, 0, base: 0, total: size, on: l)
        }
    }

    /// Send a folder's entries from `start` on: folders as mkdir, then the next file; its end continues here.
    private func folderStep(_ itemID: String, _ entries: [FolderEntry], _ start: Int, base: Int64, total: Int64, on l: Link) {
        guard l === link, linkUp else { return }                                         // resent after reconnect
        guard out.contains(where: { $0.item.id == itemID }) else { busy = false; pump(); return }   // refused
        var idx = start
        while idx < entries.count, case .dir(let p) = entries[idx] {
            l.send(text: Frame.mkdir(folder: itemID, path: p).json)
            idx += 1
        }
        guard idx < entries.count, case .file(let p, let url, _) = entries[idx] else {
            l.send(text: Frame.folderEnd(id: itemID).json) { [weak self] ok in self?.wrote(itemID, on: l, ok: ok) }
            return
        }
        guard let h = try? FileHandle(forReadingFrom: url) else {
            l.send(text: Frame.folderEnd(id: itemID).json)   // the receiver throws the partial folder away
            fail(itemID, "cannot read \(p)")
            return
        }
        let size = fileSize(url), sub = UUID().uuidString
        l.send(text: Frame.fileBegin(id: sub, name: url.lastPathComponent, size: size, sha256: nil, folder: itemID, path: p).json)
        let fs = FileSend(id: sub, itemID: itemID, handle: h, size: size, link: l, hasher: SHA256(), base: base, total: total)
        let nextIdx = idx + 1
        fs.next = { [weak self] in self?.folderStep(itemID, entries, nextIdx, base: base + size, total: total, on: l) }
        fileSend = fs
        fillWindow(fs)
    }

    private func fillWindow(_ fs: FileSend) {
        guard fileSend === fs, fs.link === link, linkUp else { return }   // link went down; resent later
        guard out.contains(where: { $0.item.id == fs.itemID }) else {    // refused meanwhile
            fileSend = nil; try? fs.handle.close(); busy = false; pump(); return
        }
        while fs.inFlight < Session.window, !fs.eof {
            let chunk: Data
            do { chunk = try fs.handle.read(upToCount: config.chunkSize) ?? Data() } catch {
                fileSend = nil
                try? fs.handle.close()
                fs.link.close("read failed mid-file")   // the peer drops the half file; we resend on reconnect
                return
            }
            if chunk.isEmpty { fs.eof = true; break }
            fs.hasher?.update(data: chunk)
            fs.inFlight += 1
            fs.link.send(data: chunk) { [weak self] ok in
                guard let self else { return }
                fs.inFlight -= 1
                guard ok, self.fileSend === fs else { return }
                fs.sentBytes += Int64(chunk.count)
                let done = fs.base + fs.sentBytes
                let step = fs.total > 0 ? Int(done * 20 / fs.total) : 20     // progress events in 5 % steps
                if step != fs.lastStep, let i = self.out.firstIndex(where: { $0.item.id == fs.itemID }) {
                    fs.lastStep = step
                    self.out[i].item.state = .sending(Double(done) / Double(max(fs.total, 1)))
                    self.emit(.outgoing(self.out[i].item))
                }
                self.fillWindow(fs)
            }
        }
        if fs.eof, fs.inFlight == 0 {
            fileSend = nil
            try? fs.handle.close()
            let id = fs.id, itemID = fs.itemID, l = fs.link, next = fs.next
            let sha = fs.hasher.map { Data($0.finalize()).hex }
            l.send(text: Frame.fileEnd(id: id, sha256: sha).json) { [weak self] ok in
                guard let self else { return }
                if let next { if ok, l === self.link { next() } } else { self.wrote(itemID, on: l, ok: ok) }
            }
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
