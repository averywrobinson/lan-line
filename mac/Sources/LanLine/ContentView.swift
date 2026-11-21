import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import LanLineCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    private var p: Palette { .of(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            Rectangle().fill(p.hairline).frame(height: 1)
            if model.showingSettings {
                SettingsView(model: model)
            } else if model.pairing {
                PairingView(model: model)
            } else {
                FeedView(model: model)
                Composer(model: model)
            }
        }
        .background(Background(glass: model.glass))
        .overlay { if model.dropTargeted && !model.pairing && !model.showingSettings { DropOverlay(peer: model.peerLabel) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            for prov in providers {
                _ = prov.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.sendFiles([url], fromDrop: true) }
                }
            }
            return true
        }
        .ignoresSafeArea(.container, edges: .top)   // the header sits in the (transparent) title bar
    }
}

private struct Background: View {
    var glass = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        let a = glass ? (scheme == .dark ? 0.74 : 0.80) : 1
        ZStack {
            LinearGradient(colors: [p.bgTop.opacity(a), p.bgBottom.opacity(a)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [p.glow, .clear], center: .top, startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }
}

// MARK: header

private struct Header: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var pinHover = false

    var body: some View {
        let p = Palette.of(scheme)
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                Text("Lan-Line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text)
                HStack(spacing: 5) {
                    Circle().fill(model.connected ? p.connected : p.idleDot).frame(width: 7, height: 7)
                        .shadow(color: model.connected ? p.connected.opacity(0.6) : .clear, radius: 3)
                    Text(model.statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(model.statusLine)")
                .help(model.multi ? model.partnerStates : "")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 76)   // keep clear of the traffic lights and the pin

            Button { model.togglePin() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(model.pinned ? p.pinOn.opacity(pinHover ? 1 : 0.92) : p.icon.opacity(pinHover ? 1 : 0.7))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { pinHover = $0 }
            .help(model.pinned ? "Pinned on top. Click to unpin." : "Click to keep Lan-Line on top")
            .accessibilityLabel(model.pinned ? "Unpin" : "Pin on top")
            .padding(.trailing, 10)
            .padding(.top, 4)
        }
        .padding(.top, 6)
        .frame(height: 50, alignment: .top)
    }
}

// MARK: feed

private struct FeedView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        RowView(row: row, model: model).id(row.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .bottomAnchored()
            .scrollIndicators(.automatic)
            .onAppear { if let last = model.rows.last?.id { proxy.scrollTo(last, anchor: .bottom) } }   // macOS 13 has no default anchor
            .overlay { if model.rows.isEmpty { EmptyState(model: model) } }
            .onChange(of: model.rows.count) { _ in
                if let last = model.rows.last?.id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }
}

private struct EmptyState: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 10) {
            LanLineMark(color: p.textSecondary, size: 15)
            Text("Drop here. Grab there.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.text.opacity(0.8))
            Text("Type, paste or drop files to send them to \(model.peerLabel).")
                .font(.system(size: 11))
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

private struct RowView: View {
    let row: Row
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let note = row.note, let link = row.link {
            UpdateNote(text: note, link: link) { model.dismiss(row.id) }
        } else if let note = row.note {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Palette.of(scheme).textSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        } else if let item = row.item {
            VStack(alignment: item.incoming ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 0) {
                    if !item.incoming { Spacer(minLength: 44) }
                    switch item.kind {
                    case .text(let t): TextBubble(item: item, text: t)
                    case .file(let name, let size, let url): FileCard(item: item, name: name, size: size, url: url, model: model)
                    case .folder(let name, let count, let size, let url): FileCard(item: item, name: name, size: size, url: url, model: model, count: count)
                    }
                    if item.incoming { Spacer(minLength: 44) }
                }
                if let caption = RowView.caption(row) {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.of(scheme).textSecondary)
                        .padding(.horizontal, 6)
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        }
    }
}

/// "Lan-Line X is available · Download ×": opens the release page in the browser, nothing more.
private struct UpdateNote: View {
    let text: String
    let link: URL
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(p.icon)
            Text(text).font(.system(size: 11)).foregroundStyle(p.textSecondary)
            Button("Download") { NSWorkspace.shared.open(link) }
                .buttonStyle(.link).font(.system(size: 11, weight: .medium))
                .help(link.absoluteString)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(p.icon).help("Dismiss")
                .accessibilityLabel("Dismiss update notice")
        }
        .frame(maxWidth: .infinity)
    }
}

extension RowView {
    /// "from STUDIO-PC", "to everyone · ✓ 2/3": only with 2+ partners; the count shows until all have it.
    static func caption(_ row: Row) -> String? {
        guard let label = row.label else { return nil }
        guard row.total > 1, row.item?.state != .delivered else { return label }
        return "\(label) · ✓ \(row.delivered)/\(row.total)"
    }
}

/// Delivery state as a small icon (never color alone).
private struct StateMark: View {
    let state: ItemState
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        Group {
            switch state {
            case .waiting: Image(systemName: "clock").help("Waiting for the PC")
            case .sending(let f): Text("\(Int(f * 100))%").font(.system(size: 10, weight: .medium).monospacedDigit())
            case .sent: Image(systemName: "ellipsis").help("Sent, waiting for confirmation")
            case .delivered: Image(systemName: "checkmark").help("Delivered")
            case .failed(let why): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.danger).help("Failed: \(why)")
            case .received: EmptyView()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(p.icon)
    }
}

private struct CopyButton: View {
    let action: () -> Void
    @State private var copied = false
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? p.connected : p.icon.opacity(hover ? 1 : 0.8))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Copy")
        .accessibilityLabel("Copy")
    }
}

