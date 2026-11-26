import AppKit
import SwiftUI
import LanLineCore
import Combine

struct TourActions { var done: () -> Void = {} }

/// One feed row: an item (text or file, either direction) or a small note.
struct Row: Identifiable {
    let id: String
    var item: Item?
    var note: String?
    /// An update notice: the release page it links to (Install fetches the signed update; beta.10).
    var link: URL?
    /// With 2+ partners: who sent it ("from STUDIO-PC") or where it went ("to Intel Mac", "to everyone").
    var label: String?
    /// Outgoing to several partners: how many have it so far.
    var delivered = 0, total = 1
    /// Incoming: the partner it comes from (to cancel one that is still arriving).
    var partner: String?
    /// When it happened (history rows; live rows are "now").
    var at: Date?
}

/// Something shared into Lan-Line (Finder → Share), waiting above the message box until the user presses Send.
struct StagedItem: Identifiable, Equatable {
    enum Kind: Equatable { case path(URL), text(String) }
    let id = UUID()
    let kind: Kind
    var label: String {
        switch kind {
        case .path(let u): return u.lastPathComponent
        case .text(let t): return t.count > 40 ? String(t.prefix(40)) + "…" : t
        }
    }
}

/// One paired computer as the window shows it.
struct PartnerInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var up = false
}

/// Pairing screen state. `show` = this computer shows a code and waits; `enter` = it types the other's code.
enum PairMode { case show, enter }

/// Everything the window shows. Lives on the main thread; the Session's events reach it through
/// the one hop in `AppController.startSession`.
@MainActor
final class AppModel: ObservableObject {
    @Published var rows: [Row] = []
    @Published var connected = false
    @Published var peer = ""
    @Published var status = "Starting…"
    @Published var pinned = true
    @Published var draftEmpty = true
    @Published var dropTargeted = false
    /// Translucent window (off for snapshots, which can't capture the blur).
    @Published var glass = false
    /// The backdrop opacity shown right now (follows the Settings slider live; saved on Save).
    @Published var glassOpacity = StorageSettings.defaultGlassOpacity

    // storage settings (shown over everything until the user has saved them once)
    @Published var showingSettings = false
    /// Liquid Glass controls may be used (off with --no-liquid, for checks of the solid controls).
    var liquid = true
    /// Accessibility pass (beta.10): the text size in use, and a counter that moves when macOS's display options
    /// (Increase contrast) change. The window rebuilds its views when either does.
    /// The welcome tour (beta.10): showing, and which card.
    @Published var showingTour = false
    @Published var tourPage = 0
    var tourActions = TourActions()
    @Published var textScale: Double = 1
    @Published var a11yTick = 0
    /// What is typed in the message box, kept so a rebuild of the window doesn't lose it.
    var draftKeep = ""
    /// One-click update progress (beta.10): nil = idle.
    @Published var updateStep: MacUpdater.Step?
    @Published var settingsFirstRun = false
    @Published var storage = StorageSettings()
    @Published var usageBytes: Int64 = 0
    @Published var unmanagedCount = 0
    @Published var unmanagedBytes: Int64 = 0
    @Published var removedPaths: Set<String> = []

    // pairing
    @Published var pairing = false
    @Published var pairMode: PairMode = .show
    @Published var pairCode = ""
    /// The port the pairing QR code names (beta.10, for the iPhone companion).
    @Published var pairPort: UInt16 = LanLineConfig.defaultPort
    @Published var pairShowQR = false
    @Published var myName = ""
    @Published var myAddresses: [String] = []
    @Published var found: [DiscoveredPeer] = []
    @Published var searching = false
    @Published var typedAddress = ""
    @Published var typedCode = ""
    @Published var pairError: String?
    @Published var pairBusy = false
    @Published var canCancelPairing = false

    var hub: Hub?
    /// Paired computers, in pairing order.
    @Published var partners: [PartnerInfo] = []
    /// Shared from another app, not sent yet.
    @Published var staged: [StagedItem] = []
    /// Where Send goes: nil = everyone, else a partner id.
    @Published var sendTarget: String?
    var multi: Bool { partners.count >= 2 }
    func name(_ id: String) -> String { partners.first { $0.id == id }?.name ?? "partner" }
    var targetLabel: String { sendTarget.map { name($0) } ?? "Everyone" }
    /// One line per partner, for the status dot's tooltip.
    var partnerStates: String { partners.map { "\($0.name): \($0.up ? "connected" : "not connected")" }.joined(separator: "\n") }
    var onPopUp: () -> Void = {}
    /// The row to point out (a notification was clicked); cleared after a moment.
    @Published var highlightID: String?
    /// The file card selected for Quick Look (beta.10); nil = none. Typing returns to the message box.
    @Published var selectedID: String?
    var onSelect: () -> Void = {}
    var onQuickLook: () -> Void = {}
    func select(_ id: String) { selectedID = id; onSelect() }

