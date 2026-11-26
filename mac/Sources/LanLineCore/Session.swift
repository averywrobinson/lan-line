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
    /// Tests: take texts but never answer them, so the sender's item stays "sent, waiting for the ack".
    public var holdTextAcksForTests = false
    /// Seconds between liveness ticks. 0 = no timer (tests call `tick()` themselves).
    public var tickInterval: TimeInterval = 1
    /// Listener, while pairing: answer the first good hello with a fresh 32-byte secret (`rekey`) and switch to
    /// it, so the short on-screen code is never the long-term secret. The code stays accepted until restart.
    public var rekeyOnPair = false
    /// Listener: addresses to tell an authenticated dialer about (its fallbacks if one stops working).
    public var advertise: [String] = []
    /// What this side tells its peer it can do (PROTOCOL.md "Capabilities"). Tests set [] to act like beta.5.
    public var caps: [String] = ["sha_end", "folders", "multi", "cancel", "clip", "resume"]
    /// How long a half-received file is kept for the sender to resume ("resume" cap, beta.10).
    public var partialKeep: TimeInterval = 2 * 3600
    /// An incoming item gets a progress card once it has been arriving this long (small files never flicker).
    public var progressDelay: TimeInterval = 0.3
    /// At most one progress event per item this often (plus one per whole percent at the most).
    public var progressInterval: TimeInterval = 0.25
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
    case receiving(Double)  // an incoming file or folder still arriving, 0...1 (beta.10)
    case cancelled          // stopped by either side (beta.10)
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
    /// An incoming file or folder still arriving (`.receiving`), or stopped before it finished (`.failed`,
    /// `.cancelled`); `.received` follows when it lands (beta.10). Only items that take a moment get these.
    case incoming(Item)
    /// The other computer's clipboard changed (clipboard sharing, beta.10). Never queued or kept.
    case clipboard(ClipContent)
    /// An incoming file was rejected (bad sha, size, too big, disk error).
    /// `id`: the item that failed (the same id its progress card had, if it had one).
    case receiveFailed(name: String, reason: String, id: String)
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
    /// Changed only on `queue` (`setDownloadDir`).
    public private(set) var config: SessionConfig
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
        /// The link dropped while this file was streaming: offer to resume it ("resume" cap, beta.10).
        var resumable = false
    }
    /// A half-received single file kept after a dropped link, for the sender to resume (beta.10).
    struct Partial: Sendable { let name: String; let size: Int64; let part: URL; let received: Int64; let at: Date }
    private var partials: [String: Partial] = [:]
    /// Receiver: a kept partial is being read back from disk (off this queue) to rebuild its hash; `resume`
    /// is answered when that is done.
    private var rehashing: (id: String, partial: Partial, link: Link)?
    /// Sender: the part the receiver already has is being hashed (off this queue) before the rest is streamed.
    private var hashingPrefix: (id: String, link: Link)?
    /// Sender: a resumable file_begin went out; waiting for the receiver's `resume` answer.
    private var awaitingResume: (id: String, url: URL, size: Int64, link: Link)?
    private struct InFile {
        let id: String
        let name: String
        let size: Int64
        var sha: String?                // nil = it comes in file_end
        var folder: String?
        var dir: URL?                   // inside a folder: where the file goes
        var dest: URL?                  // a single file: the folder it is saved in, fixed when it began
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
    /// Connections that haven't said hello yet (each is dropped after 10 s): no more than this at once.
    static let maxPending = 32
    private var held = false           // hold(): off the line until redialNow()

    private var out: [Out] = []
    private var busy = false            // an item is being written to the wire
    /// Which item has the wire. A cancel or a refusal can free the wire while one of the item's writes is
    /// still finishing; that late completion must not free it a second time (the next item already has it).
    private var wireItem: String?
    private var fileSend: FileSend?     // the file currently streaming out

    /// Up to `window` chunks in flight: enough to keep a LAN busy, bounded memory (window × chunkSize).
    private final class FileSend: @unchecked Sendable {   // confined to the session queue
        let id: String, itemID: String, handle: FileHandle, size: Int64, link: Link
        var hasher: SHA256?            // set when the SHA-256 goes in file_end
        let base: Int64, total: Int64  // progress across a folder
        var next: (@Sendable () -> Void)?   // inside a folder: what comes after this file
        var inFlight = 0, sentBytes: Int64 = 0, eof = false, lastStep = -1, lastEmit = Date.distantPast
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
        var dest: URL?                  // the folder it is saved in, fixed when it began
        var files = 0
        var bytes: Int64 = 0
        var reject: String?
        var acked = false
    }
    private var inFolder: InFolder?
    /// The top-level incoming item (a file, or a whole folder) and how far it is, for progress cards (beta.10).
    private struct InProgress {
        let id: String, kind: ItemKind, total: Int64, started: Date
        var done: Int64 = 0, shown = false, lastEmit = Date.distantPast, lastPct = -1
    }
    private var inProgress: InProgress?
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
        for p in stopKeepingPartials().values { try? FileManager.default.removeItem(at: p.part) }   // quitting: nothing to resume
    }

    /// Stop, but hand back the half-received files still worth resuming: the Hub replaces a partner's Session
    /// when its address changes, and the Session that takes over carries on with them (`adopt(partials:)`).
    func stopKeepingPartials() -> [String: Partial] {
        queue.sync {
            stopped = true
            reconnect?.cancel(); timer?.cancel(); timer = nil
            listener?.cancel(); listener = nil
            for l in pending.values { l.close("stopped") }
            pending.removeAll()
            dialing?.close("stopped"); dialing = nil
            if let l = link { l.close("stopped") }   // linkDown shelves a file in mid-air and a part being rehashed
            shelveRehash()
            let kept = partials
            partials.removeAll()
            return kept
        }
    }

    /// Tests: change what the receiver believes is free on its disk.
    func setFreeSpaceForTests(_ bytes: Int64?) { queue.async { self.config.freeSpaceOverride = bytes } }

    /// Take over another Session's kept partials (before `start`).
    func adopt(partials kept: [String: Partial]) {
        queue.async { for (id, p) in kept where self.partials[id] == nil { self.partials[id] = p } }
    }

    /// Left over from a run that ended without cleaning up (a crash, a force quit, power loss): this app's
    /// hidden part files and folders, `.<name>.<8 hex digits>.part`, untouched for longer than a partial is
    /// ever kept. Returns how many it removed.
    @discardableResult
    public static func sweepOrphans(in dir: URL, olderThan age: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where isPartName(name) {
            let u = dir.appendingPathComponent(name)
            guard let made = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, now.timeIntervalSince(made) > age else { continue }
            if (try? fm.removeItem(at: u)) != nil { removed += 1 }
        }
        return removed
    }

    static func isPartName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".part") else { return false }
        let stem = name.dropLast(5)   // ".<name>.<8 hex>"
        guard stem.count >= 11, let dot = stem.lastIndex(of: ".") else { return false }
        let tag = stem[stem.index(after: dot)...]
        return tag.count == 8 && tag.allSatisfy { $0.isASCII && $0.isHexDigit } && dot > stem.index(after: stem.startIndex)
    }

    @discardableResult
    public func send(text: String, id: String = UUID().uuidString) -> Item {
        let item = Item(id: id, kind: .text(text), incoming: false, state: .waiting)
        queue.async { self.enqueue(Out(item: item, sha: "")) }
        return item
    }

    @discardableResult
    public func send(file url: URL, id: String = UUID().uuidString) -> Item {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
        let item = Item(id: id, kind: .file(name: url.lastPathComponent, size: size, url: url),
                        incoming: false, state: .waiting)
        queue.async { self.enqueue(Out(item: item)) }   // hashed while it streams (or first, for a beta.5 peer)
        return item
    }

    /// Send a whole folder as one item. Symlinks are left out (see `scanFolder`).
    @discardableResult
    public func send(folder url: URL, scan given: FolderScan? = nil, id: String = UUID().uuidString) -> Item {
        let scan = given ?? Session.scanFolder(url)   // the hub passes the walk it already did (beta.11)
        let item = Item(id: id, kind: .folder(name: url.lastPathComponent, count: scan.count, size: scan.size, url: url),
                        incoming: false, state: .waiting)
        queue.async { self.enqueue(Out(item: item, sha: "", entries: scan.entries)) }
        return item
    }

    /// Send the clipboard (beta.10): straight away, only while connected and only to a side with the "clip" cap.
    /// Never queued: a clipboard from minutes ago is not what anyone wants to paste. Calls back whether it went out.
    public func sendClip(_ c: ClipContent, done: (@Sendable (Bool) -> Void)? = nil) {
        queue.async {
            guard self.linkUp, let l = self.link, self.peerCaps.contains("clip"), ClipRules.fits(c) else { done?(false); return }
            l.send(text: Frame.clip(c).json) { ok in done?(ok) }
        }
    }

    /// Whether the connected side can take clipboard items (nil while not connected).
    public func peerTakesClips(_ result: @escaping @Sendable (Bool?) -> Void) {
        queue.async { result(self.linkUp ? self.peerCaps.contains("clip") : nil) }
    }

    /// Save files that arrive from now on in another folder (beta.10: the folder setting, a folder per computer).
    /// A file already arriving finishes where it started.
    public func setDownloadDir(_ url: URL) { queue.async { self.config.downloadDir = url } }

    /// Stop an outgoing item (beta.10): a queued one is dropped; one on the wire stops at once and the receiver
    /// throws away what arrived (`cancel` with a beta.10 peer; an early `file_end` / `folder_end` with an older
    /// one, which it refuses as a size mismatch). An item already fully sent can't be called back.
    public func cancel(_ id: String) { queue.async { self.cancelOnQueue(id) } }

    /// Refuse the incoming file or folder that is arriving (beta.10): the sender stops (the same `ack ok:false`
    /// a full disk gives, which every version understands) and the part files are deleted.
    public func cancelIncoming(_ id: String) { queue.async { self.cancelIncomingOnQueue(id) } }

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
    /// Cut the link now (tests and the cross-machine resume check); it reconnects as after any drop.
    public func dropLink() { queue.async { self.link?.close("dropped") } }

    /// Step off the line and stay away (the iPhone app while its share sheet sends, beta.10): the link is dropped
    /// and nothing dials until `redialNow()`. Queued items wait as they do while the other side is away.
    public func hold() {
        queue.async {
            guard !self.held, !self.stopped else { return }
            self.held = true
            self.reconnect?.cancel()
            self.dialing?.close("held")
            self.link?.close("held")
        }
    }

    /// Drop the link if there is one and dial again at once (the iPhone coming back to the front); ends a hold.
    public func redialNow() {
        queue.async {
            guard !self.stopped else { return }
            self.held = false
            if let l = self.link { l.close("dropped"); return }   // the close schedules the redial
            guard self.dialing == nil, case .dialer = self.role else { return }
            self.reconnect?.cancel()
            self.hostIndex = 0
            self.dialNext()
        }
    }

    // MARK: lifecycle

    private func emit(_ e: SessionEvent) { handler(e) }

    private func startOnQueue() {
        let dir = config.downloadDir, age = config.partialKeep + 600
        DispatchQueue.global(qos: .utility).async { Session.sweepOrphans(in: dir, olderThan: age) }
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
        guard !stopped, pending.count < Session.maxPending else { close(fd); return }   // strangers can't pile up connections
        let l = Link.accepted(fd: fd, peer: peer, queue: queue, openedAt: now())
        pending[ObjectIdentifier(l)] = l
        l.start { [weak self, weak l] ev in
            guard let self, let l else { return }
            self.onLinkEvent(l, ev)
        }
    }

    private func dialNext() {
        guard !stopped, !held, case .dialer(let hosts, let port) = role, !hosts.isEmpty else { return }
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
        guard !stopped, !held, case .dialer(let hosts, _) = role else { return }
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
        wireItem = nil
        hashingPrefix = nil
        shelveRehash()
        if let fs = fileSend { try? fs.handle.close(); fileSend = nil }
        if var f = inFile {    // a half-received file: kept for the sender to resume ("resume" cap), else thrown away
            try? f.handle?.close(); f.handle = nil
            if let p = f.part {
                if peerCaps.contains("resume"), f.folder == nil, f.reject == nil, f.received > 0 {
                    partials[f.id] = Partial(name: f.name, size: f.size, part: p, received: f.received, at: now())
                    trimPartials()
                } else { try? FileManager.default.removeItem(at: p) }
            }
            inFile = nil
        }
        awaitingResume = nil
        for i in out.indices where out[i].onWire {
            if case .file = out[i].item.kind, out[i].item.state != .sent { out[i].resumable = true }
        }
        dropFolder()
        endProgress(.failed("interrupted"))   // the sender sends it again after the reconnect
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
        for (id, p) in partials where t.timeIntervalSince(p.at) > config.partialKeep {
            try? FileManager.default.removeItem(at: p.part); partials[id] = nil
        }
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
            if !config.holdTextAcksForTests { l.send(text: Frame.ack(id: id, ok: true).json) }
        case "file_begin":
            guard let id = f.id else { return }
            abortIncoming()
            if f.folder == nil { dropFolder(); endProgress(.failed("interrupted")) }
            beginFile(id: id, name: f.name ?? "file", size: f.size ?? -1, sha: f.sha256?.lowercased(), folder: f.folder, path: f.path, on: l,
                      resume: f.resume == true && f.folder == nil)
        case "file_end":
            guard let id = f.id, let file = inFile, file.id == id else { return }
            inFile = nil
            finishFile(file, endSha: f.sha256?.lowercased(), on: l)
        case "folder_begin":
            guard let id = f.id else { return }
            abortIncoming(); dropFolder(); endProgress(.failed("interrupted"))
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
        case "clip":   // beta.10: the other computer's clipboard (only sent to sides with the "clip" cap)
            if let t = f.text, t.utf8.count <= ClipRules.maxText { emit(.clipboard(.text(t))) }
            else if let b = f.png, let d = Data(base64Encoded: b), d.count <= ClipRules.maxPicture, d.starts(with: ClipRules.pngMagic) { emit(.clipboard(.png(d))) }
        case "resume":   // beta.10: the receiver has `offset` bytes of our interrupted file; send the rest
            guard let id = f.id, let a = awaitingResume, a.id == id, a.link === l else { return }
            awaitingResume = nil
            let offset = max(0, min(f.offset ?? 0, a.size))
            if offset == 0 { startFile(id: id, url: a.url, size: a.size, on: l); break }
            // Hash what the receiver already has off this queue: on a slow disk that takes longer than the
            // dead-link timeout, and beats must keep going meanwhile.
            hashingPrefix = (id, l)
            let hashing = peerCaps.contains("sha_end"), url = a.url, size = a.size
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Session.open(url, at: offset, hashing: hashing)
                self.queue.async { self.prefixHashed(id, size: size, offset: offset, r) }
            }
        case "cancel":   // beta.10: the sender stopped this item; throw away what arrived
            guard let id = f.id else { return }
            if let r = rehashing, r.id == id {   // stopped while its kept part was being read back
                rehashing = nil
                try? FileManager.default.removeItem(at: r.partial.part)
                endProgress(.cancelled)
                return
            }
            guard inProgress?.id == id || inFolder?.id == id || inFile?.id == id else { return }
            abortIncoming()
            if inFolder?.id == id { dropFolder() }
            endProgress(.cancelled)
        case "ack":
            guard let id = f.id, let i = out.firstIndex(where: { $0.item.id == id }) else { return }
            var o = out.remove(at: i)
            let err = f.err ?? "rejected"
            o.item.state = (f.ok ?? false) ? .delivered : err.hasPrefix("cancelled") ? .cancelled : .failed(err)
            emit(.outgoing(o.item))
            if awaitingResume?.id == id { awaitingResume = nil }   // refused instead of resumed
            if hashingPrefix?.id == id { hashingPrefix = nil }
            if let fs = fileSend, fs.itemID == id {   // refused while streaming (too big): stop now
                fileSend = nil
                try? fs.handle.close()
            }
            release(id)
        default:
            break   // beat, or a newer frame type: liveness already noted
        }
    }

    private func freeSpace(at dir: URL? = nil) -> Int64? {
        if let o = config.freeSpaceOverride { return o }
        let d = dir ?? config.downloadDir
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let v = try? d.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    private func noSpace(_ size: Int64, at dir: URL? = nil) -> String? {
        guard let free = freeSpace(at: dir), size + config.diskReserve > free else { return nil }
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "not enough disk space on \(config.name) (needs \(fmt(size)), \(fmt(max(free - config.diskReserve, 0))) free)"
    }

    /// A refusal the receiver can give at once, before any bytes: the sender stops and both windows say why.
    private func refuseNow(id: String, name: String, reason: String, on l: Link) {
        l.send(text: Frame.ack(id: id, ok: false, err: reason).json)
        emit(.receiveFailed(name: name, reason: reason, id: id))
    }

    /// The wire is free again, if `id` is the item that has it (see `wireItem`). Starts the next item.
    private func release(_ id: String) {
        guard wireItem == id else { return }
        wireItem = nil
        busy = false
        pump()
    }

    /// A kept part that was being read back goes on the shelf again (the link dropped, or another item came).
    private func shelveRehash() {
        guard let r = rehashing else { return }
        rehashing = nil
        partials[r.id] = r.partial
    }

    private func beginFile(id: String, name raw: String, size: Int64, sha: String?, folder: String?, path: String?, on l: Link, resume: Bool = false) {
        let name = Names.sanitize(raw)
        var f = InFile(id: id, name: name, size: size, sha: sha, folder: folder)
        if resume, let p = partials.removeValue(forKey: id) {
            if p.size == size, p.name == name {   // carry on where the link dropped
                let dir = p.part.deletingLastPathComponent()
                // Room for the rest is checked now: the check at the first file_begin can be hours old.
                if let r = noSpace(size - p.received, at: dir) {
                    try? FileManager.default.removeItem(at: p.part)
                    refuseNow(id: id, name: name, reason: r, on: l)
                    f.reject = r; f.acked = true; inFile = f
                    return
                }
                // The part's hash is rebuilt from what is on disk, off this queue: a big part on a slow disk
                // takes longer than the dead-link timeout, and beats must keep going. `rehashed` answers.
                rehashing = (id, p, l)
                inProgress = InProgress(id: id, kind: .file(name: name, size: size, url: dir.appendingPathComponent(name)), total: size, started: now(), done: p.received)
                DispatchQueue.global(qos: .userInitiated).async {
                    let h = Session.rehash(p)
                    self.queue.async { self.rehashed(id, name: name, size: size, sha: sha, hasher: h) }
                }
                return
            }
            try? FileManager.default.removeItem(at: p.part)
        }
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
            if folder == nil { f.dest = config.downloadDir }   // it finishes where it started, whatever the setting says by then
            openPart(&f, in: f.dir ?? config.downloadDir)
        }
        if let r = f.reject, folder == nil {   // answer now: the sender stops instead of streaming it all
            refuseNow(id: id, name: name, reason: r, on: l)
            f.acked = true
        }
        if resume, f.reject == nil { l.send(text: Frame.resumeAt(id: id, offset: 0).json) }   // nothing kept: from the start
        if folder == nil, f.reject == nil, !done.contains(id) {   // a resend of something already saved gets no card: it ends silently
            inProgress = InProgress(id: id, kind: .file(name: name, size: size, url: config.downloadDir.appendingPathComponent(name)), total: size, started: now())
        }
        inFile = f
    }

    private func openPart(_ f: inout InFile, in dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let part = dir.appendingPathComponent(".\(f.name).\(UUID().uuidString.prefix(8)).part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            f.handle = try FileHandle(forWritingTo: part)
            f.part = part
        } catch {
            f.reject = "cannot write: \(error.localizedDescription)"
        }
    }

    /// The kept part has been read back (`hasher` nil: it is gone or short). Answer the sender's resume offer.
    private func rehashed(_ id: String, name: String, size: Int64, sha: String?, hasher: SHA256?) {
        guard let r = rehashing, r.id == id else { return }   // cancelled, replaced or the link dropped: dealt with there
        rehashing = nil
        let p = r.partial, l = r.link
        guard l === link, linkUp else { partials[id] = p; return }
        var f = InFile(id: id, name: name, size: size, sha: sha, folder: nil)
        f.dest = p.part.deletingLastPathComponent()
        if let hasher, let wh = try? FileHandle(forWritingTo: p.part) {
            try? wh.truncate(atOffset: UInt64(p.received))
            _ = try? wh.seekToEnd()
            f.part = p.part; f.handle = wh; f.hasher = hasher; f.received = p.received
            inFile = f
            l.send(text: Frame.resumeAt(id: id, offset: p.received).json)
            return
        }
        try? FileManager.default.removeItem(at: p.part)   // nothing usable kept: from the start
        inProgress = nil
        openPart(&f, in: f.dest ?? config.downloadDir)
        if let reason = f.reject {
            refuseNow(id: id, name: name, reason: reason, on: l)
            f.acked = true
        } else {
            l.send(text: Frame.resumeAt(id: id, offset: 0).json)
            inProgress = InProgress(id: id, kind: .file(name: name, size: size, url: (f.dest ?? config.downloadDir).appendingPathComponent(name)), total: size, started: now())
        }
        inFile = f
    }

    private func beginFolder(id: String, name raw: String, count: Int, size: Int64, on l: Link) {
        let name = Names.sanitize(raw)
        var d = InFolder(id: id, name: name, count: count, size: size)
        if count < 0 || count > 1_000_000 || size < 0 || size > config.maxFileSize { d.reject = "too big or bad size" }
        else if let r = noSpace(size) { d.reject = r }
        else {
            d.dest = config.downloadDir   // it finishes where it started, whatever the setting says by then
            let stage = config.downloadDir.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8)).part")
            if (try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)) != nil { d.stage = stage }
            else { d.reject = "cannot write" }
        }
        if let r = d.reject { refuseNow(id: id, name: name, reason: r, on: l); d.acked = true }
        else if !done.contains(id) { inProgress = InProgress(id: id, kind: .folder(name: name, count: count, size: size, url: config.downloadDir.appendingPathComponent(name)), total: size, started: now()) }
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
            if inProgress?.id == d.id { endProgress(.failed(r)) }
            if !d.acked { refuseNow(id: d.id, name: d.name, reason: r, on: l) }
            return
        }
        guard let stage = d.stage else { if inProgress?.id == d.id { inProgress = nil }; return }
        if done.contains(d.id) {   // a resend of something already saved: it had no card (see beginFolder)
            try? FileManager.default.removeItem(at: stage)
            if inProgress?.id == d.id { inProgress = nil }
            l.send(text: Frame.ack(id: d.id, ok: true).json)
            return
        }
        let dir = d.dest ?? config.downloadDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Names.unique(d.name, in: dir)
        do { try FileManager.default.moveItem(at: stage, to: dest) } catch {
            try? FileManager.default.removeItem(at: stage)
            if inProgress?.id == d.id { endProgress(.failed("save failed")) }   // the card must not stay at "receiving"
            refuseNow(id: d.id, name: d.name, reason: "save failed", on: l)
            return
        }
        if inProgress?.id == d.id { inProgress = nil }   // .received replaces the progress card
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
            progressed(Int64(d.count))
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
        shelveRehash()   // the sender moved on to another item: the kept part waits for a later offer
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
            if inProgress?.id == f.id { endProgress(.failed(reason)) }
            if !f.acked {
                l.send(text: Frame.ack(id: f.id, ok: false, err: reason).json)
                emit(.receiveFailed(name: f.name, reason: reason, id: f.id))
            }
            return
        }
        guard let part = f.part else { if f.folder == nil, inProgress?.id == f.id { inProgress = nil }; return }
        if let dir = f.dir {       // inside a folder: put it in place, count it
            let dest = Names.unique(f.name, in: dir)
            if (try? FileManager.default.moveItem(at: part, to: dest)) == nil {
                try? FileManager.default.removeItem(at: part)
                inFolder?.reject = "save failed"
            } else { inFolder?.files += 1 }
            return
        }
        if done.contains(f.id) {   // a resend of something we already saved: it had no card (see beginFile)
            try? FileManager.default.removeItem(at: part)
            if inProgress?.id == f.id { inProgress = nil }
            l.send(text: Frame.ack(id: f.id, ok: true).json)
            return
        }
        let dir = f.dest ?? config.downloadDir   // where it started, even if the setting changed meanwhile
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Names.unique(f.name, in: dir)
        do {
            try FileManager.default.moveItem(at: part, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: part)
            if inProgress?.id == f.id { endProgress(.failed("save failed")) }   // the card must not stay at "receiving"
            l.send(text: Frame.ack(id: f.id, ok: false, err: "save failed").json)
            emit(.receiveFailed(name: f.name, reason: "save failed: \(error.localizedDescription)", id: f.id))
            return
        }
        if inProgress?.id == f.id { inProgress = nil }   // .received replaces the progress card
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

    /// On `queue` only (tests call it from an event hook to cancel at an exact moment).
    func cancelOnQueue(_ id: String) {
        guard let i = out.firstIndex(where: { $0.item.id == id }) else { return }
        if out[i].onWire {
            if out[i].item.state == .sent { return }   // all on the wire, waiting for the ack: too late
            guard let l = link else { return }
            let viaCancel = peerCaps.contains("cancel")
            if let fs = fileSend, fs.itemID == id {
                fileSend = nil
                try? fs.handle.close()
                if viaCancel { l.send(text: Frame.cancel(id: id).json) }
                else {
                    l.send(text: Frame.fileEnd(id: fs.id).json)                          // short: refused as a size mismatch
                    if fs.id != fs.itemID { l.send(text: Frame.folderEnd(id: id).json) }   // and the folder with it
                }
            } else if awaitingResume?.id == id || hashingPrefix?.id == id {   // waiting for the resume answer, or hashing after it (beta.10): the receiver may have the part open
                if awaitingResume?.id == id { awaitingResume = nil }
                if hashingPrefix?.id == id { hashingPrefix = nil }
                l.send(text: Frame.cancel(id: id).json)   // a resume-capable side also takes "cancel"
            } else if case .folder = out[i].item.kind {   // between two files of a folder
                l.send(text: (viaCancel ? Frame.cancel(id: id) : Frame.folderEnd(id: id)).json)
            } else { return }   // a text: already sent
            if wireItem == id { wireItem = nil; busy = false }   // a write of this item still finishing won't free the wire again
        }
        var o = out.remove(at: i)
        o.item.state = .cancelled
        emit(.outgoing(o.item))
        pump()
    }

    /// On `queue` only (tests call it from an event hook).
    func cancelIncomingOnQueue(_ id: String) {
        guard let p = inProgress, p.id == id, let l = link else { return }
        if let r = rehashing, r.id == id {   // stopped while its kept part was being read back
            rehashing = nil
            try? FileManager.default.removeItem(at: r.partial.part)
        }
        if var f = inFile, f.id == id || f.folder == id {
            dropPart(&f); f.reject = "cancelled"; f.acked = true; inFile = f
        }
        if var d = inFolder, d.id == id {
            if let st = d.stage { try? FileManager.default.removeItem(at: st) }
            d.stage = nil; d.reject = "cancelled"; d.acked = true; inFolder = d
        }
        l.send(text: Frame.ack(id: id, ok: false, err: "cancelled on \(config.name)").json)
        endProgress(.cancelled)
    }

    /// Bytes of the current incoming item landed: show its card once it takes a moment, then keep it moving.
    private func progressed(_ n: Int64) {
        guard var p = inProgress else { return }
        p.done += n
        let t = now()
        let pct = p.total > 0 ? Int(p.done * 100 / p.total) : 100
        let due = p.shown ? (pct != p.lastPct && t.timeIntervalSince(p.lastEmit) >= config.progressInterval) || t.timeIntervalSince(p.lastEmit) >= 1
                          : t.timeIntervalSince(p.started) >= config.progressDelay
        if due {
            p.shown = true; p.lastEmit = t; p.lastPct = pct
            emit(.incoming(Item(id: p.id, kind: p.kind, incoming: true, state: .receiving(Double(p.done) / Double(max(p.total, 1))))))
        }
        inProgress = p
    }

    /// The incoming item stopped short: tell the window if it was showing a card.
    private func endProgress(_ state: ItemState) {
        guard let p = inProgress else { return }
        inProgress = nil
        if p.shown { emit(.incoming(Item(id: p.id, kind: p.kind, incoming: true, state: state))) }
    }

    private func fail(_ id: String, _ reason: String) {
        if let i = out.firstIndex(where: { $0.item.id == id }) {
            var o = out.remove(at: i)
            o.item.state = .failed(reason)
            emit(.outgoing(o.item))
        }
        if wireItem == id { wireItem = nil; busy = false }
        pump()
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Put the next queued item on the wire. One item at a time, in order.
    private func pump() {
        // A "sendonly" peer (the iPhone's share sheet, beta.10) only hands things over: what is queued for that
        // device waits for the app itself to connect.
        guard linkUp, !busy, !peerCaps.contains("sendonly"), let l = link, let i = out.firstIndex(where: { !$0.onWire }) else { return }
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
        wireItem = item.id
        switch item.kind {
        case .text(let text):
            l.send(text: Frame.text(id: item.id, text: text).json) { [weak self] ok in
                self?.wrote(item.id, on: l, ok: ok)
            }
        case .file(let name, _, let url):
            let size = fileSize(url)
            guard FileManager.default.isReadableFile(atPath: url.path) else { fail(item.id, "cannot read \(name)"); return }
            if out[i].resumable, shaEnd, peerCaps.contains("resume") {   // offer to carry on; wait for the offset
                var begin = Frame.fileBegin(id: item.id, name: name, size: size, sha256: nil)
                begin.resume = true
                awaitingResume = (item.id, url, size, l)
                l.send(text: begin.json)
                return
            }
            l.send(text: Frame.fileBegin(id: item.id, name: name, size: size, sha256: shaEnd ? nil : out[i].sha).json)
            startFile(id: item.id, url: url, size: size, on: l)
        case .folder(let name, let count, let size, _):
            guard peerCaps.contains("folders") else {
                fail(item.id, "Update Lan-Line on \(peerName) to send folders")
                return
            }
            l.send(text: Frame.folderBegin(id: item.id, name: name, count: count, size: size).json)
            folderStep(item.id, out[i].entries, 0, base: 0, total: size, on: l)
        }
    }

    /// Stream a file from its start.
    private func startFile(id: String, url: URL, size: Int64, on l: Link) {
        do {
            let h = try FileHandle(forReadingFrom: url)
            let fs = FileSend(id: id, itemID: id, handle: h, size: size, link: l, hasher: peerCaps.contains("sha_end") ? SHA256() : nil, base: 0, total: size)
            fileSend = fs
            fillWindow(fs)
        } catch {
            fail(id, "cannot read: \(error.localizedDescription)")
        }
    }

    /// A file opened at `offset`, with the hash of everything before it (the part the receiver already has):
    /// with sha_end the hash in file_end still covers the whole file.
    struct Opened: @unchecked Sendable { let handle: FileHandle; let hasher: SHA256? }

    /// Runs off the session queue.
    static func open(_ url: URL, at offset: Int64, hashing: Bool) -> Result<Opened, Error> {
        Result {
            let h = try FileHandle(forReadingFrom: url)
            guard hashing else { try h.seek(toOffset: UInt64(offset)); return Opened(handle: h, hasher: nil) }
            var hasher = SHA256()
            var left = offset
            while left > 0, let d = try h.read(upToCount: Int(min(left, 1 << 20))), !d.isEmpty { hasher.update(data: d); left -= Int64(d.count) }
            guard left == 0 else { try? h.close(); throw CocoaError(.fileReadUnknown) }   // shorter than it was
            return Opened(handle: h, hasher: hasher)
        }
    }

    /// The prefix is hashed: stream the rest, unless the item was cancelled, refused or cut off meanwhile.
    private func prefixHashed(_ id: String, size: Int64, offset: Int64, _ r: Result<Opened, Error>) {
        func close() { if case .success(let o) = r { try? o.handle.close() } }
        guard let hp = hashingPrefix, hp.id == id else { close(); return }
        hashingPrefix = nil
        let l = hp.link
        guard l === link, linkUp, out.contains(where: { $0.item.id == id }) else { close(); return }
        switch r {
        case .success(let o):
            let fs = FileSend(id: id, itemID: id, handle: o.handle, size: size, link: l, hasher: o.hasher, base: 0, total: size)
            fs.sentBytes = offset
            fileSend = fs
            fillWindow(fs)
        case .failure(let e):
            fail(id, "cannot read: \(e.localizedDescription)")
        }
    }

    /// The hash of a kept partial's first `received` bytes, read back from disk; nil if it is gone or short.
    /// Runs off the session queue.
    static func rehash(_ p: Partial) -> SHA256? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p.part.path),
              let onDisk = (attrs[.size] as? NSNumber)?.int64Value, onDisk >= p.received,
              let rh = try? FileHandle(forReadingFrom: p.part) else { return nil }
        var hasher = SHA256()
        var left = p.received
        while left > 0, let d = try? rh.read(upToCount: Int(min(left, 1 << 20))), !d.isEmpty { hasher.update(data: d); left -= Int64(d.count) }
        try? rh.close()
        return left == 0 ? hasher : nil
    }

    private func trimPartials() {
        guard partials.count > 5 else { return }
        for (id, p) in partials.sorted(by: { $0.value.at < $1.value.at }).prefix(partials.count - 5) {
            try? FileManager.default.removeItem(at: p.part); partials[id] = nil
        }
    }

    /// Send a folder's entries from `start` on: folders as mkdir, then the next file; its end continues here.
    private func folderStep(_ itemID: String, _ entries: [FolderEntry], _ start: Int, base: Int64, total: Int64, on l: Link) {
        guard l === link, linkUp else { return }                                         // resent after reconnect
        guard out.contains(where: { $0.item.id == itemID }) else { release(itemID); return }   // refused or cancelled
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
            fileSend = nil; try? fs.handle.close(); release(fs.itemID); return
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
                // progress events: each whole percent at most, and no more often than progressInterval
                let step = fs.total > 0 ? Int(done * 100 / fs.total) : 100
                let t = self.now()
                if step != fs.lastStep, t.timeIntervalSince(fs.lastEmit) >= self.config.progressInterval || step == 100,
                   let i = self.out.firstIndex(where: { $0.item.id == fs.itemID }) {
                    fs.lastStep = step; fs.lastEmit = t
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
        guard l === link, wireItem == id else { return }   // not the item on the wire any more (cancelled or refused meanwhile)
        wireItem = nil
        busy = false
        if ok, let i = out.firstIndex(where: { $0.item.id == id }), out[i].item.state != .delivered {
            out[i].item.state = .sent
            emit(.outgoing(out[i].item))
        }
        pump()
    }
}
