import AppKit
import SwiftUI
import LanLineCore

/// "Keyboard Shortcuts" (⌘/ or Help → Keyboard Shortcuts) (beta.10): every shortcut on one card over the window.
/// The rows come from `KeyboardHelp`, the same list the Windows app shows.
struct ShortcutSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        let sections = KeyboardHelp.rows(mac: true, show: model.storage.showShortcut, send: model.storage.sendShortcut)
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.45 : 0.25).ignoresSafeArea()
                .onTapGesture { model.showingShortcuts = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(p.text)
                    Spacer()
                    Button { model.showingShortcuts = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: fs(15))).foregroundStyle(p.icon)
                    }
                    .buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close")
                }
                .padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sections, id: \.section) { sec in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(sec.section.uppercased()).font(.system(size: fs(10), weight: .semibold)).foregroundStyle(p.textSecondary)
                                ForEach(sec.rows, id: \.action) { r in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(r.keys)
                                            .font(.system(size: fs(11.5), weight: .medium).monospacedDigit())
                                            .foregroundStyle(r.keys.hasPrefix("Off") ? p.textSecondary : p.text)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.hairline))
                                            .frame(width: 104, alignment: .leading)
                                        Text(r.action).font(.system(size: fs(12))).foregroundStyle(p.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
            .padding(.horizontal, 18).padding(.top, 52).padding(.bottom, 18)
        }
    }
}

/// A shortcut recorder for Settings: click, press the keys. Esc cancels; ⌫ turns the shortcut off.
struct ShortcutField: View {
    @Binding var value: Shortcut?
    var offLabel = "Off"
    @State private var recording = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        HStack(spacing: 6) {
            Button { recording.toggle() } label: {
                Text(recording ? "Type a shortcut…" : (value?.display(mac: true) ?? offLabel))
                    .font(.system(size: fs(12), weight: .medium).monospacedDigit())
                    .foregroundStyle(recording ? p.accent : (value == nil ? p.textSecondary : p.text))
                    .frame(minWidth: 120)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.hairline))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(recording ? p.accent : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .background(KeyCatcher(active: $recording) { e in
                if e.keyCode == 53 { recording = false; return }                       // Esc: keep it as it was
                if e.keyCode == 51 || e.keyCode == 117 { value = nil; recording = false; return }   // ⌫: off
                if let s = HotKeys.shortcut(from: e) { value = s; recording = false }
            })
            .onChange(of: recording) { on in   // the current global shortcuts would fire instead of being recorded
                NotificationCenter.default.post(name: .lanLineRecordingShortcut, object: nil, userInfo: ["on": on])
            }
            .accessibilityLabel("Shortcut")
            .accessibilityValue(value?.display(mac: true) ?? offLabel)
            let canClear = value != nil && !recording   // the space is always kept, so the fields line up
            Button { value = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(p.icon) }
                .buttonStyle(.plain).help("Turn off").accessibilityLabel("Turn off")
                .opacity(canClear ? 1 : 0).disabled(!canClear).accessibilityHidden(!canClear)
        }
    }
}

extension Notification.Name {
    static let lanLineRecordingShortcut = Notification.Name("LanLineRecordingShortcut")
}

/// While `active`, takes the window's key presses (modifiers included) and hands them over instead of typing.
private struct KeyCatcher: NSViewRepresentable {
    @Binding var active: Bool
    let onKey: (NSEvent) -> Void

    final class Coordinator { var monitor: Any? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        if active, c.monitor == nil {
            let handler = onKey
            c.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                nonisolated(unsafe) let ev = e
                MainActor.assumeIsolated { handler(ev) }
                return nil
            }
        } else if !active, let m = c.monitor {
            NSEvent.removeMonitor(m); c.monitor = nil
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
}
