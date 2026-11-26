import AppKit
import SwiftUI
import LanLineCore

/// The two sounds (beta.10), made by `Chime` and played through NSSound (they follow the system output volume).
@MainActor
final class Sounds {
    private lazy var arrive = NSSound(data: Chime.wav(.arrive))
    private lazy var sent = NSSound(data: Chime.wav(.sent))
    private var gate = SoundGate()

    func arrived(soundsOn: Bool, notificationShown: Bool) {
        if gate.arrive(soundsOn: soundsOn, notificationShown: notificationShown, at: Date()) { play(arrive) }
    }

    func sentTick(soundsOn: Bool) { if soundsOn { play(sent) } }

    private func play(_ s: NSSound?) {
        guard let s else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}

/// Motion follows System Settings → Accessibility → Display → Reduce motion.
enum Motion {
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// New items rise into place.
    static let arrive = Animation.spring(response: 0.38, dampingFraction: 0.82)
}

/// The status dot breathes slowly while Lan-Line is reconnecting (still while connected, and with Reduce motion).
struct StatusDot: View {
    let connected: Bool
    let busy: Bool
    let color: Color
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: connected ? color.opacity(0.6) : .clear, radius: 3)
            .opacity(busy && dim ? 0.35 : 1)
            .onAppear { start() }
            .onChange(of: busy) { _ in start() }
    }

    private func start() {
        guard busy, !Motion.reduced else { dim = false; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
    }
}
