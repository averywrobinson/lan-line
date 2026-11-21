import AppKit
import SwiftUI
import LanLineCore

/// Owns the panel and the one Session. Everything here runs on the main thread.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: Options
    let model = AppModel()
    var panel: NSPanel!

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ n: Notification) {
        switch options.value("--appearance") {   // for screenshots; normally the system setting decides
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        buildMenu()
        model.glass = options.value("--snapshot") == nil && !options.flag("--no-glass")
        buildPanel()
        if let m = options.value("--demo-settings") { Demo.settings(model, firstRun: m == "first") }
        else if let m = options.value("--demo-pair") { Demo.pair(model, mode: m) }
        else if options.flag("--demo") { Demo.fill(model, empty: options.flag("--empty")) } else { boot() }
        if let out = options.value("--snapshot") { snapshot(to: out) }
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

    // MARK: session and pairing

    private var config: LanLineConfig?          // the saved pairing, if any
    private var pending: LanLineConfig?         // a pairing being tried, saved once it connects
    private var responder: DiscoveryResponder?
    private var pairTimeout: DispatchWorkItem?
    private var rediscover: Timer?

    private var port: UInt16 { options.value("--port").flatMap(UInt16.init) ?? config?.port ?? LanLineConfig.defaultPort }

    // MARK: storage (received-file cleanup)

    private var settingsURL: URL { options.configURL.deletingLastPathComponent().appendingPathComponent("settings.json") }
    private var logURL: URL { options.configURL.deletingLastPathComponent().appendingPathComponent("received.json") }
    private var cleanupTimer: Timer?
    private var frameBeforeSettings: NSRect?

    private func setUpStorage() {
        model.storage = StorageSettings.load(from: settingsURL)
        model.settingsActions = SettingsActions(
            save: { [weak self] s in self?.saveSettings(s) },
            cleanNow: { [weak self] in self?.runCleanup(manual: true) },
            openFolder: { [weak self] in
                guard let self else { return }
                let dir = self.options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? LanLineConfig.downloadsDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            },
            cancel: { [weak self] in self?.model.showingSettings = false; self?.restoreAfterSettings() })
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
                if let session = self.model.session { session.noteLatest(a) } else { self.model.showUpdate(version: a.version.description, url: a.url) }
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
        do { try n.save(to: settingsURL) } catch { model.note("Couldn't save settings: \(error.localizedDescription)") }
        model.showingSettings = false
        model.settingsFirstRun = false
        restoreAfterSettings()
        runCleanup(manual: false)
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

    @objc private func settingsFromMenu() { showPanel(activate: true); showSettings() }

    private func boot() {
        DebugLog.path = options.value("--debug-log")
        model.myName = options.name
        model.pairActions = PairActions(
            switchMode: { [weak self] m in self?.beginPairing(m) },
            search: { [weak self] in self?.search() },
            connect: { [weak self] in self?.tryConnect() },
            cancel: { [weak self] in if let c = self?.config { self?.run(c) } })
        if let c = try? LanLineConfig.load(from: options.configURL) { run(c) }
        else if options.value("--connect") != nil { run(options.loadConfig()) }   // flags win; loadConfig explains a bad path
        else { beginPairing(.show) }
        setUpStorage()
    }

    /// Normal operation with a saved pairing.
    private func run(_ cfg: LanLineConfig) {
        stopAll()
        config = cfg
        model.pairing = false
        model.peer = cfg.peer ?? ""
        model.status = "Starting…"
        startSession(cfg)
        if !cfg.connects {
            responder = try? DiscoveryResponder(port: cfg.port, name: options.name, pairID: PairCode.pairID(token: cfg.token), queue: .main)
        } else {
            // If the partner's address changes (DHCP), find it again by its pair id.
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.findMovedPartner() } }
            RunLoop.main.add(t, forMode: .common)
            rediscover = t
        }
    }

    private func startSession(_ cfg: LanLineConfig, pairing: Bool = false) {
        var sc = SessionConfig(token: cfg.token, name: options.name,
                               downloadDir: options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? LanLineConfig.downloadsDir)
        sc.rekeyOnPair = pairing && !cfg.connects
        sc.appVersion = options.value("--app-version") ?? AppInfo.version
        sc.latestKnown = savedLatest()
        if !cfg.connects && options.value("--connect") == nil { sc.advertise = Discovery.localAddresses() }
        // The one main-thread hop: the Session calls this on its own queue.
        let s = Session(role: options.role(cfg), config: sc) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.event(event) } }
        }
        model.session = s
        s.start()
    }

    private var debugPasteDone = false

    private func event(_ e: SessionEvent) {
        if case .received(let item) = e {   // a received folder is kept (and cleaned up) as one entry
            switch item.kind {
            case .file(_, let size, let url), .folder(_, _, let size, let url): logReceived(url, size: size)
            case .text: break
            }
        }
        if case .rekeyed(let t) = e {   // the pairing code was swapped for a long-term secret
            if var p = pending { p.token = t; pending = p }
            else if var c = config { c.token = t; save(c); config = c }
        }
        if case .updateAvailable(let v, let u) = e, model.storage.latestVersion != v {   // remember it across launches
            var s = model.storage; s.latestVersion = v; s.latestURL = u; model.storage = s
            try? s.save(to: settingsURL)
        }
        if case .peerAddresses(let a) = e {   // the partner's other addresses become fallback hosts
            func merged(_ h: [String]?) -> [String] { var out: [String] = []; for x in (h ?? []) + a where !out.contains(x) { out.append(x) }; return Array(out.prefix(6)) }
            if var p = pending, p.connects { p.hosts = merged(p.hosts); pending = p }
            else if var c = config, c.connects, merged(c.hosts) != (c.hosts ?? []) { c.hosts = merged(c.hosts); save(c); config = c }
        }
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
        guard case .connected(let name) = e else { return }
        if var p = pending {          // a pairing just worked: keep it
            pending = nil
            pairTimeout?.cancel()
            p.peer = name
            save(p)
            config = p
            model.pairing = false
            model.pairBusy = false
            if !p.connects {   // advertise the pair id of the new long-term secret
                responder?.close()
                responder = try? DiscoveryResponder(port: p.port, name: options.name, pairID: PairCode.pairID(token: p.token), queue: .main)
            }
        } else if var c = config, c.peer != name {
            c.peer = name
            save(c)
            config = c
        }
    }

    private func save(_ c: LanLineConfig) {
        do { try c.save(to: options.configURL) } catch { model.note("Couldn't save the pairing: \(error.localizedDescription)") }
    }

    private func stopAll() {
        model.session?.stop(); model.session = nil
        responder?.close(); responder = nil
        pairTimeout?.cancel(); pairTimeout = nil
        rediscover?.invalidate(); rediscover = nil
        model.connected = false
    }

    private func beginPairing(_ mode: PairMode) {
        stopAll()
        pending = nil
        model.pairing = true
        model.pairMode = mode
        model.pairError = nil
        model.pairBusy = false
        model.canCancelPairing = config != nil
        model.peer = ""
        growPanel(to: 430)   // the pairing screen needs a little more room than the feed
        switch mode {
        case .show:
            let code = PairCode.generate()
            model.pairCode = code
            model.myAddresses = Discovery.localAddresses()
            let cfg = LanLineConfig(port: port, token: code, role: "listen")
            pending = cfg
            startSession(cfg, pairing: true)
            do { responder = try DiscoveryResponder(port: port, name: options.name, pairID: PairCode.pairID(token: code), queue: .main) }
            catch { model.pairError = "Other computers can't find this one automatically; type its address there." }
        case .enter:
            search()
        }
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
        stopAll()
        model.pairError = nil
        model.pairBusy = true
        let cfg = LanLineConfig(port: port, token: code, hosts: [host], role: "connect")
        pending = cfg
        startSession(cfg)
        let t = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending != nil else { return }
                self.stopAll()
                self.pending = nil
                self.model.pairBusy = false
                self.model.pairError = "Couldn't pair. Check the code, and that Lan-Line is open on \(host)."
            }
        }
        pairTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: t)
    }

    private func findMovedPartner() {
        guard let c = config, c.connects, !model.connected, !model.pairing else { return }
        let want = PairCode.pairID(token: c.token)
        Discovery.search(port: c.port, queue: .main) { [weak self] peers in
            MainActor.assumeIsolated {
                guard let self, let p = peers.first(where: { $0.pairID == want }), !(c.hosts ?? []).contains(p.host) else { return }
                var n = c
                n.hosts = Array(([p.host] + (c.hosts ?? [])).prefix(4))
                self.save(n)
                self.run(n)
            }
        }
    }

    static func findInput(in v: NSView) -> InputTextView? {
        if let t = v as? InputTextView { return t }
        for sub in v.subviews { if let t = findInput(in: sub) { return t } }
        return nil
    }

    @objc private func pairFromMenu() { showPanel(activate: true); beginPairing(.show) }

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
            let fx = NSVisualEffectView()
            fx.material = .underWindowBackground
            fx.blendingMode = .behindWindow
            fx.state = .active          // stay glassy while another app is in front (the panel floats)
            host.frame = fx.bounds
            host.autoresizingMask = [.width, .height]
            fx.addSubview(host)
            p.contentView = fx
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
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
    }

    func showPanel(activate: Bool) {
        popUp()
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)   // closing hides; the Dock icon or a new item brings it back; ⌘Q quits
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