    // MARK: keyboard (beta.10)

    /// The shortcut list (⌘/).
    @Published var showingShortcuts = false
    /// Clipboard sharing paused from the menu (this session only).
    @Published var clipPaused = false
    /// Why a global shortcut couldn't be registered ("show", "send" → message), for Settings.
    @Published var hotKeyProblems: [String: String] = [:]

    private var itemIDs: [String] { visibleRows.filter { $0.item != nil }.map(\.id) }

    // MARK: history and search (beta.10)

    /// `history.jsonl` while "Keep history" is on (nil = off, or a demo).
    var historyURL: URL?
    /// Everything kept, oldest first (the feed shows the newest `maxRows`; search looks at all of it).
    private(set) var history: [HistoryEntry] = []
    private var recorded: Set<String> = []
    /// Files from the history that are no longer where they were.
    @Published var missingPaths: Set<String> = []

    @Published var searchOpen = false
    @Published var query = ""
    @Published var filter: HistoryFilter = .all
    var isFiltering: Bool { searchOpen && (!query.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all) }

    /// The feed as shown: every row, or the search results (history and the items still open, newest last).
    var visibleRows: [Row] {
        guard isFiltering else { return rows }
        var byID: [String: Row] = [:]
        for r in rows where r.item != nil { byID[r.id] = r }
        var out: [Row] = []
        var seen = Set<String>()
        for e in history where History.matches(e, query: query, filter: filter) {
            seen.insert(e.id)
            out.append(byID[e.id] ?? row(for: e))
        }
        for r in rows where r.item != nil && !seen.contains(r.id) {   // still moving, not in the history yet
            if History.matches(Self.entry(r.item!, who: nil), query: query, filter: filter) { out.append(r) }
        }
        return out
    }

    func loadHistory() {
        guard let url = historyURL else { return }
        history = History.load(from: url)
        try? History.compact(history, to: url)
        recorded = Set(history.map(\.id))
        var gone = Set<String>()
        for e in history where e.kind != "text" {
            if let p = e.path, !FileManager.default.fileExists(atPath: p) { gone.insert(p) }
        }
        missingPaths = gone
        rows = history.suffix(maxRows).map { row(for: $0) } + rows
    }

    /// An item reached its end (received, delivered, failed, cancelled): keep it.
    func record(_ item: Item, who: String?) {
        guard let url = historyURL, !recorded.contains(item.id) else { return }
        switch item.state { case .received, .delivered, .failed, .cancelled: break; default: return }
        recorded.insert(item.id)
        let e = Self.entry(item, who: who)
        history.append(e)
        if history.count > History.cap { history.removeFirst(history.count - History.cap) }
        try? History.append(e, to: url)
    }

    /// Forget everything kept; items still moving stay in the window.
    func clearHistory() {
        if let url = historyURL { History.clear(url) }
        history = []; recorded = []; missingPaths = []
        rows.removeAll { r in
            guard let i = r.item else { return false }
            switch i.state { case .received, .delivered, .failed, .cancelled: return true; default: return false }
        }
    }

    static func entry(_ item: Item, who: String?) -> HistoryEntry {
        var e = HistoryEntry(id: item.id, incoming: item.incoming, kind: "text", at: Date(), who: who, state: "received")
        switch item.kind {
        case .text(let t): e.text = t
        case .file(let n, let s, let u): e.kind = "file"; e.name = n; e.size = s; e.path = u.path
        case .folder(let n, let c, let s, let u): e.kind = "folder"; e.name = n; e.count = c; e.size = s; e.path = u.path
        }
        switch item.state {
        case .delivered: e.state = "delivered"
        case .failed(let why): e.state = "failed"; e.error = why
        case .cancelled: e.state = "cancelled"
        default: e.state = "received"
        }
        return e
    }

