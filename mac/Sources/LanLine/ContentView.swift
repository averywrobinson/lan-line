import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import LanLineCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    private var p: Palette { .of(scheme) }
    @State private var composerHeight: CGFloat = 56

    var body: some View {
        // Two layers (design refresh, beta.10): rows are content and scroll under the floating message box; they
        // fade out as they reach the title, which stays plain text. No hairline: the fade is the edge.
        VStack(spacing: 0) {
            Header(model: model)
            if model.showingSettings {
                SettingsView(model: model)
            } else if model.pairing {
                PairingView(model: model)
            } else {
                if model.searchOpen { SearchBar(model: model).transition(.move(edge: .top).combined(with: .opacity)) }
                ZStack(alignment: .bottom) {
                    FeedView(model: model, bottomInset: composerHeight)
                    Composer(model: model).readHeight($composerHeight)
                }
            }
        }
        .id("\(model.textScale)-\(model.a11yTick)")   // a new text size or contrast setting rebuilds every view
        .environment(\.liquidGlass, model.glass && model.liquid)
        .environment(\.bodyScrim, model.glass ? StorageSettings.scrimStrength(model.glassOpacity) : 0)
        .background(Background(glass: model.glass, opacity: model.glassOpacity))
        .overlay { if model.dropTargeted && !model.pairing && !model.showingSettings { DropOverlay(peer: model.peerLabel) } }
        .overlay { if model.showingShortcuts { ShortcutSheet(model: model).transition(.opacity) } }
        .overlay { if model.showingTour { TourView(model: model).transition(.opacity) } }
        .animation(.easeOut(duration: 0.15), value: model.showingTour)
        .animation(.easeOut(duration: 0.15), value: model.showingShortcuts)
        .animation(.easeOut(duration: 0.15), value: model.searchOpen)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)   // one light click on Force Touch trackpads
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
    var opacity = StorageSettings.defaultGlassOpacity
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        let a = glass ? StorageSettings.tintAlpha(opacity, dark: scheme == .dark) : 1
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
                    .font(.system(size: fs(13), weight: .semibold))
                    .foregroundStyle(p.text)
                HStack(spacing: 5) {
                    StatusDot(connected: model.connected, busy: !model.connected && !model.partners.isEmpty && !model.pairing,
                              color: model.connected ? p.connected : p.idleDot)
                    Text(model.statusLine)
                        .font(.system(size: fs(11)))
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(model.statusLine)")
                .help(model.multi ? model.partnerStates : "")
            }
            .bodyScrim(radius: 12, pad: 10)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 76)   // keep clear of the traffic lights and the pin

            Button { model.togglePin() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .font(.system(size: fs(12), weight: .medium))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(model.pinned ? p.pinOn.opacity(pinHover ? 1 : 0.92) : p.icon.opacity(pinHover ? 1 : 0.85))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                    .chrome(Circle(), interactive: true)   // the one control in the title area
            }
            .buttonStyle(.plain)
            .onHover { pinHover = $0 }
            .help(model.pinned ? "Pinned on top. Click to unpin." : "Click to keep Lan-Line on top")
            .accessibilityLabel(model.pinned ? "Unpin" : "Pin on top")
            .padding(.trailing, 10)
            .padding(.top, 2)
        }
        .padding(.top, 6)
        .frame(height: max(50, fs(46)), alignment: .top)
    }
}

// MARK: feed

