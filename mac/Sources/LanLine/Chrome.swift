import SwiftUI
import LanLineCore

/// The design refresh (beta.10): two layers. Content (bubbles, cards, groups) sits on near-opaque surfaces from the
/// palette. Controls (the message box, the pin, chips, search, the settings bar) float above it on Liquid Glass on
/// macOS 26+, and on a solid control fill everywhere else: older macOS, Reduce Transparency, Increase Contrast, and
/// off-screen snapshots (which can't render glass).

private struct LiquidGlassKey: EnvironmentKey { static let defaultValue = false }
private struct BodyScrimKey: EnvironmentKey { static let defaultValue = 0.0 }

extension EnvironmentValues {
    /// Liquid Glass may be used: a live window with the glass backdrop on.
    var liquidGlass: Bool {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self] = newValue }
    }
    /// 0...1: how much backing text on the window body needs (`StorageSettings.scrimStrength`).
    var bodyScrim: Double {
        get { self[BodyScrimKey.self] }
        set { self[BodyScrimKey.self] = newValue }
    }
}

/// Draws a floating control's material behind its content.
struct Chrome<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.liquidGlass) private var liquid
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.bodyScrim) private var scrim

    func body(content: Content) -> some View {
        let p = Palette.of(scheme)
        if #available(macOS 26.0, *), liquid, !reduceTransparency, contrast != .increased, !A11y.increaseContrast {
            // Untinted glass takes on whatever is behind the window. As the user makes the window more see-through,
            // the controls get some of the body colour back, so their text keeps its contrast (a white desktop behind
            // dark glass was the measured worst case).
            // The backing goes *under* the glass (which samples it), not into the glass tint: a tint is dropped while the
            // window is inactive, and a pinned Lan-Line is inactive most of the time.
            content.glassEffect(glass(tint), in: shape)
                .background(shape.fill(p.bgTop.opacity(tint == nil ? 0.9 * scrim : 0)))
        } else {
            content.background(
                shape.fill(tint ?? p.controlFill)
                    .overlay(shape.strokeBorder(p.controlStroke, lineWidth: 1))
                    .shadow(color: p.shadow.opacity(scheme == .dark ? 0.55 : 0.9), radius: 5, y: 2))
        }
    }

    @available(macOS 26.0, *)
    private func glass(_ tint: Color?) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Glass controls that sit close together share one sampling region, so they blend and morph into each other.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    @Environment(\.liquidGlass) private var liquid
    var body: some View {
        if #available(macOS 26.0, *), liquid { GlassEffectContainer(spacing: spacing) { content() } } else { content() }
    }
}

/// A content group: a settings section or the pairing card.
struct GroupSurface: ViewModifier {
    var radius: CGFloat = 12
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let p = Palette.of(scheme)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background(shape.fill(p.groupFill).overlay(shape.strokeBorder(p.groupStroke, lineWidth: 1)))
    }
}

/// Backing for small text that sits directly on the window body (captions, notes): invisible at the default window
/// opacity, a soft capsule of the body colour as the window is made more see-through.
struct BodyScrim: ViewModifier {
    var radius: CGFloat? = nil   // nil = capsule
    var pad: CGFloat = 6
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bodyScrim) private var strength
    func body(content: Content) -> some View {
        if strength > 0.01 {
            let fill = Palette.of(scheme).bgTop.opacity(StorageSettings.scrimMax * strength)
            content.padding(.horizontal, pad).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: radius ?? 100, style: .continuous).fill(fill))
                .padding(.horizontal, -pad).padding(.vertical, -2)
        } else {
            content
        }
    }
}

extension View {
    func chrome<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(Chrome(shape: shape, tint: tint, interactive: interactive))
    }
    func groupSurface(radius: CGFloat = 12) -> some View { modifier(GroupSurface(radius: radius)) }
    func bodyScrim(radius: CGFloat? = nil, pad: CGFloat = 6) -> some View { modifier(BodyScrim(radius: radius, pad: pad)) }

    /// Content fades out over `top` points at its upper edge (rows dissolving under the title) and to `floor`
    /// over `bottom` points at its lower edge (rows passing under the floating message box).
    func softEdges(top: CGFloat = 0, bottom: CGFloat = 0, floor: Double = 0) -> some View {
        mask(VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(floor)], startPoint: .top, endPoint: .bottom).frame(height: bottom)
        })
    }

    /// Report this view's height (the floating message box tells the feed how much room to leave).
    func readHeight(_ binding: Binding<CGFloat>) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            .onPreferenceChange(HeightKey.self) { [binding] v in
                DispatchQueue.main.async { if abs(binding.wrappedValue - v) > 0.5 { binding.wrappedValue = v } }
            }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