    func row(for e: HistoryEntry) -> Row {
        let kind: ItemKind
        let url = URL(fileURLWithPath: e.path ?? "/")
        switch e.kind {
        case "file": kind = .file(name: e.name ?? "file", size: e.size ?? 0, url: url)
        case "folder": kind = .folder(name: e.name ?? "folder", count: e.count ?? 0, size: e.size ?? 0, url: url)
        default: kind = .text(e.text ?? "")
        }
        let state: ItemState
        switch e.state {
        case "delivered": state = .delivered
        case "failed": state = .failed(e.error ?? "failed")
        case "cancelled": state = .cancelled
        default: state = .received
        }
        let label = multi ? e.who.map { e.incoming ? "from \($0)" : "to \($0)" } : nil
        return Row(id: e.id, item: Item(id: e.id, kind: kind, incoming: e.incoming, state: state), label: label, at: e.at)
    }

    /// Select the newest item (⌘↑ from the message box). False when the feed has none.
    @discardableResult func selectNewest() -> Bool {
        guard let id = itemIDs.last else { return false }
        select(id); return true
    }

    /// ↑ / ↓ through the items. False when ↓ passes the newest (back to the message box).
    @discardableResult func selectRelative(_ d: Int) -> Bool {
        let ids = itemIDs
        guard !ids.isEmpty else { return false }
        guard let cur = selectedID, let i = ids.firstIndex(of: cur) else { selectedID = ids.last; return true }
        let j = i + d
        guard ids.indices.contains(j) else { return d < 0 }
        selectedID = ids[j]
        return true
    }

