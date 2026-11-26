import SwiftUI
import LanLineCore

/// Search and filters (beta.10): ⌘F (Edit → Find…) opens this bar over the feed. Every word must match the text,
/// a file name or the other computer's name, ignoring case and accents; the chips narrow it to a kind. Searches the
/// whole history (up to 1,000 items), not just what the window holds. Esc or Done closes it.
struct SearchBar: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        GlassGroup(spacing: 6) {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: fs(12))).foregroundStyle(p.icon)
                TextField("Search texts, files and computers", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: fs(13))).foregroundStyle(p.text)
                    .focused($focused)
                    .onExitCommand { close() }
                    .accessibilityLabel("Search")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(p.icon) }
                        .buttonStyle(.plain).help("Clear").accessibilityLabel("Clear search")
                }
                Button("Done") { close() }.buttonStyle(.plain).font(.system(size: fs(12), weight: .medium)).foregroundStyle(p.accent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .chrome(Capsule())
            HStack(spacing: 6) {
                ForEach(HistoryFilter.allCases, id: \.self) { f in
                    let on = model.filter == f
                    Button { model.filter = f } label: {
                        Text(f.title).font(.system(size: fs(11.5), weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : p.text)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background { if on { Capsule().fill(p.accent) } }   // the selected filter is solid: never left to a material
                            .chrome(Capsule(), tint: on ? .clear : nil, interactive: !on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 4)
                if model.isFiltering {
                    let n = model.visibleRows.count
                    Text("\(n) \(n == 1 ? "match" : "matches")").font(.system(size: fs(11)).monospacedDigit()).foregroundStyle(p.textSecondary)
                        .bodyScrim()
                }
            }
        }
        }
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 8)
        .onAppear { focused = true }
    }

    private func close() {
        model.searchOpen = false; model.query = ""; model.filter = .all
    }
}

struct NoMatches: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: fs(20), weight: .light)).foregroundStyle(p.textSecondary)
            Text("No matches").font(.system(size: fs(13), weight: .medium)).foregroundStyle(p.text)
            Text(model.historyURL == nil ? "History is off, so only this session's items are searched." : "Search covers the last \(History.cap.formatted()) items on this Mac.")
                .font(.system(size: fs(11))).foregroundStyle(p.textSecondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
