import Combine
import AppKit
import ServiceManagement
@preconcurrency import Quartz
import SwiftUI
import LanLineCore

/// Owns the panel and the one Session. Everything here runs on the main thread.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: Options
    let model = AppModel()
    var panel: NSPanel!
    private var menuBar: MenuBarItem!
    private let notifier = Notifier()
    private let sounds = Sounds()
    private lazy var clipShare = ClipboardShare(model: model)
    private lazy var previewSource = PreviewSource(model: model)
    private var keyMonitor: Any?
    private var hotKeys: HotKeys?
    private var badgeWatch: AnyCancellable?
    private let dockProgress = DockProgress()
    private var progressWatch: AnyCancellable?
    /// Opened by the system at login (or `--background`): wait in the menu bar instead of showing the window.
    private lazy var launchedInBackground: Bool = {
        if options.flag("--background") { return true }
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == AEEventID(kAEOpenApplication) else { return false }
        return e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == 0x6C67_6974   // 'lgit', keyAELaunchedAsLoginItem
    }()

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ n: Notification) {
        switch options.value("--appearance") {   // for screenshots; normally the system setting decides
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        DebugLog.path = options.value("--debug-log")
        watchDisplayOptions()
        if let v = options.value("--text-scale").flatMap(Double.init) { applyTextScale(StorageSettings.snapTextScale(v)) }   // demos don't load settings
        _ = launchedInBackground   // read the open event before anything else handles it
        buildMenu()
        menuBar = MenuBarItem(model: model, actions: .init(
            show: { [weak self] in self?.showPanel(activate: true) },
            pair: { [weak self] in self?.pairFromMenu() },
            settings: { [weak self] in self?.settingsFromMenu() },
            checkUpdates: { [weak self] in self?.checkFromMenu() },
            dropped: { [weak self] urls, text in self?.sendDropped(urls, text: text) ?? false }))
        model.glass = options.value("--snapshot") == nil && !options.flag("--no-glass")
        model.liquid = !options.flag("--no-liquid")
        buildPanel()
        setUpNotifier()
        model.onSent = { [weak self] in guard let self else { return }; sounds.sentTick(soundsOn: model.storage.soundsValue) }
        if let m = options.value("--demo-settings") { Demo.settings(model, firstRun: m == "first") }
        else if let m = options.value("--demo-pair") { Demo.pair(model, mode: m) }
        else if options.flag("--demo-multi") { Demo.multi(model) }
        else if options.flag("--demo-transfers") { Demo.transfers(model) }
        else if options.flag("--demo-smart") { Demo.smart(model) }
        else if options.flag("--demo") { Demo.fill(model, empty: options.flag("--empty")) } else { boot(); model.animateArrivals = true }
        if let id = options.value("--demo-select") { model.selectedID = id }
        if let q = options.value("--demo-search") {   // screenshots: "QUERY" or "QUERY|filter"
            let parts = q.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            model.searchOpen = true; model.query = parts[0]
            if parts.count > 1, let f = HistoryFilter(rawValue: parts[1]) { model.filter = f }
        }   // screenshots of a selected card
        if let v = options.value("--glass-opacity").flatMap(Double.init) {   // screenshots of the opacity setting
            model.storage.glassOpacity = StorageSettings.clampOpacity(v)
            model.glassOpacity = model.storage.glassOpacityValue
        }
        if let out = options.value("--snapshot") { snapshot(to: out) }
        else if let out = options.value("--live-shot") { liveShot(to: out) }
        else { applyKeepRunning(); startQuietIfLoggingIn(); applyHotKeys() }
        if !openedEarly.isEmpty {   // what started the app (see application(_:open:))
            let early = openedEarly
            openedEarly = []
            application(NSApp, open: early)
        }
        if options.flag("--demo-shortcuts") { model.showingShortcuts = true }
        if let n = options.value("--demo-tour").flatMap(Int.init) { model.tourPage = n; model.showingTour = true }   // screenshots of a tour card
        badgeWatch = model.$unread.removeDuplicates().sink { u in NSApp.dockTile.badgeLabel = u.badge }
        progressWatch = model.$overallProgress.removeDuplicates().sink { [weak self] v in self?.dockProgress.set(v) }
        refreshLoginItem()
        // Checks of the close / reopen path (beta.9): close the window after S seconds, show it again after T.
        if let s = options.value("--test-close-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in self?.panel.performClose(nil) }
        }
        if let s = options.value("--test-reopen-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in self?.showPanel(activate: true) }
        }
    }

    // MARK: open at login (beta.10)

    /// At login, a paired Lan-Line with "Keep running in the menu bar" on waits there; the window comes up when
    /// something arrives or from the menu. Unpaired, or settings never saved: show the window as usual.
    private func startQuietIfLoggingIn() {
        guard launchedInBackground else { return }
        guard model.storage.keepRunningWhenClosedValue, model.storage.confirmed, !device.peers.isEmpty, menuBar.isShown else {
            showPanel(activate: true); return
        }
        DebugLog.write("opened at login: waiting in the menu bar")
    }

    private func refreshLoginItem() {
        let s = SMAppService.mainApp.status
        model.openAtLogin = s == .enabled || s == .requiresApproval
        model.loginNeedsApproval = s == .requiresApproval
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.note("Couldn't \(on ? "add Lan-Line to" : "remove Lan-Line from") Login Items: \(error.localizedDescription)")
        }
        refreshLoginItem()
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

    /// `--live-shot PATH [--backdrop white|black|photo] [--snapshot-size WxH]`: design checks of the real glass
    /// (design refresh, beta.10), which off-screen snapshots can't render. Shows the window once, without taking
    /// focus, over a backdrop this process draws itself (so the capture never contains the user's desktop and the
    /// worst-case wallpapers are repeatable), captures that screen region, and quits about 2 s after launch. No Dock
    /// icon, menu bar icon, hot keys or network: use it with a `--demo-…` flag.
    private var backdropWindow: NSWindow?
    private func liveShot(to path: String) {
        NSApp.setActivationPolicy(.accessory)
        var size = NSSize(width: 380, height: 560)
        if let sz = options.value("--snapshot-size")?.split(separator: "x"), sz.count == 2, let w = Double(sz[0]), let h = Double(sz[1]) {
            size = NSSize(width: w, height: h)
        }
        guard let screen = NSScreen.main else { exit(1) }
        let margin: CGFloat = 36
        let vf = screen.visibleFrame
        let back = NSRect(x: vf.maxX - size.width - margin * 2 - 20, y: vf.maxY - size.height - margin * 2 - 20,
                          width: size.width + margin * 2, height: size.height + margin * 2)
        let bw = NSWindow(contentRect: back, styleMask: [.borderless], backing: .buffered, defer: false)
        bw.isOpaque = true
        bw.level = .floating
        bw.ignoresMouseEvents = true
        bw.contentView = BackdropView(kind: options.value("--backdrop") ?? "photo")
        bw.orderFrontRegardless()
        backdropWindow = bw
        panel.level = .floating
        panel.setFrame(back.insetBy(dx: margin, dy: margin), display: true)
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: bw.windowNumber)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            // screencapture wants top-left-origin points on the main display
            let top = screen.frame.maxY - back.maxY
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "\(Int(back.minX - screen.frame.minX)),\(Int(top)),\(Int(back.width)),\(Int(back.height))", path]
            try? p.run(); p.waitUntilExit()
            exit(p.terminationStatus)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel(activate: true)
        return true
    }

    func applicationWillTerminate(_ n: Notification) { stopAll() }

    /// `lanline://stage?p=<path>&t=<text>`: from the Share extension (or `open lanline://…`). Stages, never sends.
    /// Files and links that arrived before the window existed: a drop on the Dock icon (or "Open With") that
    /// *starts* Lan-Line reaches `application(_:open:)` before `applicationDidFinishLaunching`.
    private var openedEarly: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard panel != nil else { openedEarly += urls; return }   // handled once launch has finished
        // Files dropped on the Dock icon, or "Open With → Lan-Line" in Finder (beta.10): send them.
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { sendDropped(files, text: nil) }
        for u in urls where !u.isFileURL {
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
        // Welcome tour (beta.10): someone already paired before it existed isn't owed one.
        let seen = Tour.seenAtLaunch(saved: model.storage.tourSeen, alreadyPaired: !device.peers.isEmpty)
        if seen != model.storage.tourSeen { model.storage.tourSeen = seen; try? model.storage.save(to: settingsURL) }
        model.tourActions = TourActions(done: { [weak self] in self?.finishTour() })
        model.glassOpacity = model.storage.glassOpacityValue
        applyTextScale(options.value("--text-scale").flatMap(Double.init).map(StorageSettings.snapTextScale) ?? model.storage.textScaleValue)
        model.settingsActions = SettingsActions(
            save: { [weak self] s in self?.saveSettings(s) },
            cleanNow: { [weak self] in self?.runCleanup(manual: true) },
            openFolder: { [weak self] in
                guard let self else { return }
                let dir = self.downloadsDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            },
            cancel: { [weak self] in
                guard let self else { return }
                self.model.glassOpacity = self.model.storage.glassOpacityValue   // undo a slider preview
                self.model.showingSettings = false; self.restoreAfterSettings()
            })
        model.settingsActions.setOpenAtLogin = { [weak self] on in self?.setOpenAtLogin(on) }
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
        notifier.refreshAuthorization()
        refreshLoginItem()
        if panel.frame.height < 470 { frameBeforeSettings = panel.frame }
        growPanel(to: 470)
    }

    /// The welcome tour (beta.10): once, on a new install, when a computer is paired and the first-run settings are saved.
    private func maybeShowTour() {
        guard Tour.shouldShow(seen: model.storage.tourSeen, paired: !device.peers.isEmpty, settingsConfirmed: model.storage.confirmed),
              !model.pairing, !model.showingSettings, !model.showingTour else { return }
        model.tourPage = 0
        model.showingTour = true
    }

    private func finishTour() {
        model.showingTour = false
        guard model.storage.tourSeen != true else { return }
        model.storage.tourSeen = true
        try? model.storage.save(to: settingsURL)
    }

    @objc func tourFromMenu() { showPanel(activate: true); model.showingSettings = false; model.tourPage = 0; model.showingTour = true }

    /// Accessibility pass (beta.10): the text size, and macOS's Increase contrast, which can change while running.
    private func applyTextScale(_ v: Double) {
        A11y.textScale = CGFloat(v)
        if model.textScale != v { model.textScale = v }
    }

    private var displayOptionsWatch: NSObjectProtocol?
    private func watchDisplayOptions() {
        A11y.forcedContrast = options.flag("--increase-contrast")
        A11y.refresh()
        displayOptionsWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let was = A11y.increaseContrast
                A11y.refresh()
                if was != A11y.increaseContrast { self?.model.a11yTick += 1 }
            }
        }
    }

    private func saveSettings(_ s: StorageSettings) {
        var n = s
        n.lastTrashReminder = model.storage.lastTrashReminder
        n.lastLimitWarning = model.storage.lastLimitWarning
        n.lastUpdateCheck = model.storage.lastUpdateCheck
        n.latestVersion = model.storage.latestVersion; n.latestURL = model.storage.latestURL
        model.storage = n
        model.glassOpacity = n.glassOpacityValue
        applyTextScale(n.textScaleValue)
        do { try n.save(to: settingsURL) } catch { model.note("Couldn't save settings: \(error.localizedDescription)") }
        model.showingSettings = false
        model.settingsFirstRun = false
        restoreAfterSettings()
        maybeShowTour()   // a new install: pairing and these settings are done, so say hello
        runCleanup(manual: false)
        applyKeepRunning()
        applyHotKeys()
        applyHistory()
        clipShare.apply()
        applyDownloads()
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
        let dir = downloadsDir
        let managed = Set(existing.map(\.path))
        // Only a folder Lan-Line owns is counted: a chosen folder like the Desktop holds plenty of other files.
        guard options.value("--downloads") != nil || model.storage.downloadFolderURL == nil else {
            model.unmanagedCount = 0; model.unmanagedBytes = 0; return
        }
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
        applyHistory()
        clipShare.apply()
        applyDownloads()
        model.settingsActions.clearHistory = { [weak self] in self?.model.clearHistory() }
    }

    /// "Keep history" (beta.10): on → load `history.jsonl` into the feed; turned off → forget it, file and all.
    private func applyHistory() {
        let url = settingsURL.deletingLastPathComponent().appendingPathComponent(History.fileName)
        if model.storage.keepHistoryValue {
            guard model.historyURL == nil else { return }
            model.historyURL = url
            model.loadHistory()
        } else if model.historyURL != nil || FileManager.default.fileExists(atPath: url.path) {
            model.historyURL = url
            model.clearHistory()
            model.historyURL = nil
        }
    }

    /// Saved partners plus the pairing in progress; every Hub event goes through it (PairingBook).
    private var book = PairingBook(config: DeviceConfig())
    private var device: DeviceConfig { book.config }

    /// Where received files go: `--downloads` (tests), the folder chosen in Settings, or Downloads/Lan-Line.
    private var downloadsDir: URL {
        options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? model.storage.downloadFolderURL ?? LanLineConfig.downloadsDir
    }

    /// The folder settings (beta.10): one folder, or one per computer inside it; applied to every partner.
    private func applyDownloads() {
        model.hub?.setDownloads(base: downloadsDir, perComputer: model.storage.folderPerComputerValue)
    }

    private var burst = ArrivalBurst()

    /// "When a file arrives" (beta.10): show it, or open it if it's a kind that can't run anything.
    private func afterReceive(_ item: Item) {
        let setting = model.storage.afterReceiveValue
        guard setting != .nothing else { return }
        let (name, url, isFolder): (String, URL, Bool)
        switch item.kind {
        case .file(let n, _, let u): (name, url, isFolder) = (n, u, false)
        case .folder(let n, _, _, let u): (name, url, isFolder) = (n, u, true)
        case .text: return
        }
        switch burst.next(setting, name: name, isFolder: isFolder) {   // at most 3 opened and the folder shown once per burst of arrivals
        case .open: NSWorkspace.shared.open(url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .nothing: break
        }
    }

    /// One Hub for all partners: it listens for those that dial us, dials those we dial, and answers discovery.
    private func startHub() {
        var hc = HubConfig(name: options.name, deviceID: device.deviceID, downloadDir: downloadsDir)
        hc.port = port
        hc.appVersion = options.value("--app-version") ?? AppInfo.version
        hc.latestKnown = savedLatest()
        hc.advertise = Discovery.localAddresses()
        let outbox = options.configURL.deletingLastPathComponent().appendingPathComponent("outbox.json")   // beta.11
        hc.outboxURL = outbox
        Pasted.dir = options.configURL.deletingLastPathComponent().appendingPathComponent("Pasted", isDirectory: true)
        Hub.sweepUnsent(Pasted.dir, outbox: outbox, olderThan: 7 * 86_400)   // the feed's thumbnails use these too
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
        if case .clipboard(_, let c) = e { clipShare.received(c) }
        if case .received(_, let item) = e { afterReceive(item) }
        if case .received = e {
            model.unread.arrived(inUse: inUse)
            sounds.arrived(soundsOn: model.storage.soundsValue, notificationShown: shouldNotify && model.notificationsAllowed)
        }
        switch e {   // notify before the window pops up: "in use" means the user had Lan-Line in front
        case .received(let p, let item) where shouldNotify: notifier.arrived(from: model.name(p), item)
        case .receiveFailed(let p, let n, let r, _) where shouldNotify: notifier.failed(from: model.name(p), name: n, reason: r)
        default: break
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
            model.pairPort = port
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
        maybeShowTour()
        if model.multi { model.note("Paired with \(p.name). Send goes to everyone; pick one computer next to Send.", fadeAfter: 10) }
    }

    private func search() {
        model.searching = true   // the pairing screen's network search (not the history search bar)
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
        model.hub?.setName(partner: id, String(n.prefix(64)))   // a folder per computer follows the new name
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
        let p = LanLinePanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
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
        p.previewSource = previewSource
        model.onSelect = { [weak self] in self?.panel.makeFirstResponder(nil) }   // keys come to the feed: Space previews
        model.onQuickLook = { [weak self] in self?.toggleQuickLook(forceOpen: true) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let ev = e   // local monitors run on the main thread
            let consumed = MainActor.assumeIsolated { self?.feedKeyConsumes(ev) ?? false }
            return consumed ? nil : e
        }
        model.onPopUp = { [weak self] in if self?.model.storage.popUpOnArrivalValue ?? true { self?.popUp() } }
        panel = p
        applyPin()
        if !p.setFrameUsingName("LanLinePanel") { p.center() }
        p.setFrameAutosaveName("LanLinePanel")
        if options.value("--live-shot") != nil {
            // shown by liveShot(), without taking focus
        } else if options.value("--snapshot") == nil {
            if !launchedInBackground {
                p.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
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

    // MARK: keyboard (beta.10)

    /// Register the global shortcuts from Settings; problems are shown there.
    private func applyHotKeys() {
        if hotKeys == nil {
            hotKeys = HotKeys()
            NotificationCenter.default.addObserver(forName: .lanLineRecordingShortcut, object: nil, queue: .main) { [weak self] n in
                let on = (n.userInfo?["on"] as? Bool) ?? false
                MainActor.assumeIsolated {
                    if on { self?.hotKeys?.set(.show, nil) {}; self?.hotKeys?.set(.send, nil) {} } else { self?.applyHotKeys() }
                }
            }
        }
        guard let hk = hotKeys else { return }
        var problems: [String: String] = [:]
        if let p = hk.set(.show, model.storage.showShortcut, action: { [weak self] in self?.toggleWindow() }) { problems["show"] = p }
        if let p = hk.set(.send, model.storage.sendShortcut, action: { [weak self] in self?.sendClipboard() }) { problems["send"] = p }
        model.hotKeyProblems = problems
        buildMenu()   // the File menu shows the current combinations
    }

    /// The show/hide shortcut: in front → hide (to the menu bar while "Keep running" is on); otherwise show and focus.
    @objc func toggleWindow() {
        if panel.isVisible, NSApp.isActive, panel.isKeyWindow {
            panel.orderOut(nil)
            if model.storage.keepRunningWhenClosedValue, menuBar.isShown { NSApp.setActivationPolicy(.accessory) } else { NSApp.hide(nil) }
            return
        }
        showPanel(activate: true)
        focusComposer()
    }

    /// The send-the-clipboard shortcut: files, a picture or text, to the current target, without opening the
    /// window. A notification says what went where (an empty clipboard just beeps).
    @objc func sendClipboard() {
        let pb = NSPasteboard.general
        let to = model.targetLabel == "Everyone" ? (model.multi ? "everyone" : model.peerLabel) : model.targetLabel
        guard model.hub != nil, !model.partners.isEmpty else { NSSound.beep(); model.note("Not paired yet: nothing was sent"); return }
        guard !model.pairing else { NSSound.beep(); showPanel(activate: true); return }   // mid-pairing: nothing goes out behind the pairing screen
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.sendFiles(urls)
            notifier.confirm(title: "Sent to \(to)", body: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
        } else if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            model.sendImage(png)
            notifier.confirm(title: "Sent to \(to)", body: "A picture from the clipboard")
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard model.sendText(s, includeStaged: false) else { NSSound.beep(); return }   // only the clipboard: staged items wait for Send
            notifier.confirm(title: "Sent to \(to)", body: ArrivalNotices.preview(s))
        } else {
            NSSound.beep()
        }
    }

    /// Dropped on the menu bar or Dock icon (beta.10): send to the current target without opening the window, and
    /// say where it went.
    /// Returns whether anything went out (the menu bar icon only shows its "Sent" tick then).
    @discardableResult
    func sendDropped(_ urls: [URL], text: String?) -> Bool {
        guard model.hub != nil, !model.partners.isEmpty, !model.pairing else { NSSound.beep(); showPanel(activate: true); return false }
        let to = model.targetLabel == "Everyone" ? (model.multi ? "everyone" : model.peerLabel) : model.targetLabel
        if !urls.isEmpty {
            model.sendFiles(urls)
            notifier.confirm(title: "Sent to \(to)", body: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
            return true
        } else if let t = text, model.sendText(t, includeStaged: false) {   // only what was dropped: staged items wait for Send
            notifier.confirm(title: "Sent to \(to)", body: ArrivalNotices.preview(t))
            return true
        }
        return false
    }

    @objc func sendFilesFromMenu() {
        showPanel(activate: true)
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Send"; p.message = "Choose files or folders to send to \(model.targetLabel == "Everyone" && !model.multi ? model.peerLabel : model.targetLabel)"
        p.beginSheetModal(for: panel) { [weak self] r in
            guard r == .OK else { return }
            MainActor.assumeIsolated { self?.model.sendFiles(p.urls) }
        }
    }

    @objc func findFromMenu() {
        showPanel(activate: true)
        model.selectedID = nil
        if model.showingSettings || model.pairing { return }
        model.searchOpen = true   // ⌘F: the history search bar
    }

    @objc func focusComposer() {
        model.selectedID = nil
        if let tv = panel.contentView.flatMap({ Self.findInput(in: $0) }) { panel.makeFirstResponder(tv) }
    }

    @objc func selectNewestFromMenu() { if model.selectNewest() { panel.makeFirstResponder(nil) } else { NSSound.beep() } }
    @objc func shortcutsFromMenu() { showPanel(activate: true); model.showingShortcuts.toggle() }

    private func copyItem(_ id: String) {
        if let t = model.itemText(id) { Clip.copy(text: t) } else if let u = model.itemURL(id) { Clip.copy(file: u) }
    }

    private func openItem(_ id: String) {
        guard let u = model.itemURL(id), FileManager.default.fileExists(atPath: u.path) else { NSSound.beep(); return }
        NSWorkspace.shared.open(u)
    }

    // MARK: Quick Look (beta.10)

    private var quickLookOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggleQuickLook(forceOpen: Bool = false) {
        if quickLookOpen && !forceOpen { QLPreviewPanel.shared().orderOut(nil); return }
        previewSource.refresh()
        guard previewSource.hasSelection else { return }
        let ql = QLPreviewPanel.shared()!
        if !panel.isKeyWindow { showPanel(activate: true) }
        panel.makeFirstResponder(nil)
        ql.level = max(panel.level, .floating) + 1   // above the pinned window
        if ql.isVisible { ql.reloadData(); ql.updateController() } else { ql.makeKeyAndOrderFront(nil) }
    }

    /// Keys while a file card is selected: Space = Quick Look, Esc = deselect; anything else goes back to the
    /// message box (and is typed there). The message box keeps every key while it has the cursor.
    private func feedKeyConsumes(_ e: NSEvent) -> Bool {
        if model.showingShortcuts, panel.isKeyWindow, e.keyCode == 53 { model.showingShortcuts = false; return true }   // Esc
        guard let sel = model.selectedID else { return false }
        let inQL = quickLookOpen && QLPreviewPanel.shared().isKeyWindow
        guard panel.isKeyWindow || inQL else { return false }
        if !inQL, panel.firstResponder is NSTextView { model.selectedID = nil; return false }   // the user clicked back into the box
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (Int(e.keyCode), mods) {
        case (49, []):                                                                   // Space
            if model.itemURL(sel) != nil { toggleQuickLook() } else { NSSound.beep() }
            return true
        case (53, _):                                                                    // Esc
            if inQL { QLPreviewPanel.shared().orderOut(nil) } else { focusComposer() }
            return true
        case (126, []) where !inQL: model.selectRelative(-1); return true               // ↑
        case (125, []) where !inQL: if !model.selectRelative(1) { focusComposer() }; return true   // ↓ (past the newest: back to the box)
        case (36, []) where !inQL, (76, []) where !inQL: openItem(sel); return true     // Return, keypad Enter
        case (8, [.command]): copyItem(sel); return true                                 // ⌘C
        case (15, [.command, .shift]):                                                   // ⌘⇧R
            if let u = model.itemURL(sel), FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSSound.beep() }
            return true
        case (51, []) where !inQL, (117, []) where !inQL:                                // ⌫ ⌦
            if let item = model.visibleRows.first(where: { $0.id == sel })?.item, model.canCancel(item) { model.cancel(sel) } else { model.removeFromList(sel) }
            return true
        default:
            if inQL || !(mods.isEmpty || mods == [.shift]) { return false }
            focusComposer()   // typing goes back to the message box, and lands there
            return false
        }
    }

    // MARK: notifications (beta.10)

    /// Notify only while Lan-Line isn't the window in use (Messages does the same).
    private var inUse: Bool { NSApp.isActive && panel.isVisible && !panel.isMiniaturized }
    private var shouldNotify: Bool { model.storage.notifyOnArrivalValue && !inUse }

    func windowDidBecomeKey(_ notification: Notification) { model.unread.seen() }

    private func setUpNotifier() {
        notifier.handlers = .init(
            show: { [weak self] id in
                self?.showPanel(activate: true)
                if let id { self?.model.highlight(id) }
            },
            copy: { [weak self] id, posted in
                guard let full = self?.model.itemText(id) ?? posted else { return }
                let t = SmartText.analyze(full).otp ?? full   // a one-time code: just the code (beta.10)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            },
            open: { [weak self] id in
                guard let self else { return }
                guard let u = model.itemURL(id), FileManager.default.fileExists(atPath: u.path) else { return missing(id) }
                NSWorkspace.shared.open(u)
            },
            reveal: { [weak self] id in
                guard let self else { return }
                guard let u = model.itemURL(id), FileManager.default.fileExists(atPath: u.path) else { return missing(id) }
                NSWorkspace.shared.activateFileViewerSelecting([u])
            },
            authorization: { [weak self] ok in self?.model.notificationsAllowed = ok })
        if options.value("--snapshot") == nil, options.value("--live-shot") == nil, !options.flag("--demo"), !options.flag("--demo-multi"), options.value("--demo-pair") == nil,
           options.value("--demo-settings") == nil, model.storage.notifyOnArrivalValue || options.value("--test-notify") != nil {
            notifier.requestPermission()
        }
        if let kind = options.value("--test-notify") { testNotify(kind) }
    }

    private func missing(_ id: String) {
        showPanel(activate: true)
        model.highlight(id)
        model.note("That item is no longer in the Lan-Line folder.", fadeAfter: 6)
    }

    /// `--test-notify text|file|picture|burst|failed`: post a sample notification after 2 s (checks and screenshots).
    private func testNotify(_ kind: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-demo")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let png = dir.appendingPathComponent("hero-export.png")
            if !FileManager.default.fileExists(atPath: png.path), let icon = NSApp.applicationIconImage?.tiffRepresentation,
               let rep = NSBitmapImageRep(data: icon), let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: png) }
            let pdf = dir.appendingPathComponent("Q4 plan.pdf")
            if !FileManager.default.fileExists(atPath: pdf.path) { FileManager.default.createFile(atPath: pdf.path, contents: Data(count: 412_000)) }
            let text = Item(id: "test-text", kind: .text("Meeting moved to 3:30. Bring the Q4 deck and the new icons, please."), incoming: true, state: .received)
            let file = Item(id: "test-file", kind: .file(name: "Q4 plan.pdf", size: 412_000, url: pdf), incoming: true, state: .received)
            let pic = Item(id: "test-pic", kind: .file(name: "hero-export.png", size: 2_400_000, url: png), incoming: true, state: .received)
            for i in [text, file, pic] { model.upsert(i) }
            switch kind {
            case "text": notifier.arrived(from: "Studio PC", text)
            case "file": notifier.arrived(from: "Studio PC", file)
            case "picture": notifier.arrived(from: "Studio PC", pic)
            case "failed": notifier.failed(from: "Studio PC", name: "big.zip", reason: "not enough disk space")
            default: for i in [file, pic, text] { notifier.arrived(from: "Studio PC", i) }
            }
        }
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
        // File (beta.10): sending without the mouse
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Send Files…", action: #selector(sendFilesFromMenu), keyEquivalent: "o")
        let clip = NSMenuItem(title: "Send Clipboard", action: #selector(sendClipboard), keyEquivalent: "")
        if let s = model.storage.sendShortcut { Self.setKey(clip, s) }
        file.addItem(clip)
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(findFromMenu), keyEquivalent: "f")
        editItem.submenu = edit
        // Go (beta.10): between the message box and the items
        let goItem = NSMenuItem(); main.addItem(goItem)
        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Message Box", action: #selector(focusComposer), keyEquivalent: "l")
        let newest = NSMenuItem(title: "Newest Item", action: #selector(selectNewestFromMenu), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        go.addItem(newest)
        goItem.submenu = go
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Show Lan-Line", action: #selector(showFromMenu), keyEquivalent: "0")
        win.addItem(withTitle: "Keep on Top", action: #selector(togglePinFromMenu), keyEquivalent: "p")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        if let s = model.storage.showShortcut {
            let toggle = NSMenuItem(title: "Show or Hide Lan-Line", action: #selector(toggleWindow), keyEquivalent: "")
            Self.setKey(toggle, s)
            win.insertItem(toggle, at: 1)
        }
        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Keyboard Shortcuts", action: #selector(shortcutsFromMenu), keyEquivalent: "/")
        help.addItem(withTitle: "Welcome Tour", action: #selector(tourFromMenu), keyEquivalent: "")
        helpItem.submenu = help
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
        NSApp.helpMenu = help
    }

    @objc private func showFromMenu() { showPanel(activate: true) }

    /// Show a global shortcut beside its menu item (it works there too, while Lan-Line is in front).
    private static func setKey(_ item: NSMenuItem, _ s: Shortcut) {
        if s.key == "Space" { item.keyEquivalent = " " }
        else if s.key.hasPrefix("F"), s.key.count > 1, let n = Int(s.key.dropFirst()) { item.keyEquivalent = String(UnicodeScalar(NSF1FunctionKey + n - 1)!) }
        else { item.keyEquivalent = s.key.lowercased() }
        var m: NSEvent.ModifierFlags = []
        if s.ctrl { m.insert(.control) }; if s.alt { m.insert(.option) }; if s.shift { m.insert(.shift) }; if s.cmd { m.insert(.command) }
        item.keyEquivalentModifierMask = m
    }
    @objc private func togglePinFromMenu() { model.togglePin() }
}

/// The drawn "wallpaper" behind a `--live-shot`: white and black are the worst cases for dark and light glass, and
/// "photo" is a busy, high-contrast, colourful pattern standing in for a picture.
final class BackdropView: NSView {
    let kind: String
    init(kind: String) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        switch kind {
        case "white": NSColor.white.setFill(); bounds.fill()
        case "black": NSColor.black.setFill(); bounds.fill()
        default:
            NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1), NSColor(red: 0.85, green: 0.20, blue: 0.55, alpha: 1),
                                NSColor(red: 0.20, green: 0.35, blue: 0.90, alpha: 1)])?.draw(in: bounds, angle: 55)
            // hard-edged light and dark shapes, like windows and text behind the panel
            let shapes: [(NSRect, NSColor)] = [
                (NSRect(x: 30, y: bounds.height - 150, width: 190, height: 110), .white),
                (NSRect(x: bounds.width - 210, y: bounds.height - 330, width: 170, height: 150), NSColor(white: 0.06, alpha: 1)),
                (NSRect(x: 60, y: bounds.height - 420, width: 150, height: 120), NSColor(red: 0.99, green: 0.92, blue: 0.25, alpha: 1)),
                (NSRect(x: bounds.width - 260, y: 70, width: 210, height: 130), .white),
                (NSRect(x: 40, y: 40, width: 160, height: 100), NSColor(red: 0.10, green: 0.75, blue: 0.55, alpha: 1)),
            ]
            for (rect, c) in shapes { c.setFill(); NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill() }
            let para = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
            (para as NSString).draw(in: bounds.insetBy(dx: 14, dy: 14), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.75)])
        }
    }
}
