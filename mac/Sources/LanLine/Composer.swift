import SwiftUI
import AppKit

/// The floating message box (design refresh, beta.10): a glass capsule over the feed, with the round send button
/// inside it. "To:" and staged items float above it in the same glass group.
struct Composer: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 20
    @State private var field = FieldHandle()

    var body: some View {
        let p = Palette.of(scheme)
        GlassGroup(spacing: 8) {
        VStack(alignment: .trailing, spacing: 6) {
        if model.multi { TargetPicker(model: model).padding(.horizontal, 2) }
        if !model.staged.isEmpty { StagedStrip(model: model) }
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.draftEmpty {
                    Text(model.multi ? "Message \(model.sendTarget == nil ? "everyone" : model.targetLabel)" : "Message \(model.peerLabel)")
                        .font(.system(size: fs(13)))
                        .foregroundStyle(p.textSecondary)   // full strength: measured 4.5:1+ on the glass over a white desktop
                        .padding(.leading, 5).padding(.top, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                MessageField(model: model, height: $height, handle: field)
                    .frame(height: height)
            }
            .padding(.vertical, 7)
            Button { field.submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: fs(13), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(model.draftEmpty && model.staged.isEmpty ? p.sendIdle : p.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.draftEmpty && model.staged.isEmpty)
            .help("Send (Enter). Shift+Enter adds a line.")
            .accessibilityLabel("Send")
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.15), value: model.draftEmpty)
        }
        .padding(.leading, 13).padding(.trailing, 4)
        .chrome(RoundedRectangle(cornerRadius: 17, style: .circular))   // a capsule at one line, a rounded box when it grows (circular: continuous corners glitch at radius = half the height)
        }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// Items shared into Lan-Line from another app, waiting for Send. Each can be removed; nothing goes out until Send.
struct StagedStrip: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 4) {
            Text("Ready to send. Press Send, or remove what you don't want.")
                .font(.system(size: fs(10.5))).foregroundStyle(p.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.staged) { item in
                        HStack(spacing: 5) {
                            Image(systemName: icon(item)).font(.system(size: fs(10)))
                            Text(item.label).font(.system(size: fs(11))).lineLimit(1)
                            Button { model.unstage(item.id) } label: { Image(systemName: "xmark").font(.system(size: fs(8), weight: .bold)) }
                                .buttonStyle(.plain).help("Don't send this").accessibilityLabel("Remove \(item.label)")
                        }
                        .foregroundStyle(p.text)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(p.cardFill).overlay(Capsule().strokeBorder(p.cardStroke, lineWidth: 1)))
                    }
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chrome(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.staged.count) item\(model.staged.count == 1 ? "" : "s") ready to send")
    }

    private func icon(_ i: StagedItem) -> String {
        switch i.kind {
        case .text: return "text.alignleft"
        case .path(let u):
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue ? "folder" : "doc"
        }
    }
}

/// "To: Everyone ⌄": where Send goes. Only shown with 2+ paired computers; Everyone is the default.
struct TargetPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        Menu {
            Button { model.sendTarget = nil } label: { Label("Everyone", systemImage: model.sendTarget == nil ? "checkmark" : "person.3") }
            Divider()
            ForEach(model.partners) { partner in
                Button { model.sendTarget = partner.id } label: {
                    Label("\(partner.name)\(partner.up ? "" : " (not connected)")", systemImage: model.sendTarget == partner.id ? "checkmark" : "desktopcomputer")
                }
            }
        } label: {
            Text("To: \(model.targetLabel)").font(.system(size: fs(11), weight: .medium)).foregroundStyle(p.text)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 4)
        .chrome(Capsule(), interactive: true)
        .help("Where Send goes: everyone, or one computer")
        .accessibilityLabel("Send to \(model.targetLabel)")
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
        tv.font = .systemFont(ofSize: fs(13))
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
            model.draftKeep = tv.string
        }
        tv.onChange = { [weak tv] in if let tv { resize(tv) } }
        tv.onSubmit = { [weak tv] in
            guard let tv, model.sendText(tv.string) else { return }
            tv.string = ""
            resize(tv)
        }
        tv.onFiles = { model.sendFiles($0) }
        tv.onDroppedFiles = { model.sendFiles($0, fromDrop: true) }
        tv.onImage = { model.sendImage($0) }
        tv.isOwn = { model.isChipDraggedBack($0) }
        handle.textView = tv
        if !model.draftKeep.isEmpty {   // the window was rebuilt (text size, contrast): put the draft back
            tv.string = model.draftKeep
            DispatchQueue.main.async { resize(tv) }
        }
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
    var onDroppedFiles: (([URL]) -> Void)?
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
            onDroppedFiles?(urls)
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
