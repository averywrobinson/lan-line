import AppKit
import SwiftUI
import LanLineCore

/// The accessibility pass (beta.10): text size, Increase Contrast and VoiceOver announcements, in one place.
enum A11y {
    /// Lan-Line's own text size (Settings › Appearance). macOS has no system-wide text size for apps, so, like
    /// Messages, Lan-Line carries its own. Changed only on the main thread; read while views are built.
    nonisolated(unsafe) static var textScale: CGFloat = 1
    /// macOS "Increase contrast" (or `--increase-contrast`, for off-screen checks).
    nonisolated(unsafe) static var increaseContrast = false
    nonisolated(unsafe) static var forcedContrast = false

    @MainActor static func refresh() {
        increaseContrast = forcedContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Say something through VoiceOver (only while it is running): an arrival, a failure.
    @MainActor static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let w = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        NSAccessibility.post(element: w, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// A font size at the chosen text size (to the half point, so strokes stay crisp).
func fs(_ size: CGFloat) -> CGFloat { (size * A11y.textScale * 2).rounded() / 2 }