private struct FeedView: View {
    @ObservedObject var model: AppModel
    /// The floating message box's height: the last row rests above it, older rows pass under it.
    var bottomInset: CGFloat = 0
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.visibleRows) { row in
                        RowView(row: row, model: model)
                            .transition(.asymmetric(   // new items rise into place (beta.10)
                                insertion: .scale(scale: 0.94, anchor: row.item?.incoming == true ? .bottomLeading : .bottomTrailing)
                                    .combined(with: .opacity).combined(with: .offset(y: 8)),
                                removal: .opacity))
                            .overlay {
                                if model.highlightID == row.id {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
                                        .padding(-4).allowsHitTesting(false).transition(.opacity)
                                }
                            }
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14).padding(.bottom, 4)
            }
            .bottomAnchored()
            .scrollIndicators(.automatic)
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomInset) }
            .softEdges(top: 18, bottom: 14, floor: 0.35)
            .onAppear { if let last = model.rows.last?.id { proxy.scrollTo(last, anchor: .bottom) } }   // macOS 13 has no default anchor
            .overlay {
                Group {
                    if model.isFiltering, model.visibleRows.isEmpty { NoMatches(model: model) }
                    else if model.rows.isEmpty, !model.isFiltering { EmptyState(model: model) }
                }
                .padding(.bottom, bottomInset)   // centred in the part of the feed that shows
            }
            .onChange(of: model.rows.count) { _ in
                if let last = model.rows.last?.id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .onChange(of: bottomInset) { _ in   // the message box grew (a second line, the "To:" chip, larger text): keep the newest row above it
                if let last = model.rows.last?.id, !model.isFiltering { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: model.highlightID) { id in   // a clicked notification: bring its item into view
                if let id { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: model.selectedID) { id in   // keyboard selection (beta.10): keep it in view
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
    }
}

private struct RowView: View {
    let row: Row
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let note = row.note, let link = row.link {
            UpdateNote(text: note, link: link, step: model.updateStep, install: { model.installUpdate() }) { model.dismiss(row.id) }
        } else if let note = row.note {
            Text(note)
                .font(.system(size: fs(11)))
                .foregroundStyle(Palette.of(scheme).textSecondary)
                .multilineTextAlignment(.center)
                .bodyScrim(radius: 9)
                .frame(maxWidth: .infinity)
        } else if let item = row.item {
            VStack(alignment: item.incoming ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 0) {
                    if !item.incoming { Spacer(minLength: 44) }
                    switch item.kind {
                    case .text(let t): TextBubble(item: item, text: t, selected: model.selectedID == item.id, model: model)
                    case .file(let name, let size, let url): FileCard(item: item, name: name, size: size, url: url, model: model)
                    case .folder(let name, let count, let size, let url): FileCard(item: item, name: name, size: size, url: url, model: model, count: count)
                    }
                    if item.incoming { Spacer(minLength: 44) }
                }
                if let caption = RowView.caption(row) {
                    Text(caption)
                        .font(.system(size: fs(10)))
                        .foregroundStyle(Palette.of(scheme).textSecondary)
                        .bodyScrim()
                        .padding(.horizontal, 6)
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        }
    }
}

/// "Lan-Line X is available · Install · Release notes ×" (beta.10). Install downloads the signed update and
/// restarts into it; Release notes opens the release page.
private struct UpdateNote: View {
    let text: String
    let link: URL
    let step: MacUpdater.Step?
    let install: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: fs(11))).foregroundStyle(p.icon)
            switch step {
            case .checking?: Text("Checking the update…").font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
            case .downloading(let f)?:
                Text("Downloading \(text.replacingOccurrences(of: " is available", with: ""))… \(Int(f * 100))%")
                    .font(.system(size: fs(11)).monospacedDigit()).foregroundStyle(p.textSecondary)
            case .installing?: Text("Restarting into the new version…").font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
            case .failed(let why)?:
                Text(why).font(.system(size: fs(11))).foregroundStyle(p.textSecondary).lineLimit(2)
                Button("Download") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.link).font(.system(size: fs(11), weight: .medium)).help(link.absoluteString)
            case nil:
                Text(text).font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                Button("Install", action: install)
                    .buttonStyle(.link).font(.system(size: fs(11), weight: .semibold))
                    .help("Download, check and install the update, then reopen Lan-Line")
                Button("Release notes") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.link).font(.system(size: fs(11))).help(link.absoluteString)
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: fs(9), weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(p.icon).help("Dismiss")
                .accessibilityLabel("Dismiss update notice")
        }
        .bodyScrim(radius: 10)
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
            case .sending(let f), .receiving(let f): Text("\(Int(f * 100))%").font(.system(size: fs(10), weight: .medium).monospacedDigit())
            case .cancelled: Image(systemName: "xmark").help("Cancelled")
            case .sent: Image(systemName: "ellipsis").help("Sent, waiting for confirmation")
            case .delivered: Image(systemName: "checkmark").help("Delivered")
            case .failed(let why): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.danger).help("Failed: \(why)")
            case .received: EmptyView()
            }
        }
        .font(.system(size: fs(11), weight: .semibold))
        .foregroundStyle(p.icon)
    }
}

