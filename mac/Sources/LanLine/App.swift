import Combine
import AppKit
import SwiftUI
import LanLineCore

/// Owns the panel and the one Session. Everything here runs on the main thread.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: Options
    let model = AppModel()
    var panel: NSPanel!
    private var menuBar: MenuBarItem!

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ n: Notification) {
        switch options.value("--appearance") {   // for screenshots; normally the system setting decides
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        DebugLog.path = options.value("--debug-log")
        buildMenu()
        menuBar = MenuBarItem(model: model, actions: .init(
            show: { [weak self] in self?.showPanel(activate: true) },
            pair: { [weak self] in self?.pairFromMenu() },
            settings: { [weak self] in self?.settingsFromMenu() },
            checkUpdates: { [weak self] in self?.checkFromMenu() }))
        model.glass = options.value("--snapshot") == nil && !options.flag("--no-glass")
        buildPanel()
        if let m = options.value("--demo-settings") { Demo.settings(model, firstRun: m == "first") }
        else if let m = options.value("--demo-pair") { Demo.pair(model, mode: m) }
        else if options.flag("--demo-multi") { Demo.multi(model) }
        else if options.flag("--demo") { Demo.fill(model, empty: options.flag("--empty")) } else { boot() }
        if let v = options.value("--glass-opacity").flatMap(Double.init) {   // screenshots of the opacity setting
            model.storage.glassOpacity = StorageSettings.clampOpacity(v)
            model.glassOpacity = model.storage.glassOpacityValue
        }
        if let out = options.value("--snapshot") { snapshot(to: out) } else { applyKeepRunning() }
        // Checks of the close / reopen path (beta.9): close the window after S seconds, show it again after T.
        if let s = options.value("--test-close-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in self?.panel.performClose(nil) }
        }
        if let s = options.value("--test-reopen-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in self?.showPanel(activate: true) }
        }
    }

    /// The menu bar icon is there while "Keep running in the menu bar" is on (beta.9).
    private func applyKeepRunning() {
        if model.storage.keepRunningWhenClosedValue { menuBar.show() } else { menuBar.hide() }
        if !model.storage.keepRunningWhenClosedValue || panel.isVisible { NSApp.setActivationPolicy(.regular) }
    }

    /// `--snapshot PATH`: render the window (off-screen) to a PNG and quit. For design checks in both themes.
    private func snapshot(to path: String) {
        if let sz = options.value("--snapshot-size")?.split(separator: "x"), sz.count == 2, let w = Double(sz[0]), let h = Double(sz[1]) {
            panel.setContentSize(NSSize(width: w, height: h))
        }
        panel.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [panel] in
            guard let panel, let frameView = panel.contentView?.superview else { exit(1) }
            frameView.layoutSubtreeIfNeeded()
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(1) }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel(activate: true)
        return true
    }

    func applicationWillTerminate(_ n: Notification) { stopAll() }

    /// `lanline://stage?p=<path>&t=<text>`: from the Share extension (or `open lanline://…`). Stages, never sends.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            guard let s = StageRequest(url: u) else { DebugLog.write("ignored url \(u.scheme ?? "?")://\(u.host ?? "")"); continue }
            DebugLog.write("stage request: \(s.paths.count) paths, \(s.texts.count) texts")
            model.stage(s)
            showPanel(activate: true)
        }
    }

    // MARK: session and pairing

    private var pairTimeout: DispatchWorkItem?
    private var rediscover: Timer?

    private var port: UInt16 { options.value("--port").flatMap(UInt16.init) ?? device.port }

    // MARK: storage (received-file cleanup)

    private var settingsURL: URL { options.configURL.deletingLastPathComponent().appendingPathComponent("settings.json") }
    private var logURL: URL { options.configURL.deletingLastPathComponent().appendingPathComponent("received.json") }
    private var cleanupTimer: Timer?
    private var frameBeforeSettings: NSRect?
    private var blurFade: AnyCancellable?

    private func setUpStorage() {
        model.storage = StorageSettings.load(from: settingsURL)
        model.glassOpacity = model.storage.glassOpacityValue
        model.settingsActions = SettingsActions(
            save: { [weak self] s in self?.saveSettings(s) },
            cleanNow: { [weak self] in self?.runCleanup(manual: true) },
            openFolder: { [weak self] in
                guard let self else { return }
                let dir = self.options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? LanLineConfig.downloadsDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            },
            cancel: { [weak self] in
                guard let self else { return }
                self.model.glassOpacity = self.model.storage.glassOpacityValue   // undo a slider preview
                self.model.showingSettings = false; self.restoreAfterSettings()
            })
        runCleanup(manual: false)
        if let a = savedLatest() { model.showUpdate(version: a.version.description, url: a.url) }
        checkForUpdates(manual: false)
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runCleanup(manual: false); self?.checkForUpdates(manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        cleanupTimer = t
        if !model.storage.confirmed { showSettings(firstRun: true) }   // every launch until saved once
    }

    // MARK: updates (the only network call; manual, or daily if the user turned it on)

    /// The saved "newest version heard of", if it is still newer than this app.
    private func savedLatest() -> Updates.Available? {
        guard let s = model.storage.latestVersion, let v = LanLineVersion(s), let u = model.storage.latestURL, Updates.isAllowedURL(u),
              let own = LanLineVersion(options.value("--app-version") ?? AppInfo.version), v > own else { return nil }
        return Updates.Available(version: v, url: u)
    }

    @objc func checkFromMenu() { checkForUpdates(manual: true) }

    private func checkForUpdates(manual: Bool) {
        guard manual || Updates.dueForAutoCheck(model.storage, now: Date()) else { return }
        let current = options.value("--app-version") ?? AppInfo.version
        guard LanLineVersion(current) != nil else { if manual { model.note("This build has no version number to compare.", fadeAfter: 6) }; return }
        var s = model.storage; s.lastUpdateCheck = Date(); model.storage = s; try? s.save(to: settingsURL)
        Task { @MainActor [weak self] in
            let r = await Updates.fetchLatest(current: current)
            guard let self else { return }
            if case .available(let a) = r {
                self.model.hub?.noteLatest(a)   // shows it here and tells the partners
                self.model.showUpdate(version: a.version.description, url: a.url)
                if manual { self.model.showUpdate(version: a.version.description, url: a.url) }
            } else if let m = Updates.message(r, manual: manual) {
                self.model.note(m, fadeAfter: 6)
            }
        }
    }

    private func showSettings(firstRun: Bool = false) {
        model.settingsFirstRun = firstRun
        refreshUsage()
        model.showingSettings = true
        if panel.frame.height < 470 { frameBeforeSettings = panel.frame }
        growPanel(to: 470)
    }

    private func saveSettings(_ s: StorageSettings) {
        var n = s
        n.lastTrashReminder = model.storage.lastTrashReminder
        n.lastLimitWarning = model.storage.lastLimitWarning
        n.lastUpdateCheck = model.storage.lastUpdateCheck
        n.latestVersion = model.storage.latestVersion; n.latestURL = model.storage.latestURL
        model.storage = n
        model.glassOpacity = n.glassOpacityValue
        do { try n.save(to: settingsURL) } catch { model.note("Couldn't save settings: \(error.localizedDescription)") }
        model.showingSettings = false
        model.settingsFirstRun = false
        restoreAfterSettings()
        runCleanup(manual: false)
        applyKeepRunning()
    }

    /// Settings grew the window; put it back as it was (unless pairing still needs the room).
    private func restoreAfterSettings() {
        if let f = frameBeforeSettings, !model.pairing { panel.setFrame(f, display: true, animate: true) }
        frameBeforeSettings = nil
    }

    private func logReceived(_ url: URL, size: Int64) {
        var log = ReceivedLog.load(from: logURL)
        log.removeAll { $0.path == url.path }
        log.append(ReceivedFile(path: url.path, size: size, receivedAt: Date()))
        try? ReceivedLog.save(log, to: logURL)
        runCleanup(manual: false)
    }

    private func refreshUsage() {
        let existing = ReceivedLog.load(from: logURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        model.usageBytes = existing.reduce(0) { $0 + $1.size }
        // Files in the folder that Lan-Line doesn't manage (received before 0.9.0-beta.3, or put there by hand).
        let dir = options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? LanLineConfig.downloadsDir
        let managed = Set(existing.map(\.path))
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var n = 0, bytes: Int64 = 0
        for u in items where !managed.contains(u.path) {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            n += 1; bytes += Int64(v.fileSize ?? 0)
        }
        model.unmanagedCount = n; model.unmanagedBytes = bytes
    }

    /// Move expired / over-limit received files to the Trash, then say so quietly. Never deletes anything else.
    private func runCleanup(manual: Bool) {
        let fm = FileManager.default
        let log = ReceivedLog.load(from: logURL)
        let existing = log.filter { fm.fileExists(atPath: $0.path) }
        let now = Date()
        var s = model.storage
        let plan = Cleanup.plan(existing, settings: s, now: now)
        var moved: [ReceivedFile] = []
        for f in plan.toTrash {
            do { try fm.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil); moved.append(f) }
            catch { DebugLog.write("trash failed \(f.path): \(error)") }
        }
        let movedPaths = Set(moved.map(\.path))
        let kept = existing.filter { !movedPaths.contains($0.path) }
        if kept.count != log.count { try? ReceivedLog.save(kept, to: logURL) }
        model.removedPaths.formUnion(movedPaths)
        model.usageBytes = kept.reduce(0) { $0 + $1.size }
        var changed = false
        if !moved.isEmpty {
            let size = Cleanup.formatBytes(moved.reduce(0) { $0 + $1.size })
            let why = plan.expired.isEmpty ? "to stay under your \(Cleanup.formatBytes(plan.limitBytes)) limit"
                                           : "older than \(s.retentionDays) day\(s.retentionDays == 1 ? "" : "s")"
            model.note("Moved \(moved.count) received file\(moved.count == 1 ? "" : "s") (\(size)) to the Trash, \(why).")
            if Cleanup.shouldRemindTrash(s, movedSomething: true, now: now) {
                model.note("Old received files go to the Trash. Empty it once you've had a look. (Turn this reminder off in Settings.)")
                s.lastTrashReminder = now; changed = true
            }
        } else if manual {
            model.note("Nothing to clean up. Received files use \(Cleanup.formatBytes(plan.usageBytes)).", fadeAfter: 6)
        }
        if Cleanup.shouldWarnLimit(s, level: plan.level, now: now) || (manual && plan.level > 0) {
            let used = Cleanup.formatBytes(plan.usageBytes), lim = Cleanup.formatBytes(plan.limitBytes)
            model.note(plan.level == 2
                ? "Received files use \(used), over your \(lim) limit. Raise it or turn on cleanup in Settings (⌘,)."
                : "Received files use \(used) of your \(lim) limit.")
            s.lastLimitWarning = now; changed = true
        }
        if changed { model.storage = s; try? s.save(to: settingsURL) }
    }

    /// Make the window tall enough for a settings or pairing screen.
    private func growPanel(to h: CGFloat) {
        guard let panel, panel.frame.height < h else { return }
        var f = panel.frame; f.origin.y -= h - f.height; f.size.height = h
        panel.setFrame(f, display: true, animate: true)
    }

    @objc func settingsFromMenu() { showPanel(activate: true); showSettings() }

    private func boot() {
        model.myName = options.name
        model.pairActions = PairActions(
            switchMode: { [weak self] m in self?.beginPairing(m) },
            search: { [weak self] in self?.search() },
            connect: { [weak self] in self?.tryConnect() },
            cancel: { [weak self] in self?.cancelPairing() })
        model.partnerActions = PartnerActions(
            rename: { [weak self] id, name in self?.renamePartner(id, name) },
            forget: { [weak self] id in self?.forgetPartner(id) },
            pairAnother: { [weak self] in self?.model.showingSettings = false; self?.restoreAfterSettings(); self?.beginPairing(.show) })
        var loaded = (try? DeviceConfig.load(from: options.configURL, defaultRole: "listen")) ?? DeviceConfig()
        if let host = options.value("--connect"), loaded.peers.isEmpty, let legacy = try? LanLineConfig.load(from: options.configURL) {
            loaded.peers = [Partner(id: "legacy", name: legacy.peer ?? host, secret: legacy.token, role: "connect", hosts: [host])]   // flags win
        }
        book = PairingBook(config: loaded)
        save()
        startHub()
        if device.peers.isEmpty { beginPairing(.show) }
        setUpStorage()
    }

    /// Saved partners plus the pairing in progress; every Hub event goes through it (PairingBook).
    private var book = PairingBook(config: DeviceConfig())
    private var device: DeviceConfig { book.config }

    private var downloadsDir: URL { options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? LanLineConfig.downloadsDir }

    /// One Hub for all partners: it listens for those that dial us, dials those we dial, and answers discovery.
    private func startHub() {
        var hc = HubConfig(name: options.name, deviceID: device.deviceID, downloadDir: downloadsDir)
        hc.port = port
        hc.appVersion = options.value("--app-version") ?? AppInfo.version
        hc.latestKnown = savedLatest()
        hc.advertise = Discovery.localAddresses()
        // The one main-thread hop: the Hub calls this on its own queue.
        let h = Hub(config: hc, partners: device.peers) { [weak self] e in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.event(e) } }
        }
        model.hub = h
        model.partners = device.peers.map { PartnerInfo(id: $0.id, name: $0.name) }
        model.status = device.peers.isEmpty ? "Not paired yet" : "Starting…"
        h.start()
        h.startResponder()
        // Partners we dial that moved (DHCP) are found again by pair id or device id.
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.hub?.findMoved() } }
        RunLoop.main.add(t, forMode: .common)
        rediscover = t
    }

    private var debugPasteDone = false

    private func event(_ e: HubEvent) {
        if case .received(_, let item) = e {   // a received folder is kept (and cleaned up) as one entry
            switch item.kind {
            case .file(_, let size, let url), .folder(_, _, let size, let url): logReceived(url, size: size)
            case .text: break
            }
        }
        let (ev, effects) = book.handle(e)   // event ids follow renames; the pairing in progress finishes here
        for f in effects { apply(f) }
        if case .updateAvailable(let v, let u) = ev, model.storage.latestVersion != v {   // remember it across launches
            var s = model.storage; s.latestVersion = v; s.latestURL = u; model.storage = s
            try? s.save(to: settingsURL)
        }
        let e = ev
        model.handle(e)
        // --debug-paste PATH: once connected, put PATH on the clipboard the way Finder's Copy does and run Paste.
        if case .connected = e, !debugPasteDone, let path = options.value("--debug-paste") {
            debugPasteDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    let pb = NSPasteboard.general
                    if path != "-" {   // "-" = paste whatever is on the clipboard now
                        pb.clearContents()
                        pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                    }
                    let tv = self?.panel.contentView.flatMap { Self.findInput(in: $0) }
                    DebugLog.write("debug paste: types=\(pb.types?.map(\.rawValue).joined(separator: ",") ?? "-") input=\(tv == nil ? "missing" : "found")")
                    tv?.paste(nil)
                }
            }
        }
    }

    /// Carry out what the PairingBook decided, in order.
    private func apply(_ f: PairingBook.Effect) {
        switch f {
        case .save: save()
        case .hubRemove(let id):
            model.hub?.remove(id)
            model.partners.removeAll { $0.id == id }
            if model.sendTarget == id { model.sendTarget = nil }
        case .hubRename(let old, let new): model.hub?.rename(partner: old, to: new)
        case .renamedLocally(let old, let new):
            if let i = model.partners.firstIndex(where: { $0.id == old }) { model.partners[i] = PartnerInfo(id: new, name: model.partners[i].name, up: model.partners[i].up) }
            if model.sendTarget == old { model.sendTarget = new }
        case .finished(let p): finishPairing(p)
        }
    }

    private func save() {
        do { try device.save(to: options.configURL) } catch { model.note("Couldn't save the pairing: \(error.localizedDescription)") }
    }

    private func stopAll() {
        model.hub?.stop(); model.hub = nil
        pairTimeout?.cancel(); pairTimeout = nil
        rediscover?.invalidate(); rediscover = nil
        model.connected = false
    }

    // MARK: pairing adds a partner; the others stay connected


    private func beginPairing(_ mode: PairMode) {
        if let id = book.cancel() { model.hub?.remove(id); model.partners.removeAll { $0.id == id } }
        pairTimeout?.cancel()
        model.pairing = true
        model.pairMode = mode
        model.pairError = nil
        model.pairBusy = false
        model.canCancelPairing = !device.peers.isEmpty
        growPanel(to: 430)   // the pairing screen needs a little more room than the feed
        guard device.peers.count < DeviceConfig.maxPartners else {
            model.pairError = "Lan-Line pairs with up to \(DeviceConfig.maxPartners) computers. Forget one in Settings first."
            return
        }
        switch mode {
        case .show:
            let code = PairCode.generate()
            model.pairCode = code
            model.myAddresses = Discovery.localAddresses()
            let p = Partner(id: "pairing-" + UUID().uuidString.prefix(8), name: "New computer", secret: code, role: "listen", hosts: [])
            book.begin(p)
            model.hub?.add(p, pairing: true)   // the hub's responder now also answers for this code
        case .enter:
            search()
        }
    }

    private func cancelPairing() {
        if let id = book.cancel() { model.hub?.remove(id) }
        pairTimeout?.cancel()
        model.pairing = false
        model.pairBusy = false
    }

    /// The PairingBook saved the new partner: show it and leave the pairing screen.
    private func finishPairing(_ p: Partner) {
        pairTimeout?.cancel()
        if let i = model.partners.firstIndex(where: { $0.id == p.id }) { model.partners[i].name = p.name; model.partners[i].up = true }
        else { model.partners.append(PartnerInfo(id: p.id, name: p.name, up: true)) }
        model.pairing = false
        model.pairBusy = false
        if model.multi { model.note("Paired with \(p.name). Send goes to everyone; pick one computer next to Send.", fadeAfter: 10) }
    }

    private func search() {
        model.searching = true
        Discovery.search(port: port, queue: .main) { [weak self] peers in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.searching = false
                self.model.found = peers
                if self.model.typedAddress.isEmpty, peers.count == 1 { self.model.typedAddress = peers[0].host }
            }
        }
    }

    private func tryConnect() {
        let host = model.typedAddress.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { model.pairError = "Pick a computer above or type its address."; return }
        guard let code = PairCode.normalize(model.typedCode) else {
            model.pairError = "The code is 10 letters and numbers, like 7QK4M-2XH9C."; return
        }
        model.pairError = nil
        model.pairBusy = true
        let p = Partner(id: "pairing-" + UUID().uuidString.prefix(8), name: host, secret: code, role: "connect", hosts: [host])
        book.begin(p)
        model.hub?.add(p, pairing: false)
        let t = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let q = self.book.pending, q.id == p.id || q.id == self.book.resolve(p.id) else { return }
                _ = self.book.cancel()
                self.model.hub?.remove(q.id)
                self.model.pairBusy = false
                self.model.pairError = "Couldn't pair. Check the code, and that Lan-Line is open on \(host)."
            }
        }
        pairTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: t)
    }

    private func renamePartner(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        for f in book.rename(id, to: n) { apply(f) }
        if let i = model.partners.firstIndex(where: { $0.id == id }) { model.partners[i].name = String(n.prefix(64)) }
    }

    private func forgetPartner(_ id: String) {
        for f in book.forget(id) { apply(f) }
        model.connected = model.partners.contains { $0.up }
        if device.peers.isEmpty { model.status = "Not paired yet" }
    }

    static func findInput(in v: NSView) -> InputTextView? {
        if let t = v as? InputTextView { return t }
        for sub in v.subviews { if let t = findInput(in: sub) { return t } }
        return nil
    }

    @objc func pairFromMenu() { showPanel(activate: true); beginPairing(.show) }

    // MARK: window

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Lan-Line"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.minSize = NSSize(width: 300, height: 230)
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.delegate = self
        p.setAccessibilityIdentifier("LanLinePanel")
        let host = NSHostingView(rootView: ContentView(model: model))
        if model.glass {
            // Smoked glass: the system blurs what is behind the window; the SwiftUI background tints it.
            p.isOpaque = false
            p.backgroundColor = .clear
            // The blur is a layer *under* the content (not its parent), so the opacity setting can fade it
            // without touching text.
            let root = NSView()
            let fx = NSVisualEffectView()
            fx.material = .underWindowBackground
            fx.blendingMode = .behindWindow
            fx.state = .active          // stay glassy while another app is in front (the panel floats)
            for v in [fx, host] as [NSView] { v.frame = root.bounds; v.autoresizingMask = [.width, .height]; root.addSubview(v) }
            p.contentView = root
            blurFade = model.$glassOpacity.sink { [weak fx] v in fx?.alphaValue = StorageSettings.blurAlpha(v) }
        } else {
            p.contentView = host
        }
        model.onPin = { [weak self] _ in self?.applyPin() }
        model.onPopUp = { [weak self] in self?.popUp() }
        panel = p
        applyPin()
        if !p.setFrameUsingName("LanLinePanel") { p.center() }
        p.setFrameAutosaveName("LanLinePanel")
        if options.value("--snapshot") == nil {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            p.orderFrontRegardless()
        }
    }

    private func applyPin() {
        let on = model.pinned
        panel.level = on ? .floating : .normal
        panel.isFloatingPanel = on
        panel.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
    }

    /// Something arrived: bring the window back even if it was minimized, hidden or closed.
    private func popUp() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }   // back in the Dock while shown
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
    }

    func showPanel(activate: Bool) {
        popUp()
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing hides; ⌘Q quits. With "Keep running in the menu bar" on (the default) Lan-Line also leaves the
        // Dock and stays in the menu bar; otherwise the Dock icon stays. Either brings it back, as does a new item.
        panel.orderOut(nil)
        if model.storage.keepRunningWhenClosedValue, menuBar.isShown { NSApp.setActivationPolicy(.accessory) }
        return false
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lan-Line", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkFromMenu), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Pair with Another Computer…", action: #selector(pairFromMenu), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lan-Line", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lan-Line", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Show Lan-Line", action: #selector(showFromMenu), keyEquivalent: "0")
        win.addItem(withTitle: "Keep on Top", action: #selector(togglePinFromMenu), keyEquivalent: "p")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc private func showFromMenu() { showPanel(activate: true) }
    @objc private func togglePinFromMenu() { model.togglePin() }
}
