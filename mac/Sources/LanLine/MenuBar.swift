import AppKit
import Combine

/// The menu bar icon (beta.9). With "Keep running in the menu bar" on, closing the window leaves Lan-Line here
/// (out of the Dock) instead of in the Dock. A template image, so macOS draws it like the icons beside it in
/// light, dark and tinted menu bars: the app mark (two rounded squares) joined by a line while a computer is
/// connected, apart while none is. Click for the menu.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    struct Actions {
        var show: () -> Void
        var pair: () -> Void
        var settings: () -> Void
        var checkUpdates: () -> Void
    }

    private let model: AppModel
    private let actions: Actions
    private var item: NSStatusItem?
    private var watch: AnyCancellable?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
    }

    var isShown: Bool { item != nil }

    func show() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.setAccessibilityLabel("Lan-Line")
        it.behavior = .removalAllowed   // ⌘-drag it out of the menu bar hides it, like any other
        it.autosaveName = "Lan-Line"
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(entry("Show Lan-Line", #selector(showFromMenu)))
        menu.addItem(entry("Pair with Another Computer…", #selector(pairFromMenu)))
        menu.addItem(entry("Settings…", #selector(settingsFromMenu)))
        menu.addItem(entry("Check for Updates…", #selector(checkFromMenu)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lan-Line", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        it.menu = menu
        item = it
        watch = model.$connected.removeDuplicates().sink { [weak self] up in self?.draw(connected: up) }
        draw(connected: model.connected)
    }

    func hide() {
        watch = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func entry(_ title: String, _ sel: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        m.target = self
        return m
    }

    private func draw(connected: Bool) {
        guard let b = item?.button else { return }
        b.image = Self.icon(connected: connected)
        b.toolTip = "Lan-Line · \(model.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = model.statusLine
        item?.button?.toolTip = "Lan-Line · \(model.statusLine)"
    }

    @objc private func showFromMenu() { actions.show() }
    @objc private func pairFromMenu() { actions.pair() }
    @objc private func settingsFromMenu() { actions.settings() }
    @objc private func checkFromMenu() { actions.checkUpdates() }

    /// The mark, 31 × 18 pt: two 11 pt rounded squares 7 pt apart, as in the app icon (1.7 pt lines, like the SF Symbols beside it) and, while
    /// connected, the line and dot between them. Drawn, not a bitmap, so it is sharp at any scale.
    static func icon(connected: Bool) -> NSImage {
        let w: CGFloat = 31, h: CGFloat = 18, box: CGFloat = 11, lw: CGFloat = 1.7, rad: CGFloat = 3.1, dot: CGFloat = 1.8
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            NSColor.black.set()
            let y = (h - box) / 2, inset = lw / 2
            let l = NSRect(x: inset, y: y, width: box, height: box)
            let r = NSRect(x: w - inset - box, y: y, width: box, height: box)
            for b in [l, r] {
                let p = NSBezierPath(roundedRect: b, xRadius: rad, yRadius: rad)
                p.lineWidth = lw
                p.stroke()
            }
            if connected {
                let mid = h / 2, x0 = l.maxX + lw / 2, x1 = r.minX - lw / 2, cx = (x0 + x1) / 2
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x0, y: mid)); line.line(to: NSPoint(x: x1, y: mid))
                line.lineWidth = lw * 0.85
                line.stroke()
                NSBezierPath(ovalIn: NSRect(x: cx - dot, y: mid - dot, width: dot * 2, height: dot * 2)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = connected ? "Lan-Line, connected" : "Lan-Line, not connected"
        return img
    }
}
