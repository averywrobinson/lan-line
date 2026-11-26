import SwiftUI

/// Lan-Line's palette, one set per appearance: the brand kit's "smoked glass" tokens in dark, a matching
/// light set. Neutrals carry the UI; blue is the action accent; emerald = connected, coral = pinned on top.
struct Palette {
    let bgTop, bgBottom, glow, hairline: Color
    let text, textSecondary, icon: Color
    let outFill, outStroke, inFill, inStroke: Color
    let cardFill, cardStroke, composerFill, composerStroke, composerHighlight: Color
    /// The design refresh (beta.10): group surfaces (settings groups, the pairing card) and the solid stand-in for
    /// glass controls (older macOS, Reduce Transparency, Increase Contrast, snapshots).
    let groupFill, groupStroke, controlFill, controlStroke: Color
    let sendIdle, accent, connected, idleDot, danger: Color
    let shadow, pinOn: Color

    static func of(_ scheme: ColorScheme) -> Palette {
        A11y.increaseContrast ? (scheme == .dark ? darkContrast : lightContrast) : (scheme == .dark ? dark : light)
    }

    /// macOS "Increase contrast" (accessibility pass, beta.10): opaque surfaces, strokes that outline every shape,
    /// and secondary text close to primary.
    static let darkContrast = dark.contrast(
        secondary: Color(hex: 0xDCE3EC), stroke: .white.opacity(0.55), inStroke: Color(hex: 0xB9DAFF).opacity(0.85),
        out: Color(red: 58/255, green: 64/255, blue: 76/255), incoming: Color(red: 38/255, green: 59/255, blue: 84/255),
        group: Color(red: 40/255, green: 46/255, blue: 57/255), control: Color(red: 44/255, green: 50/255, blue: 62/255),
        hairline: .white.opacity(0.35), idle: Color(hex: 0xA8B4C4))
    static let lightContrast = light.contrast(
        secondary: .black.opacity(0.82), stroke: .black.opacity(0.55), inStroke: Color(red: 0.20, green: 0.38, blue: 0.62),
        out: .white, incoming: Color(red: 0.86, green: 0.92, blue: 0.985), group: .white, control: .white,
        hairline: .black.opacity(0.35), idle: Color(hex: 0x5B6676))

    private func contrast(secondary: Color, stroke: Color, inStroke: Color, out: Color, incoming: Color, group: Color,
                          control: Color, hairline: Color, idle: Color) -> Palette {
        Palette(bgTop: bgTop, bgBottom: bgBottom, glow: .clear, hairline: hairline,
                text: text, textSecondary: secondary, icon: secondary,
                outFill: out, outStroke: stroke, inFill: incoming, inStroke: inStroke,
                cardFill: out, cardStroke: stroke, composerFill: control, composerStroke: stroke, composerHighlight: stroke,
                groupFill: group, groupStroke: stroke, controlFill: control, controlStroke: stroke,
                sendIdle: sendIdle, accent: accent, connected: connected, idleDot: idle, danger: danger,
                shadow: shadow, pinOn: pinOn)
    }

    static let dark = Palette(
        bgTop: Color(hex: 0x1B2029), bgBottom: Color(hex: 0x11151C),
        glow: Color(hex: 0x93C5FD).opacity(0.10), hairline: .white.opacity(0.08),
        text: Color(hex: 0xF8FAFC), textSecondary: Color(hex: 0xA3B0C2), icon: Color(hex: 0xA3B0C2),
        // Content surfaces are near-opaque (beta.10): their text reads the same over any wallpaper and slider setting.
        outFill: Color(red: 58/255, green: 64/255, blue: 76/255).opacity(0.92), outStroke: .white.opacity(0.11),
        inFill: Color(red: 38/255, green: 59/255, blue: 84/255).opacity(0.94), inStroke: Color(hex: 0x93C5FD).opacity(0.24),
        cardFill: Color(red: 58/255, green: 64/255, blue: 76/255).opacity(0.92), cardStroke: .white.opacity(0.11),
        composerFill: .white.opacity(0.05), composerStroke: .white.opacity(0.11), composerHighlight: .white.opacity(0.24),
        groupFill: Color(red: 40/255, green: 46/255, blue: 57/255).opacity(0.92), groupStroke: .white.opacity(0.08),
        controlFill: Color(red: 44/255, green: 50/255, blue: 62/255).opacity(0.96), controlStroke: .white.opacity(0.14),
        sendIdle: .white.opacity(0.16), accent: Color(red: 0.25, green: 0.52, blue: 0.96),
        connected: Color(hex: 0x34D359), idleDot: Color(hex: 0x64748B), danger: Color(red: 1.0, green: 0.42, blue: 0.40),
        shadow: .black.opacity(0.40), pinOn: Color(hex: 0xE0463A))

    static let light = Palette(
        bgTop: Color(red: 0.984, green: 0.988, blue: 0.992), bgBottom: Color(red: 0.937, green: 0.945, blue: 0.957),
        glow: Color(red: 0.55, green: 0.70, blue: 0.95).opacity(0.10), hairline: .black.opacity(0.08),
        text: .black.opacity(0.87), textSecondary: .black.opacity(0.64), icon: .black.opacity(0.55),
        outFill: .white.opacity(0.94), outStroke: .black.opacity(0.09),
        inFill: Color(red: 0.86, green: 0.92, blue: 0.985), inStroke: Color(red: 0.66, green: 0.78, blue: 0.92),
        cardFill: .white.opacity(0.94), cardStroke: .black.opacity(0.09),
        composerFill: .white, composerStroke: .black.opacity(0.13), composerHighlight: .white,
        groupFill: .white.opacity(0.92), groupStroke: .black.opacity(0.08),
        controlFill: .white.opacity(0.97), controlStroke: .black.opacity(0.13),
        sendIdle: .black.opacity(0.18), accent: Color(red: 0.15, green: 0.45, blue: 0.92),
        connected: Color(hex: 0x22A447), idleDot: Color(hex: 0x94A3B8), danger: Color(red: 0.84, green: 0.18, blue: 0.16),
        shadow: .black.opacity(0.10), pinOn: Color(hex: 0xD2392D))
}

/// The Lan-Line mark: two rounded squares joined by a short line (the left one solid, the right one dimmer).
struct LanLineMark: View {
    var color: Color
    var size: CGFloat = 16
    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(color, lineWidth: size * 0.11)
                .frame(width: size, height: size)
            Rectangle().fill(color).frame(width: size * 0.45, height: size * 0.11)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(color.opacity(0.55), lineWidth: size * 0.11)
                .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
