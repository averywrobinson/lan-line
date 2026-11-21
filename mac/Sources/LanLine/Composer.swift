import SwiftUI
import AppKit

/// The rounded message box with the round send button inside it.
struct Composer: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 20
    @State private var field = FieldHandle()

    var body: some View {
        let p = Palette.of(scheme)
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.draftEmpty {
                    Text("Message \(model.peerLabel)")
                        .font(.system(size: 13))
                        .foregroundStyle(p.textSecondary.opacity(0.8))
                        .padding(.leading, 5).padding(.top, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                MessageField(model: model, height: $height, handle: field)
                    .frame(height: height)
            }
            .padding(.vertical, 6)
            Button { field.submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(model.draftEmpty ? p.sendIdle : p.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.draftEmpty)
            .help("Send (Enter). Shift+Enter adds a line.")
            .accessibilityLabel("Send")
            .padding(.bottom, 3)
            .animation(.easeOut(duration: 0.15), value: model.draftEmpty)
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(p.composerFill)
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(
                    LinearGradient(colors: [p.composerHighlight, p.composerStroke], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: p.shadow.opacity(scheme == .dark ? 0.6 : 0.8), radius: 4, y: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

/// Lets the send button reach the AppKit text view.
@MainActor
final class FieldHandle {
    weak var textView: InputTextView?
    func submit() { textView?.onSubmit?() }
}

/// NSTextView bridge: Enter sends, Shift+Enter adds a line, pasting files or an image sends them.
struct MessageField: NSViewRepresentable {
    let model: AppModel
    @Binding var height: CGFloat
    let handle: FieldHandle

    func makeNSView(context: Context) -> NSScrollView {
        let tv = InputTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.allowsUndo = true
        tv.focusRingType = .none
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Message")
        tv.setAccessibilityIdentifier("LanLineInput")
        let model = self.model
        let resize: @MainActor (InputTextView) -> Void = { [binding = $height] tv in
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            binding.wrappedValue = min(max(20, lm.usedRect(for: tc).height + 4), 96)
            model.draftEmpty = tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        tv.onChange = { [weak tv] in if let tv { resize(tv) } }
        tv.onSubmit = { [weak tv] in
            guard let tv, model.sendText(tv.string) else { return }
            tv.string = ""
            resize(tv)
        }
        tv.onFiles = { model.sendFiles($0) }
        tv.onImage = { model.sendImage($0) }
        tv.isOwn = { model.isOwn($0) }
        handle.textView = tv
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {}
}

final class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onChange: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    var isOwn: ((URL) -> Bool)?

    override func keyDown(with e: NSEvent) {
        if (e.keyCode == 36 || e.keyCode == 76), !hasMarkedText() {
            if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) { insertNewlineIgnoringFieldEditor(nil) }
            else { onSubmit?() }
            return
        }
        super.keyDown(with: e)
    }

    override func didChangeText() { super.didChangeText(); onChange?() }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = Pasteboards.fileURLs(pb), !urls.isEmpty { onFiles?(urls); return }
        if pb.string(forType: .string) == nil, let png = Pasteboards.png(pb) { onImage?(png); return }
        super.paste(sender)
    }

    /// A plain-text view disables Paste when the clipboard holds only an image or files; we can send those.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Pasteboards.hasSendable(NSPasteboard.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        if let urls = Pasteboards.fileURLs(info.draggingPasteboard), !urls.isEmpty {
            let fresh = urls.filter { !(isOwn?($0) ?? false) }
            if !fresh.isEmpty { onFiles?(fresh) }
            return true
        }
        return super.performDragOperation(info)
    }
}

enum Pasteboards {
    @MainActor static func fileURLs(_ pb: NSPasteboard) -> [URL]? {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
    @MainActor static func hasSendable(_ pb: NSPasteboard) -> Bool {
        if let urls = fileURLs(pb), !urls.isEmpty { return true }
        return pb.availableType(from: [.png, .tiff]) != nil
    }
    @MainActor static func png(_ pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