    /// Take an item off the list (the file, if any, stays where it is). The selection moves to a neighbour.
    func removeFromList(_ id: String) {
        let ids = itemIDs
        guard let i = ids.firstIndex(of: id) else { return }
        let next = i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil)
        withAnimation(.easeOut(duration: 0.2)) { rows.removeAll { $0.id == id } }
        if history.contains(where: { $0.id == id }) {   // and from the history, so it doesn't come back
            history.removeAll { $0.id == id }
            if let url = historyURL { try? History.compact(history, to: url) }
            objectWillChange.send()
        }
        selectedID = next
    }
    /// The system allows Lan-Line's notifications (false = turned off in System Settings).
    @Published var notificationsAllowed = true
    /// Arrived while Lan-Line wasn't in use: the Dock badge and the menu bar dot (beta.10).
    @Published var unread = Unread()
    /// Lan-Line is in Login Items (beta.10); the system's own setting, read on launch and when Settings opens.
    @Published var openAtLogin = false
    @Published var loginNeedsApproval = false
    var onPin: (Bool) -> Void = { _ in }
    var pairActions = PairActions()
    var settingsActions = SettingsActions()
    var partnerActions = PartnerActions()
    private let maxRows = 200

    var peerLabel: String { peer.isEmpty ? "your other computer" : peer }
    var statusLine: String {
        if pairing { return connected ? "Paired with \(peer)" : "Not paired yet" }
        if connected, multi { return "Connected · \(partners.filter(\.up).count) of \(partners.count)" }
        return connected ? "Connected · \(peer.isEmpty ? "partner" : peer)" : status
    }

    func handle(_ e: HubEvent) {
        switch e {
        case .listening:
            if !connected { status = partners.isEmpty ? "Not paired yet" : "Waiting for \(peerLabel)…" }
        case .connected(let p, let n):
            if let i = partners.firstIndex(where: { $0.id == p }) { partners[i].up = true; partners[i].name = n }
            connected = true
            if partners.count == 1 { peer = n }
        case .disconnected(let p, _):
            if let i = partners.firstIndex(where: { $0.id == p }) { partners[i].up = false }
            connected = partners.contains { $0.up }
            if !connected { status = "Reconnecting…" }
        case .status(let p, let s):
            if !connected { status = Self.statusLine(s, away: p.isEmpty ? "partner" : name(p)) }
        case .received(let p, let item):
            rates[item.id] = nil
            record(item, who: name(p))
            upsert(item, label: multi ? "from \(name(p))" : nil, partner: p); onPopUp()
            refreshOverall()   // it is no longer "receiving": the Dock's progress bar follows
            if let n = ArrivalNotices.make([(name(p), item)]) { A11y.announce("\(n.title). \(n.body)") }   // VoiceOver: say what arrived
        case .incoming(let p, let item):   // still arriving, or stopped short (beta.10)
            track(item)
            switch item.state {
            case .failed:   // if a receiveFailed for this same item follows, the card already says it
                rates[item.id] = nil
                cardedFailures.insert(item.id)
            case .cancelled: rates[item.id] = nil
            default: break
            }
            upsert(item, label: multi ? "from \(name(p))" : nil, partner: p)
        case .outgoing(let h):
            upsertOutgoing(h)
        case .receiveFailed(let p, let n, let r, let id):
            if cardedFailures.remove(id) != nil { onPopUp(); return }   // this item's card already says so
            note("Couldn't receive \(n)\(multi ? " from \(name(p))" : ""): \(r)"); onPopUp()
        case .error(let msg): if !pairing { note(msg) }
        case .rekeyed, .peerAddresses, .peerDevice: break   // the controller saves these
        case .updateAvailable(let v, let u): showUpdate(version: v, url: u)
        case .clipboard: break   // the controller puts it on the pasteboard (ClipboardShare)
        }
    }

    /// The row for an outgoing item: one row for everyone, with "✓ n/m" until all have it.
    func upsertOutgoing(_ h: HubItem) {
        let item = Item(id: h.id, kind: h.kind, incoming: false, state: h.summary)
        track(item)
        record(item, who: h.total > 1 ? "everyone" : h.to.first.map { name($0) })
        let label = multi ? (h.total > 1 ? "to everyone" : h.to.first.map { "to \(name($0))" }) : nil
        if let i = rows.firstIndex(where: { $0.id == h.id }) {
            rows[i].item = item; rows[i].delivered = h.delivered; rows[i].total = h.total
            if rows[i].label == nil { rows[i].label = label }
            return
        }
        append(Row(id: h.id, item: item, label: label, delivered: h.delivered, total: h.total))
    }

    func upsert(_ item: Item, label: String? = nil, partner: String? = nil) {
        if let i = rows.firstIndex(where: { $0.id == item.id }) { rows[i].item = item; return }
        append(Row(id: item.id, item: item, label: label, partner: partner))
    }

    // MARK: transfers (beta.10)

    /// Speed estimates for items still moving.
    private var rates: [String: TransferRate] = [:]
    /// Names whose failure an incoming card already shows (so no second note).
    private var cardedFailures: Set<String> = []
    /// Everything still moving, as one fraction (weighted by size), for the Dock icon; nil = nothing moving.
    @Published var overallProgress: Double?

    static func bytes(_ k: ItemKind) -> Int64 {
        switch k { case .file(_, let s, _), .folder(_, _, let s, _): return max(s, 0); case .text: return 0 }
    }

    private func track(_ item: Item) {
        let total = Self.bytes(item.kind)
        switch item.state {
        case .sending(let f), .receiving(let f):
            var r = rates[item.id] ?? TransferRate()
            r.update(done: Int64(f * Double(total)), at: Date())
            rates[item.id] = r
        case .delivered, .sent, .failed, .cancelled, .received: rates[item.id] = nil
        case .waiting: break
        }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshOverall() } }
    }

    private func refreshOverall() {
        var done = 0.0, total = 0.0
        for r in rows {
            guard let it = r.item else { continue }
            switch it.state {
            case .sending(let f), .receiving(let f):
                let b = Double(Self.bytes(it.kind)); done += f * b; total += b
            default: break
            }
        }
        let v: Double? = total > 0 ? done / total : nil
        if v != overallProgress { overallProgress = v }
    }

    /// Screenshots: a steady speed for a demo card.
    func demoRate(_ id: String, done: Int64, bytesPerSecond: Double) {
        var r = TransferRate(); let t = Date()
        r.update(done: done - Int64(bytesPerSecond), at: t - 1); r.update(done: done, at: t)
        rates[id] = r
    }

    /// "42% · 85 MB/s · 12 s left" for a card that is moving.
    func progressText(_ item: Item) -> String? {
        let f: Double
        switch item.state { case .sending(let x), .receiving(let x): f = x; default: return nil }
        let total = Self.bytes(item.kind)
        return (rates[item.id] ?? TransferRate()).describe(done: Int64(f * Double(total)), total: total)
    }

    /// Can this item still be stopped? Queued or moving, either direction.
    func canCancel(_ item: Item) -> Bool {
        switch item.state {
        case .waiting, .sending: return !item.incoming
        case .receiving: return item.incoming
        default: return false
        }
    }

    func cancel(_ id: String) {
        guard let r = rows.first(where: { $0.id == id }), let item = r.item, canCancel(item) else { return }
        if item.incoming, let p = r.partner { hub?.cancelIncoming(partner: p, id: id) } else { hub?.cancel(id) }
    }

    /// Session diagnostics → the short line under the title. Version and pairing problems say what to do.
    static func statusLine(_ s: String, away: String) -> String {
        if s.hasPrefix("dialing") { return "Connecting to \(away)…" }
        if s.hasPrefix("Refused") { return "\(away) doesn't know this pairing: pair again" }
        if s.contains("update Lan-Line on the other") || s.hasPrefix("The other computer runs an older") { return "Update Lan-Line on \(away)" }
        if s.contains("newer Lan-Line") { return "Update Lan-Line on this Mac" }
        return "Can't reach \(away)"
    }

    /// One quiet, dismissible "Lan-Line X is available: Download" row (a newer notice replaces an older one).
    func showUpdate(version: String, url: String) {
        guard Updates.isAllowedURL(url), let link = URL(string: url) else { return }
        rows.removeAll { $0.link != nil }
        append(Row(id: "update", note: "Lan-Line \(version) is available", link: link))
    }

    /// Install (beta.10): signed update.json → download → check → stage → quit; the helper swaps and reopens.
    func installUpdate(current: String = AppInfo.version, manifest: URL = SignedUpdate.manifestURL) {
        if case .checking? = updateStep { return }
        if case .downloading? = updateStep { return }
        if case .installing? = updateStep { return }
        if let b = MacUpdater.blocker() { updateStep = .failed("Can't update in place: \(b)."); return }
        updateStep = .checking
        Task { @MainActor [weak self] in
            guard let offer = await SignedUpdate.fetchOffer(current: current, platform: .mac, from: manifest) else {
                self?.updateStep = .failed("No signed update for this Mac yet. Use Download instead."); return
            }
            let r = await MacUpdater.prepare(offer, current: current) { f in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateStep = .downloading(f) } }
            }
            guard let self else { return }
            switch r {
            case .failure(let e): self.updateStep = .failed(e.description)
            case .success(let staged):
                self.updateStep = .installing
                if MacUpdater.swapAfterExit(staged: staged) { NSApp.terminate(nil) }
                else { self.updateStep = .failed("Couldn't start the installer helper.") }
            }
        }
    }

    func highlight(_ id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        highlightID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            MainActor.assumeIsolated { if self?.highlightID == id { withAnimation(.easeOut(duration: 0.4)) { self?.highlightID = nil } } }
        }
    }

    func itemText(_ id: String) -> String? {
        if case .text(let t)? = visibleRows.first(where: { $0.id == id })?.item?.kind { return t }
        return nil
    }

    func itemURL(_ id: String) -> URL? {
        switch visibleRows.first(where: { $0.id == id })?.item?.kind {
        case .file(_, _, let u)?, .folder(_, _, _, let u)?: return u
        default: return nil
        }
    }

    func dismiss(_ id: String) { withAnimation(.easeOut(duration: 0.2)) { rows.removeAll { $0.id == id } } }

    func note(_ s: String, fadeAfter: TimeInterval? = nil) {
        let id = UUID().uuidString
        append(Row(id: id, note: s))
        if let t = fadeAfter {   // a passing remark, not something to keep in the feed
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.3)) { self?.rows.removeAll { $0.id == id } } }
            }
        }
    }

    /// New items rise into place (off for screenshots and with Reduce motion).
    var animateArrivals = false
    /// The user sent something (the send tick).
    var onSent: () -> Void = {}

    private func append(_ r: Row) {
        if animateArrivals, r.item != nil, !Motion.reduced { withAnimation(Motion.arrive) { rows.append(r) } } else { rows.append(r) }
        if rows.count > maxRows { rows.removeFirst(rows.count - maxRows) }
    }

    /// When a file chip was last dragged out of this window. A drop of that same file soon after is the chip
    /// coming back (ignore it); the same file dropped or pasted from Finder is a real resend (send it).
    var chipDragAt: Date?

    /// True only for a chip dragged out of this window and dropped back on it.
    func isChipDraggedBack(_ url: URL) -> Bool {
        guard let t = chipDragAt, Date().timeIntervalSince(t) < 60, isOwn(url) else { return false }
        chipDragAt = nil
        return true
    }

    /// True when the URL is one of our own feed items.
    func isOwn(_ url: URL) -> Bool {
        rows.contains {
            switch $0.item?.kind {
            case .file(_, _, let u)?, .folder(_, _, _, let u)?: return u.standardizedFileURL == url.standardizedFileURL
            default: return false
            }
        }
    }

    // MARK: sending

    /// Send: the staged items (if any) and the typed text (if any), to the current target.
    @discardableResult
    /// `includeStaged`: the message box's Send also sends what is staged above it. The paths that send without
    /// the window (the clipboard shortcut, a drop on the menu bar icon) send only their own text.
    func sendText(_ text: String, includeStaged: Bool = true) -> Bool {
        let typed = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let staged = includeStaged ? self.staged : []
        guard typed || !staged.isEmpty else { return false }
        guard let h = hub, !partners.isEmpty else { note("Not paired yet: nothing was sent"); return false }
        if !staged.isEmpty { sendStaged() }
        if typed { upsertOutgoing(h.send(text: text, to: sendTarget)) }
        onSent()
        return true
    }

    /// Items shared from Finder or another app wait here; nothing is sent until Send.
    func stage(_ r: StageRequest) {
        for p in r.paths where !staged.contains(where: { $0.kind == .path(URL(fileURLWithPath: p)) }) {
            staged.append(StagedItem(kind: .path(URL(fileURLWithPath: p))))
        }
        for t in r.texts { staged.append(StagedItem(kind: .text(t))) }
        if staged.count > 200 { staged.removeFirst(staged.count - 200) }
    }

    func unstage(_ id: UUID) { staged.removeAll { $0.id == id } }

    private func sendStaged() {
        let items = staged
        staged = []
        let urls = items.compactMap { if case .path(let u) = $0.kind { return u }; return nil }
        if !urls.isEmpty { sendFiles(urls) }
        for case .text(let t) in items.map(\.kind) { if let h = hub { upsertOutgoing(h.send(text: t, to: sendTarget)) } }
    }

    func sendFiles(_ urls: [URL], fromDrop: Bool = false) {
        guard let h = hub, !partners.isEmpty else { note("Not paired yet: nothing was sent"); return }
        guard !pairing else { return }
        var sentAny = false
        for raw in urls {
            let u = (raw as NSURL).isFileReferenceURL() ? ((raw as NSURL).filePathURL ?? raw) : raw
            if fromDrop && isChipDraggedBack(u) { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else {
                // Never skip silently: say why (a missing file, or macOS privacy settings blocking the folder).
                let why: String
                do { _ = try FileManager.default.attributesOfItem(atPath: u.path); why = "unknown reason" }
                catch { why = (error as NSError).localizedDescription }
                DebugLog.write("can't send \(u.path): \(why)")
                note("Couldn't read \(u.lastPathComponent): \(why)")
                continue
            }
            if isDir.boolValue {
                DebugLog.write("sending folder \(u.path)")
                let skipped = Session.scanFolder(u).skipped
                upsertOutgoing(h.send(folder: u, to: sendTarget))
                sentAny = true
                if skipped > 0 { note("\(u.lastPathComponent): \(skipped) shortcut\(skipped == 1 ? "" : "s") (symlinks) left out", fadeAfter: 8) }
                continue
            }
            DebugLog.write("sending \(u.path)")
            upsertOutgoing(h.send(file: u, to: sendTarget))
            sentAny = true
        }
        if sentAny { onSent() }
    }

    func sendImage(_ png: Data) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Lan-Line-pasted")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = Names.unique("pasted-\(f.string(from: Date())).png", in: dir)
        do { try png.write(to: url); sendFiles([url]) } catch { note("Couldn't save the pasted image") }
    }

    func togglePin() { pinned.toggle(); onPin(pinned) }
}

/// What the pairing screen can ask the controller to do.
@MainActor
struct PairActions {
    var switchMode: (PairMode) -> Void = { _ in }
    var search: () -> Void = {}
    var connect: () -> Void = {}
    var cancel: () -> Void = {}
}

/// What the Paired computers list can ask the controller to do.
@MainActor
struct PartnerActions {
    var rename: (String, String) -> Void = { _, _ in }
    var forget: (String) -> Void = { _ in }
    var pairAnother: () -> Void = {}
}

/// What the settings screen can ask the controller to do.
@MainActor
struct SettingsActions {
    var save: (StorageSettings) -> Void = { _ in }
    var cleanNow: () -> Void = {}
    var openFolder: () -> Void = {}
    var cancel: () -> Void = {}
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var clearHistory: () -> Void = {}
    /// System Settings → Notifications → Lan-Line.
    var openNotificationSettings: () -> Void = {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.avery.lan-line")!)
    }
}

/// `--debug-log PATH`: append diagnostic lines to a file (support and tests; off by default).
enum DebugLog {
    nonisolated(unsafe) static var path: String?
    static func write(_ line: String) {
        guard let path else { return }
        let l = "\(Date()) \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(l.utf8)); try? h.close() }
        else { try? l.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
