import AppKit

/// A progress bar across the bottom of the Dock icon while files are moving (beta.10), like Finder's copies.
/// The badge (unread count) still draws on top: the Dock adds it after the tile's own view.
@MainActor
final class DockProgress {
    private let bar = Bar()
    private var shown = false

    func set(_ value: Double?) {
        let tile = NSApp.dockTile
        guard let v = value else {
            if shown { tile.contentView = nil; tile.display(); shown = false }
            return
        }
        if !shown {
            let view = NSImageView(image: NSApp.applicationIconImage)
            view.frame = NSRect(origin: .zero, size: tile.size)
            bar.frame = NSRect(x: tile.size.width * 0.12, y: tile.size.height * 0.1, width: tile.size.width * 0.76, height: tile.size.height * 0.1)
            view.addSubview(bar)
            tile.contentView = view
            shown = true
        }
        bar.value = min(max(v, 0), 1)
        bar.needsDisplay = true
        tile.display()
    }

    /// A rounded track with the system accent fill, readable on any wallpaper.
    private final class Bar: NSView {
        var value = 0.0
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.height / 2
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
            let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
            var fill = inner; fill.size.width = max(inner.height, inner.width * value)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
        }
    }
}
