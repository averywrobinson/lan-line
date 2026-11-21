import Foundation
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

    static func fill(_ m: AppModel, empty: Bool = false) {
        m.connected = true
        m.peer = "Studio PC"
        if empty { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-demo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("hero-export.png")
        let pdf = dir.appendingPathComponent("Q4 plan.pdf")
        if !FileManager.default.fileExists(atPath: pdf.path) { FileManager.default.createFile(atPath: pdf.path, contents: Data(count: 412_000)) }
        m.rows = [
            Row(id: "1", item: Item(id: "1", kind: .text("Can you send the new deck?"), incoming: true, state: .received)),
            Row(id: "2", item: Item(id: "2", kind: .text("Updated deck & icons"), incoming: false, state: .delivered)),
            Row(id: "3", item: Item(id: "3", kind: .file(name: "hero-export.png", size: 2_400_000, url: png), incoming: false, state: .delivered)),
            Row(id: "4", item: Item(id: "4", kind: .file(name: "Q4 plan.pdf", size: 412_000, url: pdf), incoming: true, state: .received)),
            Row(id: "5", item: Item(id: "5", kind: .file(name: "render-final.mov", size: 182_000_000, url: dir.appendingPathComponent("render-final.mov")), incoming: false, state: .sending(0.42))),
        ]
    }
}
