import Foundation
import CoreGraphics
import LanLineCore

/// `--demo`: sample items for screenshots and design checks (no network).
@MainActor
enum Demo {
    /// `--demo-pair show|enter`: the pairing screen with sample values.
    static func pair(_ m: AppModel, mode: String) {
        m.pairing = true
        m.myName = "MacBook Pro"
        if mode == "enter" {
            m.pairMode = .enter
            m.found = [DiscoveredPeer(name: "STUDIO-PC", host: "192.168.1.30", port: 47830, pairID: "0")]
            m.typedAddress = "192.168.1.30"
            m.typedCode = "7QK4M-2XH9C"
        } else {
            m.pairMode = .show
            m.pairCode = "7QK4M2XH9C"
            m.myAddresses = ["192.168.1.20"]
            m.pairShowQR = mode == "qr"
        }
    }

    /// `--demo-settings first|normal`: the storage settings screen with sample usage.
    static func settings(_ m: AppModel, firstRun: Bool) {
        fill(m)
        m.storage = StorageSettings()
        if !firstRun { m.storage.retentionDays = 30; m.storage.overLimit = "trash"; m.storage.confirmed = true }
        m.usageBytes = 8_400_000_000
        m.settingsFirstRun = firstRun
        m.showingSettings = true
    }

    /// `--demo-multi`: three paired computers, labels and a "✓ 1/2" row.
    static func multi(_ m: AppModel) {
        fill(m)
        m.partners = [PartnerInfo(id: "pc", name: "Studio PC", up: true), PartnerInfo(id: "intel", name: "Intel Mac", up: false)]
        m.rows[0].label = "from Studio PC"
        m.rows[1].label = "to everyone"; m.rows[1].total = 2; m.rows[1].delivered = 2
        m.rows[2].label = "to Intel Mac"
        m.rows[3].label = "from Studio PC"
        m.rows[4].label = "to everyone"; m.rows[4].total = 2; m.rows[4].delivered = 1
        m.rows[4].item = Item(id: "5", kind: m.rows[4].item!.kind, incoming: false, state: .sent)
    }

    /// A one-page "Q4 plan" (a title, a few bars) so the demo card shows a real document thumbnail.
    private static func samplePDF(_ url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 56, y: 680, width: 300, height: 40))
        let bars: [CGFloat] = [180, 260, 220, 340]
        for (i, h) in bars.enumerated() {
            ctx.setFillColor(CGColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 0.35 + 0.15 * CGFloat(i)))
            ctx.fill(CGRect(x: 80 + CGFloat(i) * 120, y: 200, width: 80, height: h))
        }
        ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
        for i in 0..<6 { ctx.fill(CGRect(x: 56, y: 620 - CGFloat(i) * 22, width: CGFloat(500 - i * 37), height: 9)) }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// `--demo-transfers`: a file arriving, one sending, one queued and one cancelled (beta.10 cards).
    static func transfers(_ m: AppModel) {
        fill(m)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-demo")
        let mov = dir.appendingPathComponent("render-final.mov"), pdf = dir.appendingPathComponent("Q4 plan.pdf")
        m.rows = [
            Row(id: "1", item: Item(id: "1", kind: .text("Sending the renders now"), incoming: true, state: .received)),
            Row(id: "2", item: Item(id: "2", kind: .file(name: "render-final.mov", size: 1_820_000_000, url: mov), incoming: true, state: .receiving(0.38)), partner: "pc"),
            Row(id: "3", item: Item(id: "3", kind: .file(name: "Q4 plan.pdf", size: 412_000_000, url: pdf), incoming: false, state: .sending(0.42))),
            Row(id: "4", item: Item(id: "4", kind: .folder(name: "Shoot 11-24", count: 214, size: 6_400_000_000, url: dir.appendingPathComponent("Shoot")), incoming: false, state: .waiting)),
            Row(id: "5", item: Item(id: "5", kind: .file(name: "old-cut.mov", size: 900_000_000, url: dir.appendingPathComponent("old-cut.mov")), incoming: true, state: .cancelled)),
        ]
        m.demoRate("2", done: 691_600_000, bytesPerSecond: 85_000_000)
        m.demoRate("3", done: 173_040_000, bytesPerSecond: 31_000_000)
    }

    /// `--demo-smart`: a code, a colour, code, a single link and a message with links (beta.10 smart items).
    static func smart(_ m: AppModel) {
        fill(m)
        let texts: [(String, Bool)] = [
            ("Your Lan-Line test verification code is 482913. It expires in 10 minutes.", true),
            ("#3A7BD5", false),
            ("```swift\nlet port: UInt16 = 47830\nprint(\"listening on \\(port)\")\n```", true),
            ("https://github.com/averywrobinson/lan-line/releases", false),
            ("Notes are in https://example.com/q4-plan and the deck on www.example.org/deck", true),
        ]
        m.rows = texts.enumerated().map { i, t in
            Row(id: "s\(i)", item: Item(id: "s\(i)", kind: .text(t.0), incoming: t.1, state: t.1 ? .received : .delivered))
        }
    }

    static func fill(_ m: AppModel, empty: Bool = false) {
        m.connected = true
        m.peer = "Studio PC"
        if empty { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-demo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("hero-export.png")
        let pdf = dir.appendingPathComponent("Q4 plan.pdf")
        if (try? Data(contentsOf: pdf).prefix(4)) != Data("%PDF".utf8) { samplePDF(pdf) }   // a real page, so it gets a thumbnail
        m.rows = [
            Row(id: "1", item: Item(id: "1", kind: .text("Can you send the new deck?"), incoming: true, state: .received)),
            Row(id: "2", item: Item(id: "2", kind: .text("Updated deck & icons"), incoming: false, state: .delivered)),
            Row(id: "3", item: Item(id: "3", kind: .file(name: "hero-export.png", size: 2_400_000, url: png), incoming: false, state: .delivered)),
            Row(id: "4", item: Item(id: "4", kind: .file(name: "Q4 plan.pdf", size: 412_000, url: pdf), incoming: true, state: .received)),
            Row(id: "5", item: Item(id: "5", kind: .file(name: "render-final.mov", size: 182_000_000, url: dir.appendingPathComponent("render-final.mov")), incoming: false, state: .sending(0.42))),
        ]
    }
}
