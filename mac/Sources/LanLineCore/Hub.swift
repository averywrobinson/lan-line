import Foundation

/// Settings for a Hub: what every partner Session shares.
public struct HubConfig: Sendable {
    public var name: String
    public var deviceID: String
    public var port: UInt16 = LanLineConfig.defaultPort
    /// nil = all IPv4 interfaces.
    public var bindHost: String?
    public var downloadDir: URL
    public var appVersion = ""
    public var latestKnown: Updates.Available?
    /// Listener side: addresses to tell partners about (their fallbacks).
    public var advertise: [String] = []
    /// Tests: adjust every partner Session's config (fast backoff, free-space override…).
    public var tune: (@Sendable (inout SessionConfig) -> Void)?

    public init(name: String, deviceID: String, downloadDir: URL) {
        self.name = name; self.deviceID = deviceID; self.downloadDir = downloadDir
    }
}

/// One outgoing item as the window shows it: sent to one partner or to everyone, with each partner's state.
public struct HubItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: ItemKind
    /// Partner ids it goes to.
    public let to: [String]
    public var states: [String: ItemState]

    public var delivered: Int { states.values.filter { $0 == .delivered }.count }
    public var total: Int { to.count }

    /// One state for the row: delivered when everyone has it, failed when someone refused and nobody is
    /// still busy, otherwise the least advanced state (waiting < sending < sent).
    public var summary: ItemState {
        let s = to.compactMap { states[$0] }
        if s.count == to.count, s.allSatisfy({ $0 == .delivered }) { return .delivered }
        let busy = s.filter { if case .failed = $0 { return false }; return $0 != .delivered && $0 != .cancelled }
        if busy.isEmpty, let f = s.first(where: { if case .failed = $0 { return true }; return false }) {
            if case .failed(let why) = f { return .failed(to.count > 1 ? "\(s.filter { if case .failed = $0 { return true }; return false }.count) of \(to.count): \(why)" : why) }
        }
        if busy.isEmpty, s.contains(.cancelled) { return .cancelled }
        if s.count < to.count || busy.contains(.waiting) { return .waiting }
        let sending = busy.compactMap { if case .sending(let f) = $0 { return f }; return nil }
        if !sending.isEmpty { return .sending(sending.reduce(0, +) / Double(sending.count)) }
        return .sent
    }
}

public enum HubEvent: Sendable, Equatable {
    case listening(UInt16)
    case connected(partner: String, name: String)
    case disconnected(partner: String, reason: String)
    case received(partner: String, Item)
    case outgoing(HubItem)
    /// An incoming file or folder still arriving, or stopped short (beta.10).
    case incoming(partner: String, Item)
    /// A partner's clipboard (clipboard sharing, beta.10).
    case clipboard(partner: String, ClipContent)
    /// `id`: the item that failed (the same id its progress card had, if it had one).
    case receiveFailed(partner: String, name: String, reason: String, id: String)
    case status(partner: String, String)
    /// Pairing: the code was swapped for this long-term secret; save it for that partner.
    case rekeyed(partner: String, token: String)
    case peerAddresses(partner: String, [String])
    /// The partner's real device id (its hello); the app may re-key the partner by it.
    case peerDevice(partner: String, device: String)
    case updateAvailable(version: String, url: String)
    case error(String)
}

/// Several partners at once (beta.7): one listener for all listening partners, routed by secret, and one dialer
/// per partner this computer connects to. Each partner gets today's two-computer Session, unchanged in what it
/// sends; there is no relaying between partners. Everything runs on one queue; events arrive on it.
public final class Hub: @unchecked Sendable {
    public let config: HubConfig
    public let queue = DispatchQueue(label: "lan-line.hub")
    private let handler: @Sendable (HubEvent) -> Void

