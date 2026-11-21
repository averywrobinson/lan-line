import AppKit
import FerryCore
import Observation

/// One feed row: an item (text or file, either direction) or a small note.
struct Row: Identifiable {
    let id: String
    var item: Item?
    var note: String?
}

/// Pairing screen state. `show` = this computer shows a code and waits; `enter` = it types the other's code.
enum PairMode { case show, enter }

/// Everything the window shows. Lives on the main thread; the Session's events reach it through
/// the one hop in `AppController.startSession`.
@MainActor @Observable
final class AppModel {
    var rows: [Row] = []
    var connected = false
    var peer = ""
    var status = "Starting…"
    var pinned = true
    var draftEmpty = true
    var dropTargeted = false
    /// Translucent window (off for snapshots, which can't capture the blur).
    var glass = false

    // pairing
    var pairing = false
    var pairMode: PairMode = .show
    var pairCode = ""
    var myName = ""
    var myAddresses: [String] = []
    var found: [DiscoveredPeer] = []
    var searching = false
    var typedAddress = ""
    var typedCode = ""
    var pairError: String?
    var pairBusy = false
    var canCancelPairing = false

    @ObservationIgnored var session: Session?
    @ObservationIgnored var onPopUp: () -> Void = {}
    @ObservationIgnored var onPin: (Bool) -> Void = { _ in }
    @ObservationIgnored var pairActions = PairActions()
    private let maxRows = 200

    var peerLabel: String { peer.isEmpty ? "your other computer" : peer }
    var statusLine: String {
        if pairing { return connected ? "Paired with \(peer)" : "Not paired yet" }
        return connected ? "Connected · \(peer.isEmpty ? "partner" : peer)" : status
    }

    func handle(_ e: SessionEvent) {
        let away = peer.isEmpty ? "partner" : peer
        switch e {
        case .listening: status = "Waiting for \(away)…"
        case .connected(let p): connected = true; peer = p
        case .disconnected: connected = false; status = "Reconnecting…"
        case .status(let s): if !connected { status = s.hasPrefix("dialing") ? "Connecting to \(away)…" : "Can't reach \(away)" }
        case .received(let item): upsert(item); onPopUp()
        case .outgoing(let item): upsert(item)
        case .receiveFailed(let name, let reason): note("Couldn't receive \(name): \(reason)"); onPopUp()
        case .error(let msg): if !pairing { note(msg) }
        }
    }

    func upsert(_ item: Item) {
        if let i = rows.firstIndex(where: { $0.id == item.id }) { rows[i].item = item; return }
        append(Row(id: item.id, item: item))
    }

    func note(_ s: String) { append(Row(id: UUID().uuidString, note: s)) }

    private func append(_ r: Row) {
        rows.append(r)
        if rows.count > maxRows { rows.removeFirst(rows.count - maxRows) }
    }

    /// True when the URL is one of our own feed items (a chip dragged back onto the window).
    func isOwn(_ url: URL) -> Bool {
        rows.contains { if case .file(_, _, let u)? = $0.item?.kind { return u.standardizedFileURL == url.standardizedFileURL }; return false }
    }

    // MARK: sending

    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let s = session else { return false }
        upsert(s.send(text: text))
        return true
    }

    func sendFiles(_ urls: [URL]) {
        guard let s = session, !pairing else { return }
        for u in urls where !isOwn(u) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { note("Folders can't be sent yet: \(u.lastPathComponent)"); continue }
            upsert(s.send(file: u))
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
