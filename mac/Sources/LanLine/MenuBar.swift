import AppKit
import Combine
import LanLineCore

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
        /// Something was dropped on the icon (beta.10): files and folders, else text.
        var dropped: ([URL], String?) -> Bool = { _, _ in false }
    }

    private let model: AppModel
    private let actions: Actions
    private var item: NSStatusItem?
    private var watch: AnyCancellable?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// "Pause Clipboard Sharing" (beta.10), shown while sharing is on.
    private let clipItem = NSMenuItem(title: "Pause Clipboard Sharing", action: #selector(toggleClipPause), keyEquivalent: "")

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
        clipItem.target = self
        menu.addItem(clipItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lan-Line", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        it.menu = menu
        if let b = it.button {   // drop files, a picture or text on the icon to send it (beta.10)
            let drop = StatusDropView(frame: b.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onDrop = { [weak self] urls, text in if self?.actions.dropped(urls, text) == true { self?.flashSent() } }   // the tick only when it went out
            b.addSubview(drop)
        }
        item = it
        watch = model.$connected.combineLatest(model.$unread).removeDuplicates { $0 == $1 }
            .sink { [weak self] up, u in self?.draw(connected: up, unread: u) }
        draw(connected: model.connected, unread: model.unread)
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

    private func draw(connected: Bool, unread: Unread) {
        guard let b = item?.button else { return }
        b.image = Self.icon(connected: connected, unread: unread.count > 0)
        b.toolTip = tooltip(unread)
    }

    private func tooltip(_ u: Unread) -> String { ["Lan-Line", u.phrase, model.statusLine].compactMap { $0 }.joined(separator: " · ") }

    @objc private func toggleClipPause() { model.clipPaused.toggle() }

    /// A check mark for a moment after a drop, then the usual icon.
    private func flashSent() {
        guard let b = item?.button else { return }
        let check = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Sent")
        check?.isTemplate = true
        b.image = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.draw(connected: self.model.connected, unread: self.model.unread) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        clipItem.isHidden = !model.storage.shareClipboardValue
        clipItem.state = model.clipPaused ? .on : .off
        statusLine.title = [model.unread.phrase, model.statusLine].compactMap { $0 }.joined(separator: " · ")
        item?.button?.toolTip = tooltip(model.unread)
    }

    @objc private func showFromMenu() { actions.show() }
    @objc private func pairFromMenu() { actions.pair() }
    @objc private func settingsFromMenu() { actions.settings() }
    @objc private func checkFromMenu() { actions.checkUpdates() }

    /// The mark, 31 × 18 pt: two 11 pt rounded squares 7 pt apart, as in the app icon (1.7 pt lines, like the SF Symbols beside it) and, while
    /// connected, the line and dot between them. Drawn, not a bitmap, so it is sharp at any scale.
    /// `unread`: a dot at the top right, like the badges on the icons beside it, for items not seen yet (beta.10);
    /// the right square leaves a gap around it so it reads as a separate mark in a one-colour template image.
    static func icon(connected: Bool, unread: Bool = false) -> NSImage {
        let w: CGFloat = 31, h: CGFloat = 18, box: CGFloat = 11, lw: CGFloat = 1.7, rad: CGFloat = 3.1, dot: CGFloat = 1.8
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            NSColor.black.set()
            let y = (h - box) / 2, inset = lw / 2
            let l = NSRect(x: inset, y: y, width: box, height: box)
            let r = NSRect(x: w - inset - box, y: y, width: box, height: box)
            let badge = NSRect(x: w - 7.4, y: h - 7.4, width: 7.4, height: 7.4)
            for b in [l, r] {
                NSGraphicsContext.saveGraphicsState()
                if unread, b == r {   // cut a ring around the dot out of the square
                    let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h))
                    clip.append(NSBezierPath(ovalIn: badge.insetBy(dx: -1.6, dy: -1.6)).reversed)
                    clip.addClip()
                }
                let p = NSBezierPath(roundedRect: b, xRadius: rad, yRadius: rad)
                p.lineWidth = lw
                p.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            if unread { NSBezierPath(ovalIn: badge).fill() }
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
        img.accessibilityDescription = (connected ? "Lan-Line, connected" : "Lan-Line, not connected") + (unread ? ", new items" : "")
        return img
    }
}

/// Covers the menu bar button and takes drops (files, folders, pictures, text) without getting in the way of clicks:
/// a click goes on to the button, which opens the menu as before. The button lights up while something hovers.
final class StatusDropView: NSView {
    var onDrop: ([URL], String?) -> Void = { _, _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var button: NSButton? { superview as? NSButton }

    override func mouseDown(with event: NSEvent) { button?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { button?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        button?.highlight(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { button?.highlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { button?.highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let pb = sender.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { onDrop(urls, nil); return true }
        if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Lan-Line-pasted", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let u = dir.appendingPathComponent("dropped-\(f.string(from: Date())).png")
            if (try? png.write(to: u)) != nil { onDrop([u], nil); return true }
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onDrop([], s); return true }
        return false
    }
}
