import SwiftUI
import LanLineCore

/// The welcome tour (beta.10): three cards over the window, once, on a new install after pairing and the first-run
/// settings; again any time from Help › Welcome Tour. The wording is `Tour.cards(.mac)`, shared with the other apps.
struct TourView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cards = Tour.cards(.mac)

    static func symbol(_ id: String) -> String {
        switch id {
        case "send": return "paperplane.fill"
        case "anywhere": return "square.and.arrow.up.fill"
        default: return "pin.fill"
        }
    }

    var body: some View {
        let p = Palette.of(scheme)
        let page = min(max(model.tourPage, 0), cards.count - 1)
        let card = cards[page]
        let last = page == cards.count - 1
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.45 : 0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: Self.symbol(card.id))
                    .font(.system(size: fs(24), weight: .medium)).foregroundStyle(.white)
                    .rotationEffect(.degrees(card.id == "close" ? 45 : 0))
                    .frame(width: fs(54), height: fs(54))
                    .background(RoundedRectangle(cornerRadius: fs(15), style: .continuous).fill(p.accent))
                    .accessibilityHidden(true)
                VStack(spacing: 5) {
                    Text(card.title).font(.system(size: fs(15), weight: .semibold)).foregroundStyle(p.text)
                    Text(card.body).font(.system(size: fs(12))).foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(card.title). \(card.body) Card \(page + 1) of \(cards.count).")
                HStack(spacing: 6) {
                    ForEach(cards.indices, id: \.self) { i in
                        Circle().fill(i == page ? p.accent : p.textSecondary.opacity(0.35)).frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
                HStack(spacing: 14) {
                    if !last {
                        Button("Skip") { model.tourActions.done() }
                            .buttonStyle(.plain).font(.system(size: fs(12), weight: .medium)).foregroundStyle(p.textSecondary)
                            .keyboardShortcut(.cancelAction)
                    } else if page > 0 {
                        Button("Back") { go(page - 1) }
                            .buttonStyle(.plain).font(.system(size: fs(12), weight: .medium)).foregroundStyle(p.textSecondary)
                    }
                    Button { if last { model.tourActions.done() } else { go(page + 1) } } label: {
                        Text(last ? "Done" : "Next").font(.system(size: fs(12.5), weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 20).frame(height: fs(28))
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.accent))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 300)
            .groupSurface(radius: 18)
            .shadow(color: p.shadow, radius: 18, y: 6)
            .padding(16)
            .id(page)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .accessibilityAddTraits(.isModal)
    }

    private func go(_ to: Int) {
        if reduceMotion { model.tourPage = to } else { withAnimation(.easeOut(duration: 0.2)) { model.tourPage = to } }
    }
}

/// The empty window (beta.10): a small picture of two computers passing a file, the line "Drop here. Grab there.",
/// and three hints. In a short window only the headline and one line show.
struct EmptyState: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        ViewThatFits(in: .vertical) {
            VStack(spacing: 12) {
                Illustration(p: p)
                Text("Drop here. Grab there.").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(p.text.opacity(0.85))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Tour.hints(.mac)) { h in
                        HStack(spacing: 8) {
                            Image(systemName: Self.symbol(h.id)).font(.system(size: fs(11), weight: .medium)).foregroundStyle(p.accent).frame(width: fs(16))
                            Text(h.text).font(.system(size: fs(11.5))).foregroundStyle(p.textSecondary)
                        }
                    }
                }
            }
            .padding(16)
            VStack(spacing: 8) {
                LanLineMark(color: p.textSecondary, size: 15)
                Text("Drop here. Grab there.").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(p.text.opacity(0.85))
                Text("Type, paste or drop files to send them to \(model.peerLabel).")
                    .font(.system(size: fs(11))).foregroundStyle(p.textSecondary).multilineTextAlignment(.center)
            }
            .padding(14)
        }
        .bodyScrim(radius: 16, pad: 0)
        .padding(6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing here yet. \(Tour.hints(.mac).map(\.text).joined(separator: ". ")).")
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "type": return "keyboard"
        case "drop": return "arrow.down.doc"
        default: return "square.and.arrow.up"
        }
    }

    /// Two computers and a file on its way between them.
    private struct Illustration: View {
        let p: Palette
        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 26, weight: .light)).foregroundStyle(p.textSecondary)
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { _ in Circle().fill(p.textSecondary.opacity(0.45)).frame(width: 3, height: 3) }
                    Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(p.accent)
                    ForEach(0..<2, id: \.self) { _ in Circle().fill(p.textSecondary.opacity(0.45)).frame(width: 3, height: 3) }
                }
                Image(systemName: "desktopcomputer").font(.system(size: 26, weight: .light)).foregroundStyle(p.textSecondary)
            }
            .accessibilityHidden(true)
        }
    }
}
