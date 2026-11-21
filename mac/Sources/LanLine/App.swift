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
        if let m = options.value("--demo-pair") { Demo.pair(model, mode: m) }
        else if options.flag("--demo") { Demo.fill(model, empty: options.flag("--empty")) } else { boot() }
        if let out = options.value("--snapshot") { snapshot(to: out) }
    }

    /// `--snapshot PATH`: render the window (off-screen) to a PNG and quit. For design checks in both themes.
    private func snapshot(to path: String) {
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

    private func boot() {
        model.myName = options.name
        model.pairActions = PairActions(
            switchMode: { [weak self] m in self?.beginPairing(m) },
            search: { [weak self] in self?.search() },
            connect: { [weak self] in self?.tryConnect() },
            cancel: { [weak self] in if let c = self?.config { self?.run(c) } })
        if let c = try? LanLineConfig.load(from: options.configURL) { run(c) }
        else if options.value("--connect") != nil { run(options.loadConfig()) }   // flags win; loadConfig explains a bad path
        else { beginPairing(.show) }
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

    private func startSession(_ cfg: LanLineConfig) {
        let sc = SessionConfig(token: cfg.token, name: options.name,
                               downloadDir: options.value("--downloads").map { URL(fileURLWithPath: $0) } ?? LanLineConfig.downloadsDir)
        // The one main-thread hop: the Session calls this on its own queue.
        let s = Session(role: options.role(cfg), config: sc) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.event(event) } }
        }
        model.session = s
        s.start()
    }

    private func event(_ e: SessionEvent) {
        model.handle(e)
        guard case .connected(let name) = e else { return }
        if var p = pending {          // a pairing just worked: keep it
            pending = nil
            pairTimeout?.cancel()
            p.peer = name
            save(p)
            config = p
            model.pairing = false
            model.pairBusy = false
            if !p.connects, responder == nil {
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
        if panel.frame.height < 430 {   // the pairing screen needs a little more room than the feed
            var f = panel.frame; f.origin.y -= 430 - f.height; f.size.height = 430; panel.setFrame(f, display: true, animate: true)
        }
        switch mode {
        case .show:
            let code = PairCode.generate()
            model.pairCode = code
            model.myAddresses = Discovery.localAddresses()
            let cfg = LanLineConfig(port: port, token: code, role: "listen")
            pending = cfg
            startSession(cfg)
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
            NSApp.activate()
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
        if activate { NSApp.activate(); panel.makeKeyAndOrderFront(nil) }
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
        appMenu.addItem(.separator())
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
