import AppKit
import LanLineCore

/// Clipboard sharing (beta.10): copy on this Mac, paste on the other computer, and the other way round. Off until
/// turned on in Settings. Watches the pasteboard's change count (twice a second, as clipboard managers do), never
/// sends what password managers mark private (nspasteboard.org types), never queues, and never sends back what
/// just arrived. Pictures go as PNG up to 10 MB; files are left to the normal send.
@MainActor
final class ClipboardShare {
    private let model: AppModel
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastFingerprint: String?
    private var toldOld = false

    init(model: AppModel) { self.model = model }

    /// Start or stop watching to match the setting (called at start and after Save).
    func apply() {
        if model.storage.shareClipboardValue {
            guard timer == nil else { return }
            lastCount = NSPasteboard.general.changeCount   // what's there now was copied before sharing started
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate(); timer = nil
            model.clipPaused = false
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = (pb.types ?? []).map(\.rawValue)
        let content = Self.read(pb, pictures: model.storage.shareClipboardPicturesValue)
        guard ClipRules.shouldSend(content, types: types, enabled: model.storage.shareClipboardValue, paused: model.clipPaused,
                                   pictures: model.storage.shareClipboardPicturesValue, lastFingerprint: lastFingerprint),
              let c = content, let hub = model.hub else { return }
        lastFingerprint = ClipRules.fingerprint(c)
        hub.sendClip(c) { [weak self] sent, tooOld in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, sent == 0, tooOld > 0, !self.toldOld else { return }
                    self.toldOld = true
                    self.model.note("To share the clipboard, update Lan-Line on the other computer too.", fadeAfter: 10)
                }
            }
        }
    }

    /// Text first (what people mostly copy); a picture only when there is no text. Files are skipped.
    static func read(_ pb: NSPasteboard, pictures: Bool) -> ClipContent? {
        if pb.types?.contains(.fileURL) == true { return nil }
        if let s = pb.string(forType: .string), !s.isEmpty { return .text(s) }
        guard pictures else { return nil }
        if let png = pb.data(forType: .png) { return .png(png) }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return .png(png)
        }
        return nil
    }

    /// A partner's clipboard arrived: put it on this Mac's pasteboard, and don't send it straight back.
    func received(_ c: ClipContent) {
        guard model.storage.shareClipboardValue, !model.clipPaused else { return }
        if case .png = c, !model.storage.shareClipboardPicturesValue { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch c {
        case .text(let t): pb.setString(t, forType: .string)
        case .png(let d):
            pb.setData(d, forType: .png)
            if let tiff = NSImage(data: d)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }   // for older apps
        }
        lastCount = pb.changeCount
        lastFingerprint = ClipRules.fingerprint(c)
    }
}