private struct BubbleBackground: View {
    let incoming: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(incoming ? p.inFill : p.outFill)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(incoming ? p.inStroke : p.outStroke, lineWidth: 1))
    }
}

private struct TextBubble: View {
    let item: Item
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(p.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                CopyButton { Clip.copy(text: text) }
                if !item.incoming { StateMark(state: item.state) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
        }
        .padding(.leading, 13).padding(.trailing, 9).padding(.vertical, 8)
        .background(BubbleBackground(incoming: item.incoming))
        .contextMenu { Button("Copy") { Clip.copy(text: text) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.incoming ? "Received" : "Sent") text: \(text)")
    }
}

private struct FileCard: View {
    let item: Item
    let name: String
    let size: Int64
    let url: URL
    @ObservedObject var model: AppModel
    var count: Int? = nil          // a folder: how many files are inside
    @Environment(\.colorScheme) private var scheme

    private var removed: Bool { model.removedPaths.contains(url.path) }
    private var detail: String {
        if removed { return "Moved to Trash" }
        let bytes = ByteCountFormatter.string(fromByteCount: max(size, 0), countStyle: .file)
        guard let count else { return bytes }
        return "\(count) file\(count == 1 ? "" : "s") · \(bytes)"
    }

    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                FileIcon(url: url)
                    .opacity(removed ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(p.textSecondary)
                }
                .frame(minWidth: 90, alignment: .leading)
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    if !removed { CopyButton { Clip.copy(file: url) } }
                    if !item.incoming { StateMark(state: item.state) }
                }
            }
            if case .sending(let f) = item.state {
                ProgressView(value: f).progressViewStyle(.linear).controlSize(.mini).tint(p.accent)
            }
        }
        .padding(11)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.incoming ? p.inFill : p.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(item.incoming ? p.inStroke : p.cardStroke, lineWidth: 1))
                .shadow(color: p.shadow, radius: scheme == .dark ? 6 : 3, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2) { if !removed { NSWorkspace.shared.open(url) } }
        .onDrag { model.chipDragAt = Date(); return removed ? NSItemProvider() : (NSItemProvider(contentsOf: url) ?? NSItemProvider()) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy") { Clip.copy(file: url) }
        }
        .help("Double-click to open. Drag out to copy.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.incoming ? "Received" : "Sent") \(count == nil ? "file" : "folder"): \(name), \(detail)")
        .accessibilityAction(named: "Open") { NSWorkspace.shared.open(url) }
    }
}

/// A real thumbnail for images, the system icon for everything else.
private struct FileIcon: View {
    let url: URL
    var body: some View {
        Group {
            if let thumb = Thumbs.image(for: url) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
enum Thumbs {
    private static var cache: [URL: NSImage] = [:]
    static func image(for url: URL) -> NSImage? {
        if let c = cache[url] { return c }
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96,
                  kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = img
        return img
    }
}

enum Clip {
    @MainActor static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @MainActor static func copy(file url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}

private struct DropOverlay: View {
    let peer: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(p.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.accent.opacity(0.10)))
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.doc").font(.system(size: 22, weight: .medium))
                    Text("Drop to send to \(peer)").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(p.accent)
            )
            .padding(8)
            .allowsHitTesting(false)
    }
}

private extension View {
    /// Start scrolled to the newest row (macOS 14+); macOS 13 scrolls there on appear instead.
    @ViewBuilder func bottomAnchored() -> some View {
        if #available(macOS 14.0, *) { self.defaultScrollAnchor(.bottom) } else { self }
    }
}
