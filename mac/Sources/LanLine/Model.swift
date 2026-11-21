import AppKit
import SwiftUI
import LanLineCore
import Combine

/// One feed row: an item (text or file, either direction) or a small note.
struct Row: Identifiable {
    let id: String
    var item: Item?
    var note: String?
    /// An update notice: the release page it links to (Lan-Line never downloads anything itself).
    var link: URL?
    /// With 2+ partners: who sent it ("from STUDIO-PC") or where it went ("to Intel Mac", "to everyone").
    var label: String?
    /// Outgoing to several partners: how many have it so far.
    var delivered = 0, total = 1
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

    // storage settings (shown over everything until the user has saved them once)
    @Published var showingSettings = false
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
    /// Where Send goes: nil = everyone, else a partner id.
    @Published var sendTarget: String?
    var multi: Bool { partners.count >= 2 }
    func name(_ id: String) -> String { partners.first { $0.id == id }?.name ?? "partner" }
    var targetLabel: String { sendTarget.map { name($0) } ?? "Everyone" }
    /// One line per partner, for the status dot's tooltip.
    var partnerStates: String { partners.map { "\($0.name): \($0.up ? "connected" : "not connected")" }.joined(separator: "\n") }
    var onPopUp: () -> Void = {}
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
            upsert(item, label: multi ? "from \(name(p))" : nil); onPopUp()
        case .outgoing(let h):
            upsertOutgoing(h)
        case .receiveFailed(let p, let n, let r):
            note("Couldn't receive \(n)\(multi ? " from \(name(p))" : ""): \(r)"); onPopUp()
        case .error(let msg): if !pairing { note(msg) }
        case .rekeyed, .peerAddresses, .peerDevice: break   // the controller saves these
        case .updateAvailable(let v, let u): showUpdate(version: v, url: u)
        }
    }

    /// The row for an outgoing item: one row for everyone, with "✓ n/m" until all have it.
    func upsertOutgoing(_ h: HubItem) {
        let item = Item(id: h.id, kind: h.kind, incoming: false, state: h.summary)
        let label = multi ? (h.total > 1 ? "to everyone" : h.to.first.map { "to \(name($0))" }) : nil
        if let i = rows.firstIndex(where: { $0.id == h.id }) {
            rows[i].item = item; rows[i].delivered = h.delivered; rows[i].total = h.total
            if rows[i].label == nil { rows[i].label = label }
            return
        }
        append(Row(id: h.id, item: item, label: label, delivered: h.delivered, total: h.total))
    }

    func upsert(_ item: Item, label: String? = nil) {
        if let i = rows.firstIndex(where: { $0.id == item.id }) { rows[i].item = item; return }
        append(Row(id: item.id, item: item, label: label))
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

    private func append(_ r: Row) {
        rows.append(r)
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

    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let h = hub, !partners.isEmpty else { return false }
        upsertOutgoing(h.send(text: text, to: sendTarget))
        return true
    }

    func sendFiles(_ urls: [URL], fromDrop: Bool = false) {
        guard let h = hub, !partners.isEmpty else { note("Not paired yet: nothing was sent"); return }
        guard !pairing else { return }
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
                if skipped > 0 { note("\(u.lastPathComponent): \(skipped) shortcut\(skipped == 1 ? "" : "s") (symlinks) left out", fadeAfter: 8) }
                continue
            }
            DebugLog.write("sending \(u.path)")
            upsertOutgoing(h.send(file: u, to: sendTarget))
        }
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