/// Stop a transfer (beta.10): an × in a circle where the copy button sits while a file is moving or queued.
private struct CancelButton: View {
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: fs(14)))
                .foregroundStyle(hover ? p.danger : p.icon)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Cancel")
        .accessibilityLabel("Cancel transfer")
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
                .font(.system(size: fs(11), weight: .medium))
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
    var selected = false
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SmartTextBubble(item: item, text: text, selected: selected, model: model)   // codes, colours, code, links (beta.10)
            HStack(spacing: 6) {
                CopyButton { Clip.copy(text: SmartText.code(text)?.body ?? text) }
                if !item.incoming { StateMark(state: item.state) }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
        }
        .padding(.leading, 13).padding(.trailing, 9).padding(.vertical, 8)
        .background(BubbleBackground(incoming: item.incoming))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.accent, lineWidth: 2).allowsHitTesting(false) }
        }
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

    private var removed: Bool { model.removedPaths.contains(url.path) || model.missingPaths.contains(url.path) }
    /// Not a file to open yet (still arriving) or any more (stopped short); outgoing cards point at the original.
    private var unavailable: Bool {
        if removed { return true }
        switch item.state { case .receiving, .cancelled, .failed: return item.incoming; default: return false }
    }
    private var moving: Bool { switch item.state { case .sending, .receiving: return true; default: return false } }
    private var detail: String {
        if model.removedPaths.contains(url.path) { return "Moved to Trash" }
        if model.missingPaths.contains(url.path) { return "No longer on this Mac" }
        if let t = model.progressText(item) { return t }
        if item.state == .cancelled { return "Cancelled" }
        if item.incoming, case .failed(let why) = item.state { return "Failed: \(why)" }
        let bytes = ByteCountFormatter.string(fromByteCount: max(size, 0), countStyle: .file)
        guard let count else { return bytes }
        return "\(count) file\(count == 1 ? "" : "s") · \(bytes)"
    }

    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                FileIcon(url: url)
                    .opacity(unavailable && !moving ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: fs(13), weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: fs(11)).monospacedDigit())
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 90, alignment: .leading)
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    if model.canCancel(item) { CancelButton { model.cancel(item.id) } }
                    else if !unavailable { CopyButton { Clip.copy(file: url) } }
                    if !item.incoming, !moving { StateMark(state: item.state) }
                }
            }
            switch item.state {
            case .sending(let f), .receiving(let f):
                ProgressView(value: f).progressViewStyle(.linear).controlSize(.mini).tint(p.accent)
                    .animation(.easeOut(duration: 0.25), value: f)
            default: EmptyView()
            }
        }
        .padding(11)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.incoming ? p.inFill : p.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(item.incoming ? p.inStroke : p.cardStroke, lineWidth: 1))
                .shadow(color: p.shadow.opacity(0.6), radius: scheme == .dark ? 5 : 3, y: 1.5)
        )
        .overlay {
            if model.selectedID == item.id {   // selected for Quick Look (Space)
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.accent, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2) { if !unavailable { NSWorkspace.shared.open(url) } }
        .simultaneousGesture(TapGesture().onEnded { if !unavailable { model.select(item.id) } })
        .onDrag { model.chipDragAt = Date(); return unavailable ? NSItemProvider() : (NSItemProvider(contentsOf: url) ?? NSItemProvider()) }
        .contextMenu {
            if model.canCancel(item) {
                Button(item.incoming ? "Stop Receiving" : "Cancel Sending") { model.cancel(item.id) }
                Divider()
            }
            if !unavailable {
                Button("Quick Look") { model.select(item.id); model.onQuickLook() }.disabled(removed)
                Divider()
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy") { Clip.copy(file: url) }
            }
        }
        .help("Click and press Space for Quick Look. Double-click to open. Drag out to copy.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.incoming ? "Received" : "Sent") \(count == nil ? "file" : "folder"): \(name), \(detail)")
        .accessibilityAction(named: "Open") { NSWorkspace.shared.open(url) }
        .accessibilityAction(named: "Quick Look") { model.select(item.id); model.onQuickLook() }
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
                    Image(systemName: "arrow.up.doc").font(.system(size: fs(22), weight: .medium))
                    Text("Drop to send to \(peer)").font(.system(size: fs(13), weight: .semibold))
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
