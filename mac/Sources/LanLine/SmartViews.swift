import AppKit
import SwiftUI
import LanLineCore

/// Smart text items (beta.10): a one-time code to copy on its own, a colour swatch, code in a block, a link card
/// and link chips. What a message is comes from `SmartText` (shared with Windows).
struct SmartTextBubble: View {
    let item: Item
    let text: String
    var selected = false
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.of(scheme)
        let info = SmartText.analyze(text)
        VStack(alignment: .leading, spacing: 7) {
            if let url = info.singleLink {
                LinkCard(url: url, model: model)
            } else if let code = info.code {
                CodeBlock(code: code)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let c = info.color { Swatch(color: c).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 } }
                    Text(text)
                        .font(.system(size: fs(13))).foregroundStyle(p.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let otp = info.otp { CodeChip(code: otp) }
                if !info.links.isEmpty {
                    HStack(spacing: 5) { ForEach(info.links.prefix(3), id: \.self) { LinkChip(url: $0) } }
                }
            }
        }
        .contextMenu {
            Button("Copy") { Clip.copy(text: info.code?.body ?? text) }
            if let otp = info.otp { Button("Copy Code \(otp)") { Clip.copy(text: otp) } }
            if let c = info.color {
                Button("Copy as \(c.hex)") { Clip.copy(text: c.hex) }
                Button("Copy as \(c.rgb)") { Clip.copy(text: c.rgb) }
                Button("Copy as \(c.hsl)") { Clip.copy(text: c.hsl) }
            }
            ForEach(info.links, id: \.self) { u in Button("Open \(LinkPreview.host(u))") { Links.open(u) } }
        }
    }
}

enum Links {
    /// Only web links ever open (SmartText only finds http(s)); the default browser opens them.
    @MainActor static func open(_ u: URL) {
        guard let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return }
        NSWorkspace.shared.open(u)
    }
}

/// "Copy code 482 913": the digits only, grouped for reading.
private struct CodeChip: View {
    let code: String
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        Button {
            Clip.copy(text: code)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "key.fill").font(.system(size: fs(10), weight: .semibold))
                Text(copied ? "Copied" : "Copy code").font(.system(size: fs(11.5), weight: .medium))
                Text(Self.grouped(code)).font(.system(size: fs(13), weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(p.accent))
        }
        .buttonStyle(.plain)
        .help("Copy only the code")
        .accessibilityLabel("Copy code \(code)")
    }
    static func grouped(_ c: String) -> String { c.count == 6 ? c.prefix(3) + " " + c.suffix(3) : c }
}

private struct Swatch: View {
    let color: SmartColor
    var body: some View {
        Circle()
            .fill(Color(.sRGB, red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255, opacity: color.a))
            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
            .frame(width: 16, height: 16)
            .accessibilityLabel("Colour \(color.hex)")
    }
}

private struct CodeBlock: View {
    let code: SmartCode
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 4) {
            Text(code.language ?? "Code").font(.system(size: fs(10), weight: .semibold)).foregroundStyle(p.textSecondary)   // the bubble's copy button copies the code
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.body)
                    .font(.system(size: fs(12), design: .monospaced)).foregroundStyle(p.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(scheme == .dark ? 0.28 : 0.05)))
        .frame(maxWidth: 300, alignment: .leading)
    }
}

private struct LinkChip: View {
    let url: URL
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        Button { Links.open(url) } label: {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: fs(9.5), weight: .semibold))
                Text(LinkPreview.host(url)).font(.system(size: fs(11))).lineLimit(1)
            }
            .foregroundStyle(p.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(p.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// A message that is one link: the site, the path, Open; with link previews on, the page's title and picture.
private struct LinkCard: View {
    let url: URL
    @ObservedObject var model: AppModel
    @State private var preview: LinkPreview?
    @State private var picture: NSImage?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Palette.of(scheme)
        VStack(alignment: .leading, spacing: 0) {
            if let picture {
                Color.clear.frame(height: 120)   // as wide as the card, which shrinks in a narrow window
                    .overlay(Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)).clipped()
            }
            HStack(spacing: 9) {
                Image(systemName: "safari").font(.system(size: fs(18), weight: .light)).foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? preview?.site ?? LinkPreview.host(url))
                        .font(.system(size: fs(12.5), weight: .semibold)).foregroundStyle(p.text).lineLimit(2)
                    Text(LinkPreview.host(url) + (url.path.count > 1 ? url.path : ""))
                        .font(.system(size: fs(11))).foregroundStyle(p.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Button("Open") { Links.open(url) }.controlSize(.small).fixedSize().layoutPriority(1)
            }
            .padding(9)
        }
        .frame(minWidth: 150, idealWidth: 260, maxWidth: 260, alignment: .leading)   // was a fixed 260, wider than a 380-point window allows
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(scheme == .dark ? 0.22 : 0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(url.absoluteString)
        .task(id: model.storage.linkPreviewsValue) {
            guard model.storage.linkPreviewsValue else { preview = nil; picture = nil; return }
            preview = await PreviewFetcher.shared.preview(url)
            if let img = preview?.image { picture = await PreviewFetcher.shared.picture(img) }
        }
    }
}

/// Fetches link previews (only while "Show link previews" is on): the first 512 KB of the page, 5 s at most, no
/// cookies or cache shared with anything; pictures up to 2 MB. Results are kept for this session.
@MainActor
final class PreviewFetcher {
    static let shared = PreviewFetcher()
    private var pages: [URL: LinkPreview?] = [:]
    private var pictures: [URL: NSImage?] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = LinkPreview.timeout; c.timeoutIntervalForResource = LinkPreview.timeout
        c.httpAdditionalHeaders = ["User-Agent": "Lan-Line link preview", "Accept": "text/html"]
        return URLSession(configuration: c)
    }()

    func preview(_ url: URL) async -> LinkPreview? {
        if let hit = pages[url] { return hit }
        var result: LinkPreview?
        if let (bytes, response) = try? await session.bytes(from: url),
           (response.mimeType ?? "").contains("html") {
            var data = Data()
            do { for try await b in bytes { data.append(b); if data.count >= LinkPreview.maxHTML { break } } } catch {}
            let html = String(decoding: data, as: UTF8.self)
            let p = LinkPreview.parse(html: html, base: response.url ?? url)
            if p.title != nil || p.image != nil { result = p }
        }
        pages[url] = result
        return result
    }

    func picture(_ url: URL) async -> NSImage? {
        if let hit = pictures[url] { return hit }
        var img: NSImage?
        // Read as a stream and stop at the cap: a server that sends no length (or lies) can't make us buffer more.
        if let (bytes, response) = try? await session.bytes(from: url), (response.mimeType ?? "").hasPrefix("image/"),
           response.expectedContentLength <= Int64(LinkPreview.maxImage) {
            var data = Data(), tooBig = false
            do { for try await b in bytes { data.append(b); if data.count > LinkPreview.maxImage { tooBig = true; break } } } catch { tooBig = true }
            if !tooBig { img = NSImage(data: data) }
        }
        pictures[url] = img
        return img
    }
}
