import Foundation

/// How long received files are kept and how much room they may use. Saved as `settings.json` next to the
/// pairing config, so re-pairing never resets it. Defaults: nothing is ever deleted; warn as 10 GB fills up.
public struct StorageSettings: Codable, Sendable, Equatable {
    /// Days to keep a received file; 0 = keep forever.
    public var retentionDays: Int = 0
    /// Storage limit for received files in GB; 0 = no limit.
    public var limitGB: Double = 10
    /// Over the limit: "warn" (just say so) or "trash" (move the oldest received files to the Trash).
    public var overLimit: String = "warn"
    /// Every so often, remind that cleaned-up files sit in the Trash until it is emptied.
    public var trashReminder: Bool = true
    /// The user has looked at these settings and pressed Save at least once.
    public var confirmed: Bool = false
    public var lastTrashReminder: Date?
    public var lastLimitWarning: Date?

    public init() {}

    public static let retentionChoices = [0, 1, 10, 30, 60, 90]
    public static let limitChoices: [Double] = [0, 5, 10, 25, 50, 100]

    public static var defaultURL: URL {
        LanLineConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    public static func load(from url: URL = defaultURL) -> StorageSettings {
        guard let d = try? Data(contentsOf: url) else { return StorageSettings() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(StorageSettings.self, from: d)) ?? StorageSettings()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: url, options: [.atomic])
    }

    public var limitBytes: Int64 { limitGB > 0 ? Int64(limitGB * 1_000_000_000) : 0 }
}

/// One file Lan-Line received and saved. Only files in this log are ever cleaned up: anything the user
/// put in the folder, or a file moved out of it, is left alone.
public struct ReceivedFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var receivedAt: Date
    public init(path: String, size: Int64, receivedAt: Date) { self.path = path; self.size = size; self.receivedAt = receivedAt }
}

public enum ReceivedLog {
    public static var defaultURL: URL {
        LanLineConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("received.json")
    }

    public static func load(from url: URL = defaultURL) -> [ReceivedFile] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ReceivedFile].self, from: d)) ?? []
    }

    public static func save(_ files: [ReceivedFile], to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(files).write(to: url, options: [.atomic])
    }
}

/// What a cleanup pass should do. Pure: the apps do the file moves and show the notes.
public struct CleanupPlan: Equatable, Sendable {
    public var expired: [ReceivedFile] = []     // older than the retention period
    public var overLimit: [ReceivedFile] = []   // oldest files moved to get back under the limit ("trash" mode)
    public var usageBytes: Int64 = 0            // what the kept files use afterwards
    public var limitBytes: Int64 = 0
    /// 0 = fine, 1 = at least 80 % of the limit, 2 = over the limit.
    public var level: Int = 0
    public var toTrash: [ReceivedFile] { expired + overLimit }
}

public enum Cleanup {
    /// `existing` = log entries whose files are still there (the caller drops the rest from the log).
    public static func plan(_ existing: [ReceivedFile], settings s: StorageSettings, now: Date) -> CleanupPlan {
        var p = CleanupPlan()
        p.limitBytes = s.limitBytes
        var keep = existing.sorted { $0.receivedAt < $1.receivedAt }   // oldest first
        if s.retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(s.retentionDays) * 86_400)
            p.expired = keep.filter { $0.receivedAt <= cutoff }
            keep.removeAll { $0.receivedAt <= cutoff }
        }
        var usage = keep.reduce(Int64(0)) { $0 + $1.size }
        if p.limitBytes > 0, s.overLimit == "trash" {
            // Never move the newest file: one file bigger than the limit is the user's to decide about.
            while usage > p.limitBytes, keep.count > 1 {
                let f = keep.removeFirst()
                p.overLimit.append(f)
                usage -= f.size
            }
        }
        p.usageBytes = usage
        if p.limitBytes > 0 {
            p.level = usage > p.limitBytes ? 2 : (Double(usage) >= 0.8 * Double(p.limitBytes) ? 1 : 0)
        }
        return p
    }

    /// Quiet warnings: at most one limit warning a day, one Trash reminder every 14 days.
    public static func shouldWarnLimit(_ s: StorageSettings, level: Int, now: Date) -> Bool {
        level > 0 && (s.lastLimitWarning.map { now.timeIntervalSince($0) >= 86_400 } ?? true)
    }

    public static func shouldRemindTrash(_ s: StorageSettings, movedSomething: Bool, now: Date) -> Bool {
        movedSomething && s.trashReminder && (s.lastTrashReminder.map { now.timeIntervalSince($0) >= 14 * 86_400 } ?? true)
    }

    public static func formatBytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_000_000_000
        if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
        let mb = Double(b) / 1_000_000
        return mb >= 1 ? String(format: "%.0f MB", mb) : "\(max(b / 1000, b > 0 ? 1 : 0)) KB"
    }
}
