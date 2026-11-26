import SwiftUI
import CoreImage
import LanLineCore

/// First run (and "Pair with Another Computer…"): show a code here, or type the other computer's code.
struct PairingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        // Design refresh (beta.10): the code, name and address sit on one card, readable over any backdrop; the
        // alternatives are quiet links beneath it.
        ScrollView {
            VStack(spacing: 12) {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    LanLineMark(color: p.textSecondary, size: 15)
                    Text("Pair with your other computer")
                        .font(.system(size: fs(15), weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(model.pairMode == .show
                         ? "Open Lan-Line on the other computer, pick this one, and type this code."
                         : "Pick the computer that shows a code, then type it here.")
                        .font(.system(size: fs(11.5)))
                        .foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.pairMode == .show { ShowCode(model: model) } else { EnterCode(model: model) }
                if let e = model.pairError {
                    Text(e).font(.system(size: fs(11))).foregroundStyle(p.danger)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error: \(e)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .groupSurface(radius: 16)
                HStack(spacing: 14) {
                    if model.canCancelPairing {
                        LinkButton(title: "Cancel") { model.pairActions.cancel() }
                    }
                    LinkButton(title: model.pairMode == .show ? "Enter a code instead" : "Show a code instead") {
                        model.pairActions.switchMode(model.pairMode == .show ? .enter : .show)
                    }
                }
                .bodyScrim()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10).padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .softEdges(top: 12)
    }
}

private struct ShowCode: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 10) {
            if model.pairShowQR, let qr = PairQR.image(PairLink(code: model.pairCode, name: model.myName, port: model.pairPort, hosts: model.myAddresses)) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                    .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    .accessibilityLabel("Pairing QR code for the Lan-Line iPhone app")
                Text("Scan with Lan-Line on your iPhone").font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
            }
            HStack(spacing: 10) {
                Text(PairCode.display(model.pairCode))
                    .font(.system(size: fs(24), weight: .semibold, design: .monospaced))
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
                        .font(.system(size: fs(12), weight: .medium))
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
                Text(model.myName).font(.system(size: fs(11.5), weight: .medium)).foregroundStyle(p.text.opacity(0.85))
                if let a = model.myAddresses.first {
                    Text(a)
                        .font(.system(size: fs(11), design: .monospaced)).foregroundStyle(p.textSecondary)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Waiting for the other computer…").font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
            }
            Button(model.pairShowQR ? "Hide the QR code" : "Pairing an iPhone? Show a QR code") { withAnimation(.easeOut(duration: 0.2)) { model.pairShowQR.toggle() } }
                .buttonStyle(.plain).font(.system(size: fs(11.5), weight: .medium)).foregroundStyle(p.accent)
        }
    }
}

/// The pairing QR code (beta.10): Core Image's generator, level M, drawn pixel-sharp.
enum PairQR {
    @MainActor static func image(_ link: PairLink) -> NSImage? {
        guard !link.code.isEmpty, !link.hosts.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(link.url.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width / 2, height: out.extent.height / 2))
    }
}

private struct EnterCode: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack {
                    Text("On your network").font(.system(size: fs(11), weight: .medium)).foregroundStyle(p.textSecondary)
                    Spacer()
                    Button { model.pairActions.search() } label: {
                        if model.searching { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: fs(11), weight: .medium)).foregroundStyle(p.icon) }
                    }
                    .buttonStyle(.plain).help("Search again").accessibilityLabel("Search again")
                }
                if model.found.isEmpty && !model.searching {
                    Text("None found. Type the address the other computer shows.")
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.found, id: \.self) { peer in
                    let chosen = model.typedAddress == peer.host
                    Button { model.typedAddress = peer.host } label: {
                        HStack(spacing: 8) {
                            Image(systemName: chosen ? "checkmark.circle.fill" : "desktopcomputer")
                                .font(.system(size: fs(12))).foregroundStyle(chosen ? p.accent : p.icon).frame(width: 16)
                            Text(peer.name).font(.system(size: fs(12), weight: .medium)).foregroundStyle(p.text).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(peer.host).font(.system(size: fs(11), design: .monospaced)).foregroundStyle(p.textSecondary)
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
                    Text(model.pairBusy ? "Pairing…" : "Pair").font(.system(size: fs(13), weight: .semibold))
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
            Text(label).font(.system(size: fs(11.5), weight: .medium)).foregroundStyle(p.textSecondary).frame(width: fs(52), alignment: .leading)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(p.textSecondary.opacity(0.6)))
                .textFieldStyle(.plain)
                .font(.system(size: fs(13), design: mono ? .monospaced : .default))
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
            Text(title).font(.system(size: fs(11.5), weight: .medium))
                .foregroundStyle(hover ? p.text : p.textSecondary)
                .underline(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