    private var partners: [String: Partner] = [:]
    private var order: [String] = []
    private var sessions: [String: Session] = [:]
    private var listener: SocketListener?
    private var pending: [ObjectIdentifier: (link: Link, opened: Date)] = [:]
    private var items: [String: HubItem] = [:]              // hub item id → item
    private var routes: [String: (hub: String, partner: String)] = [:]   // session item id → hub item, partner
    private var up = Set<String>()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var _boundPort: UInt16?
    private var responder: DiscoveryResponder?

    public init(config: HubConfig, partners: [Partner], handler: @escaping @Sendable (HubEvent) -> Void) {
        self.config = config; self.handler = handler
        for p in partners { self.partners[p.id] = p; order.append(p.id) }
    }

    /// The port the listener got (tests listen on port 0).
    public var boundPort: UInt16? { queue.sync { _boundPort } }
    /// Partner ids with a live link now.
    public var connectedPartners: Set<String> { queue.sync { up } }

    public func start() {
        queue.async {
            for id in self.order { self.makeSession(id, pairing: false) }
            self.ensureListener()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { self.dropSilent() }   // cancelled in stop()
            t.resume()
            self.timer = t
        }
    }

    /// Stop everything. Call from outside the hub's queue.
    public func stop() {
        let all: [Session] = queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            listener?.cancel(); listener = nil
            responder?.close(); responder = nil
            for p in pending.values { p.link.close("stopped") }
            pending.removeAll()
            return Array(sessions.values)
        }
        for s in all { s.stop() }
    }

    /// Add a partner (or replace one with the same id). `pairing`: this computer shows a code for it; the first
    /// connection swaps the code for a long-term secret (`.rekeyed`).
    public func add(_ p: Partner, pairing: Bool) {
        let old: Session? = queue.sync {
            let o = sessions.removeValue(forKey: p.id)
            partners[p.id] = p
            if !order.contains(p.id) { order.append(p.id) }
            up.remove(p.id)
            return o
        }
        let kept = old?.stopKeepingPartials() ?? [:]   // half-received files stay resumable across the swap
        queue.async {
            if !self.stopped { self.makeSession(p.id, pairing: pairing, partials: kept); self.ensureListener() }
            else { for k in kept.values { try? FileManager.default.removeItem(at: k.part) } }
        }
    }

    /// The partner's name changed (it said so in its hello, or it was renamed here): with a folder per computer,
    /// what arrives from now on goes to the folder of that name. A file already arriving finishes where it started.
    public func setName(partner id: String, _ name: String) { queue.async { self.setNameOnQueue(id, name) } }

    private func setNameOnQueue(_ id: String, _ name: String) {
        guard var p = partners[id], p.name != name, !name.isEmpty else { return }
        p.name = name
        partners[id] = p
        if perComputer { sessions[id]?.setDownloadDir(folder(for: id)) }
    }

    /// Forget a partner: its Session stops and its secret is no longer accepted.
    public func remove(_ id: String) {
        let old: Session? = queue.sync {
            partners[id] = nil; order.removeAll { $0 == id }; up.remove(id)
            return sessions.removeValue(forKey: id)
        }
        old?.stop()
        queue.async { self.handler(.disconnected(partner: id, reason: "forgotten")) }
    }

    /// Change a partner's id to its real device id (learned from its hello), keeping its link.
    public func rename(partner old: String, to new: String) {
        queue.async {
            guard old != new, let p = self.partners.removeValue(forKey: old), self.partners[new] == nil else { return }
            var q = p; q.id = new
            self.partners[new] = q
            if let i = self.order.firstIndex(of: old) { self.order[i] = new }
            if let s = self.sessions.removeValue(forKey: old) { self.sessions[new] = s }
            if let t = self.tags.removeValue(forKey: old) { t.id = new; self.tags[new] = t }
            if self.up.remove(old) != nil { self.up.insert(new) }
            for (k, r) in self.routes where r.partner == old { self.routes[k] = (r.hub, new) }
        }
    }

    /// An update check found a newer version: every partner Session shows it once and passes it on.
    public func noteLatest(_ a: Updates.Available) {
        let all: [Session] = queue.sync { Array(sessions.values) }
        for s in all { s.noteLatest(a) }
    }

    // MARK: sending

    @discardableResult
    public func send(text: String, to: String?) -> HubItem { fanOut(.text(text), to: to) { $0.send(text: text) } }

    @discardableResult
    public func send(file url: URL, to: String?) -> HubItem {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
        return fanOut(.file(name: url.lastPathComponent, size: size, url: url), to: to) { $0.send(file: url) }
    }

    @discardableResult
    public func send(folder url: URL, to: String?) -> HubItem {
        let scan = Session.scanFolder(url)
        return fanOut(.folder(name: url.lastPathComponent, count: scan.count, size: scan.size, url: url), to: to) { $0.send(folder: url) }
    }

    /// Everyone (`to` nil) or one partner. Each partner's Session queues its own copy, so an offline partner
    /// gets it when it reconnects.
    private func fanOut(_ kind: ItemKind, to: String?, _ send: (Session) -> Item) -> HubItem {
        let targets: [(String, Session)] = queue.sync {
            let ids = to.map { [$0] } ?? order
            return ids.compactMap { id in sessions[id].map { (id, $0) } }
        }
        var item = HubItem(id: UUID().uuidString, kind: kind, to: targets.map(\.0), states: [:])
        for (pid, _) in targets { item.states[pid] = .waiting }
        let sent = targets.map { ($0.0, send($0.1)) }
        let registered = item
        queue.sync {
            for (pid, it) in sent { routes[it.id] = (registered.id, pid) }
            items[registered.id] = registered
        }
        let itemID = registered.id
        queue.async { if let i = self.items[itemID] { self.handler(.outgoing(i)) } }
        return item
    }

    /// Share the clipboard with every connected partner that takes it (beta.10); never queued.
    /// `done` gets how many it went to and how many connected partners are too old for it.
    public func sendClip(_ c: ClipContent, done: (@Sendable (_ sent: Int, _ tooOld: Int) -> Void)? = nil) {
        queue.async {
            let ss = self.order.compactMap { self.sessions[$0] }
            let group = DispatchGroup()
            let tally = ClipTally()
            for s in ss {
                group.enter()
                s.peerTakesClips { takes in
                    if takes == false { tally.old() }
                    if takes == true { s.sendClip(c) { ok in if ok { tally.sent() }; group.leave() } } else { group.leave() }
                }
            }
            group.notify(queue: self.queue) { done?(tally.n, tally.tooOld) }
        }
    }

    private final class ClipTally: @unchecked Sendable {
        private let lock = NSLock(); private(set) var n = 0, tooOld = 0
        func sent() { lock.lock(); n += 1; lock.unlock() }
        func old() { lock.lock(); tooOld += 1; lock.unlock() }
    }

    /// Where received files go (beta.10): one folder, or a folder per computer inside it. Applies to every partner now
    /// and to partners added later.
    public func setDownloads(base: URL, perComputer: Bool) {
        queue.async {
            self.downloadBase = base; self.perComputer = perComputer
            for (id, s) in self.sessions { s.setDownloadDir(self.folder(for: id)) }
        }
    }

    private var downloadBase: URL?
    private var perComputer = false
    private func folder(for id: String) -> URL {
        ReceiveOptions.folder(base: downloadBase ?? config.downloadDir, perComputer: perComputer, partner: partners[id]?.name ?? id)
    }

    /// Drop every link and dial again (beta.10, the iPhone coming back to the front: iOS may have suspended its
    /// sockets while it was in the background, and waiting 45 s for the dead-link check would feel broken).
    public func reconnect() {
        queue.async { for s in self.sessions.values { s.redialNow() } }
    }

    /// Step off every line until `reconnect()` (beta.10): the iPhone app does this in the background while its
    /// share sheet connects with the same pairing, so the two never knock each other off.
    public func hold() {
        queue.async { for s in self.sessions.values { s.hold() } }
    }

    /// Stop an outgoing item for everyone it is still going to (beta.10).
    public func cancel(_ hubID: String) {
        queue.async {
            for (sid, r) in self.routes where r.hub == hubID { self.sessions[r.partner]?.cancel(sid) }
        }
    }

    /// Refuse an incoming item that is still arriving from `partner` (beta.10).
    public func cancelIncoming(partner: String, id: String) {
        queue.async { self.sessions[partner]?.cancelIncoming(id) }
    }

    // MARK: sessions

    private func makeSession(_ id: String, pairing: Bool, partials: [String: Session.Partial] = [:]) {
        guard let p = partners[id] else { return }
        var sc = SessionConfig(token: p.secret, name: config.name, downloadDir: folder(for: id))
        sc.appVersion = config.appVersion; sc.latestKnown = config.latestKnown; sc.deviceID = config.deviceID
        sc.rekeyOnPair = pairing && !p.connects
        sc.external = !p.connects
        sc.advertise = p.connects ? [] : config.advertise
        config.tune?(&sc)
        let role: Role = p.connects ? .dialer(hosts: p.hosts, port: p.port ?? config.port) : .listener(port: 0)
        let tag = PartnerTag(id)
        tags[id] = tag
        let s = Session(role: role, config: sc, queue: queue) { [weak self] e in self?.fromSession(tag.id, e) }
        sessions[id] = s
        if !partials.isEmpty { s.adopt(partials: partials) }
        s.start()
    }

    /// Which partner a Session's events belong to; `rename` changes it in place.
    private final class PartnerTag: @unchecked Sendable { var id: String; init(_ id: String) { self.id = id } }
    private var tags: [String: PartnerTag] = [:]

    private func fromSession(_ id: String, _ e: SessionEvent) {
        switch e {
        case .listening: break
        case .connected(let name):
            up.insert(id)
            setNameOnQueue(id, name)   // the folder per computer follows the name the computer gives itself
            handler(.connected(partner: id, name: name))
        case .disconnected(let r): up.remove(id); handler(.disconnected(partner: id, reason: r))
        case .received(let item): handler(.received(partner: id, item))
        case .incoming(let item): handler(.incoming(partner: id, item))
        case .clipboard(let c): handler(.clipboard(partner: id, c))
        case .outgoing(let item):
            guard let r = routes[item.id], var h = items[r.hub] else { return }
            h.states[r.partner] = item.state
            items[r.hub] = h
            handler(.outgoing(h))
        case .receiveFailed(let n, let r, let item): handler(.receiveFailed(partner: id, name: n, reason: r, id: item))
        case .error(let m): handler(.error(m))
        case .status(let s): handler(.status(partner: id, s))
        case .rekeyed(let t): if var p = partners[id] { p.secret = t; partners[id] = p }; handler(.rekeyed(partner: id, token: t))
        case .peerAddresses(let a): handler(.peerAddresses(partner: id, a))
        case .peerDevice(let d): handler(.peerDevice(partner: id, device: d))
        case .updateAvailable(let v, let u): handler(.updateAvailable(version: v, url: u))
        }
    }

    // MARK: discovery

    /// Answer "LANLINE?1" on `port` once per listening partner (and pairing code), with this device id.
    public func startResponder(port: UInt16? = nil) {
        queue.async {
            guard self.responder == nil, !self.stopped else { return }
            self.responder = try? DiscoveryResponder(port: port ?? self.config.port, name: self.config.name, device: self.config.deviceID,
                                                    pairIDs: { self.listeningPairIDs() }, queue: self.queue)   // closed in stop()
        }
    }

    private func listeningPairIDs() -> [String] {   // runs on the queue (the responder's read handler)
        order.compactMap { partners[$0] }.filter { !$0.connects }.map { PairCode.pairID(token: $0.secret) }
    }

    /// Partners this computer dials that aren't connected: look for them on the LAN (by pair id or device id),
    /// and if one answers from a new address, dial it there. Reports the new address as `.peerAddresses`.
    public func findMoved(port: UInt16? = nil, targets: [String]? = nil, timeout: TimeInterval = 1.2) {
        queue.async {
            let lost = self.order.compactMap { self.partners[$0] }.filter { $0.connects && !self.up.contains($0.id) }
            guard !lost.isEmpty, !self.stopped else { return }
            Discovery.search(port: port ?? self.config.port, timeout: timeout, targets: targets, queue: self.queue) { found in
                guard !self.stopped else { return }
                for p in lost where !self.up.contains(p.id) {
                    let pid = PairCode.pairID(token: p.secret)
                    guard let hit = found.first(where: { $0.pairID == pid || ($0.device != nil && $0.device == p.id) }),
                          !p.hosts.contains(hit.host) || p.hosts.first != hit.host else { continue }
                    var q = p
                    q.hosts = [hit.host] + p.hosts.filter { $0 != hit.host }
                    self.partners[p.id] = q
                    let old = self.sessions.removeValue(forKey: p.id)
                    self.handler(.peerAddresses(partner: p.id, q.hosts))
                    DispatchQueue.global().async {
                        let kept = old?.stopKeepingPartials() ?? [:]   // a file cut off by the address change stays resumable
                        self.queue.async {
                            if !self.stopped, self.partners[p.id] != nil, self.sessions[p.id] == nil { self.makeSession(p.id, pairing: false, partials: kept) }
                            else { for k in kept.values { try? FileManager.default.removeItem(at: k.part) } }
                        }
                    }
                }
            }
        }
    }

    // MARK: the shared listener

    private func ensureListener() {
        guard listener == nil, !stopped, partners.values.contains(where: { !$0.connects }) else { return }
        do {
            let l = try SocketListener(bindHost: config.bindHost, port: config.port, queue: queue) { [weak self] fd, peer in
                self?.accept(fd: fd, peer: peer)
            }
            listener = l
            _boundPort = l.port
            handler(.listening(l.port))
        } catch {
            handler(.error("listen failed: \(error.localizedDescription)"))
        }
    }

    private func accept(fd: Int32, peer: String) {
        guard !stopped, pending.count < Session.maxPending else { close(fd); return }   // strangers can't pile up connections
        let l = Link.accepted(fd: fd, peer: peer, queue: queue, openedAt: Date())
        pending[ObjectIdentifier(l)] = (l, Date())
        l.start { [weak self, weak l] ev in
            guard let self, let l else { return }
            switch ev {
            case .text(let s): self.route(l, s)
            case .closed: self.pending[ObjectIdentifier(l)] = nil
            case .data: l.close("binary before hello")
            case .ready: break
            }
        }
    }

    /// The first frame decides which partner this is: the listening partner whose secret the MAC matches.
    private func route(_ l: Link, _ s: String) {
        pending[ObjectIdentifier(l)] = nil
        guard let f = Frame.decode(s), f.type == "hello" else { l.close("bad hello"); return }
        guard f.v == LL2.version else {
            l.send(text: Frame.upgrade.json)
            handler(.status(partner: "", "The other computer runs an older Lan-Line. Update it to connect."))
            l.close("peer speaks protocol v\(f.v ?? 0)")
            return
        }
        for id in order {
            guard let p = partners[id], !p.connects, let session = sessions[id], session.matchesHello(f) else { continue }
            session.adopt(l, hello: s)
            return
        }
        l.send(text: Frame.refused.json)
        l.close("bad hello")
    }

    private func dropSilent() {
        let now = Date()
        for (k, p) in pending where now.timeIntervalSince(p.opened) > 10 {
            pending[k] = nil
            p.link.close("no hello within 10 s")
        }
    }
}
