import AppKit
@preconcurrency import Quartz
import QuickLookThumbnailing
import SwiftUI
import LanLineCore

/// The Lan-Line window. A panel that can drive Quick Look (beta.10): click a file card to select it, Space to
/// preview, the arrow keys to step through the other files, Space or Esc to close, as in Finder.
final class LanLinePanel: NSPanel {
    var previewSource: PreviewSource?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { MainActor.assumeIsolated { previewSource != nil } }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = previewSource
            panel.delegate = previewSource
            previewSource?.began(panel)
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewSource?.ended()
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

/// What Quick Look shows: every file and folder in the feed that is still on disk, starting at the selected one.
/// Keeps the feed's selection in step while the user pages through with the arrow keys.
@MainActor
final class PreviewSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let model: AppModel
    private var items: [(id: String, url: URL)] = []
    private var watch: NSKeyValueObservation?

    init(model: AppModel) { self.model = model }

    /// The files to page through, oldest first (the feed's order).
    func refresh() {
        items = model.visibleRows.compactMap { r in
            guard let item = r.item else { return nil }
            switch item.kind {
            case .file(_, _, let u), .folder(_, _, _, let u):
                guard !model.removedPaths.contains(u.path), FileManager.default.fileExists(atPath: u.path) else { return nil }
                return (item.id, u)
            case .text: return nil
            }
        }
    }

    var hasSelection: Bool { model.selectedID.map { id in items.contains { $0.id == id } } ?? false }

    func began(_ panel: QLPreviewPanel) {
        refresh()
        panel.reloadData()
        if let id = model.selectedID, let i = items.firstIndex(where: { $0.id == id }) { panel.currentPreviewItemIndex = i }
        watch = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
            let i = change.newValue ?? -1
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, i >= 0, i < self.items.count else { return }
                    self.model.selectedID = self.items[i].id
                }
            }
        }
    }

    func ended() { watch = nil }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated { index >= 0 && index < items.count ? items[index].url : nil }
        return url.map { $0 as NSURL }
    }

    /// Up/down page too (Quick Look itself pages with left/right).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let panel else { return false }
        let step: Int
        switch event.keyCode {
        case 126: step = -1   // up
        case 125: step = 1    // down
        default: return false
        }
        MainActor.assumeIsolated {
            let n = items.count
            guard n > 0 else { return }
            panel.currentPreviewItemIndex = min(max(panel.currentPreviewItemIndex + step, 0), n - 1)
        }
        return true
    }
}

/// Real thumbnails for any file the system can preview (pictures, PDFs, videos, documents), from the same
/// generator Finder uses; the file's icon shows until one is ready, and for files with none.
enum Thumbs {
    struct Thumb { let image: NSImage; let photo: Bool }
    @MainActor private static var cache: [String: Thumb] = [:]

    private static func key(_ url: URL) -> String {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(m)"
    }

    @MainActor static func cached(_ url: URL) -> Thumb? { cache[key(url)] }

    @MainActor static func load(_ url: URL, side: CGFloat = 36) async -> Thumb? {
        let k = key(url)
        if let c = cache[k] { return c }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let photo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        let t = Thumb(image: rep.nsImage, photo: photo)
        cache[k] = t
        return t
    }
}

/// The card's picture: a photo fills a rounded square; a document page or video frame keeps its shape on a
/// faint frame; everything else (and folders) shows the system icon.
struct FileIcon: View {
    let url: URL
    @State private var thumb: Thumbs.Thumb?

    var body: some View {
        Group {
            if let t = thumb ?? Thumbs.cached(url) {
                if t.photo {
                    Image(nsImage: t.image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                } else {
                    Image(nsImage: t.image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
            }
        }
        .task(id: url) { if thumb == nil { thumb = await Thumbs.load(url) } }
        .accessibilityHidden(true)
    }
}
