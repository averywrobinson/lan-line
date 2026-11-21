import SwiftUI
import FerryCore

/// First run (and "Pair with Another Computer…"): show a code here, or type the other computer's code.
struct PairingView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    LanLineMark(color: p.textSecondary, size: 15)
                    Text("Pair with your other computer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(model.pairMode == .show
                         ? "Open Lan-Line on the other computer, pick this one, and type this code."
                         : "Pick the computer that shows a code, then type it here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.pairMode == .show { ShowCode(model: model) } else { EnterCode(model: model) }
                if let e = model.pairError {
                    Text(e).font(.system(size: 11)).foregroundStyle(p.danger)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error: \(e)")
                }
                HStack(spacing: 14) {
                    if model.canCancelPairing {
                        LinkButton(title: "Cancel") { model.pairActions.cancel() }
                    }
                    LinkButton(title: model.pairMode == .show ? "Enter a code instead" : "Show a code instead") {
                        model.pairActions.switchMode(model.pairMode == .show ? .enter : .show)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ShowCode: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(PairCode.display(model.pairCode))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(p.text)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(model.pairCode.map(String.init).joined(separator: " "))")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PairCode.display(model.pairCode), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(copied ? p.connected : p.icon)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the code")
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.cardStroke, lineWidth: 1)))

            VStack(spacing: 2) {
                Text(model.myName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.text.opacity(0.85))
                if let a = model.myAddresses.first {
                    Text(a)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textSecondary)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Waiting for the other computer…").font(.system(size: 11)).foregroundStyle(p.textSecondary)
            }
        }
    }
}

private struct EnterCode: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack {
                    Text("On your network").font(.system(size: 11, weight: .medium)).foregroundStyle(p.textSecondary)
                    Spacer()
                    Button { model.pairActions.search() } label: {
                        if model.searching { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundStyle(p.icon) }
                    }
                    .buttonStyle(.plain).help("Search again").accessibilityLabel("Search again")
                }
                if model.found.isEmpty && !model.searching {
                    Text("None found. Type the address the other computer shows.")
                        .font(.system(size: 11)).foregroundStyle(p.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.found, id: \.self) { peer in
                    let chosen = model.typedAddress == peer.host
                    Button { model.typedAddress = peer.host } label: {
                        HStack(spacing: 8) {
                            Image(systemName: chosen ? "checkmark.circle.fill" : "desktopcomputer")
                                .font(.system(size: 12)).foregroundStyle(chosen ? p.accent : p.icon).frame(width: 16)
                            Text(peer.name).font(.system(size: 12, weight: .medium)).foregroundStyle(p.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(peer.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textSecondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(chosen ? p.accent.opacity(0.12) : p.cardFill)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(chosen ? p.accent.opacity(0.5) : p.cardStroke, lineWidth: 1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(peer.name), \(peer.host)")
                }
            }
            Field(label: "Address", text: $model.typedAddress, prompt: "192.168.1.20", mono: true)
            Field(label: "Code", text: $model.typedCode, prompt: "XXXXX-XXXXX", mono: true, onSubmit: { model.pairActions.connect() })
            Button { model.pairActions.connect() } label: {
                HStack(spacing: 6) {
                    if model.pairBusy { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12).tint(.white) }
                    Text(model.pairBusy ? "Pairing…" : "Pair").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.pairBusy)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var mono = false
    var onSubmit: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.textSecondary).frame(width: 52, alignment: .leading)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(p.textSecondary.opacity(0.6)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(p.text)
                .autocorrectionDisabled()
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.composerFill)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.composerStroke, lineWidth: 1)))
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    var body: some View {
        let p = Palette.of(scheme)
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover ? p.text : p.textSecondary)
                .underline(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
