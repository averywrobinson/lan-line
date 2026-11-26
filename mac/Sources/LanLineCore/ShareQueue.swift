import Foundation
import notify

/// The iPhone's share sheet (beta.10) is a separate little program from the app. They meet in one shared folder:
/// the pairing, the settings and the history live there, and so does this queue of things the share sheet took
/// in. The sheet tries to send straight away; whatever it couldn't send stays queued and the app sends it the
/// next time it is in front.
public enum SharedHome {
    public static let group = "group.com.avery.lan-line"

    /// The folder the app and its share sheet both reach; nil where there is no app group (the Mac, tests).
    public static var container: URL? {
        #if os(iOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        #else
        return nil
        #endif
    }

    /// The app's own Application Support/Lan-Line (where the first iPhone builds kept everything).
    public static var privateSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lan-Line", isDirectory: true)
    }

    /// Where config.json, settings.json and the history live on iPhone.
    public static var supportDir: URL {
        container?.appendingPathComponent("Library/Application Support/Lan-Line", isDirectory: true) ?? privateSupportDir
    }

    public static var queueDir: URL { supportDir.appendingPathComponent("ShareQueue", isDirectory: true) }

    /// Things that arrive while only the share sheet is connected (it asks the computer not to send any).
    public static var inboxDir: URL { supportDir.appendingPathComponent("Inbox", isDirectory: true) }

    /// Move an earlier build's files into the shared folder, once: only when the shared folder has no pairing yet.
    @discardableResult
    public static func migrate(from old: URL, to new: URL, files: [String] = ["config.json", "settings.json", History.fileName]) -> Bool {
        let fm = FileManager.default
        guard old.standardizedFileURL != new.standardizedFileURL,
              fm.fileExists(atPath: old.appendingPathComponent("config.json").path),
              !fm.fileExists(atPath: new.appendingPathComponent("config.json").path) else { return false }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for f in files {
            let a = old.appendingPathComponent(f), b = new.appendingPathComponent(f)
            guard fm.fileExists(atPath: a.path) else { continue }
            try? fm.removeItem(at: b)
            do { try fm.moveItem(at: a, to: b) } catch { if f == "config.json" { return false } }
        }
        return true
    }
}

/// One thing the share sheet took in.
public struct ShareJob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// "text", "file" or "folder".
    public var kind: String
    public var text: String?
    /// The file's (or folder's) name inside the job's folder.
    public var name: String?
    /// The computers it still has to reach (partner ids); nil = every paired computer.
    public var to: [String]?
    public var at: Date
    /// Taken in, but nobody has said "send" yet (the sheet is still asking who gets it). A draft is never
    /// sent by anyone; if the sheet goes away without an answer, the draft is thrown away later.
    public var draft: Bool?

    public init(id: String = UUID().uuidString, kind: String, text: String? = nil, name: String? = nil, to: [String]?, at: Date = Date(), draft: Bool? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.name = name; self.to = to; self.at = at; self.draft = draft
    }
}

/// The queue on disk: one folder per job (`<id>/job.json`, and `<id>/payload/<name>` for a file or folder).
/// Two programs use it at once, so taking a job is a rename: whoever renames the folder first has it.
public struct ShareQueue: Sendable {
    public static let maxText = 100_000
    public let dir: URL
    public init(dir: URL = SharedHome.queueDir) { self.dir = dir }

    private func folder(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }
    private func jobFile(_ id: String) -> URL { folder(id).appendingPathComponent("job.json") }
    private static func isID(_ s: String) -> Bool { !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }

    private func write(_ job: ShareJob) throws {
        try FileManager.default.createDirectory(at: folder(job.id), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970   // fractions kept: things shared together stay in order
        try enc.encode(job).write(to: jobFile(job.id), options: [.atomic])
    }

    @discardableResult
    public func add(text: String, to: [String]?, draft: Bool = false) throws -> ShareJob {
        let job = ShareJob(kind: "text", text: String(text.prefix(Self.maxText)), to: to, draft: draft ? true : nil)
        try write(job)
        return job
    }

    /// Take a file or folder in (copied, or moved when `move` is set: the share sheet's own temporary copies).
    @discardableResult
    public func add(file: URL, to: [String]?, move: Bool = false, draft: Bool = false) throws -> ShareJob {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else { throw CocoaError(.fileNoSuchFile) }
        let name = file.lastPathComponent
        let job = ShareJob(kind: isDir.boolValue ? "folder" : "file", name: name, to: to, draft: draft ? true : nil)
        let payload = folder(job.id).appendingPathComponent("payload", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            if move { try FileManager.default.moveItem(at: file, to: payload.appendingPathComponent(name)) }
            else { try FileManager.default.copyItem(at: file, to: payload.appendingPathComponent(name)) }
            try write(job)   // last: a job only counts once its payload is in place
        } catch {
            try? FileManager.default.removeItem(at: folder(job.id))
            throw error
        }
        return job
    }

    /// Where a file job's bytes are (nil for text).
    public func payload(_ job: ShareJob) -> URL? {
        guard job.kind != "text", let n = job.name, !n.isEmpty, !n.contains("/"), n != ".", n != ".." else { return nil }
        return folder(job.id).appendingPathComponent("payload", isDirectory: true).appendingPathComponent(n)
    }

    /// Everything waiting to be sent, oldest first. Damaged entries and drafts are skipped.
    public func pending() -> [ShareJob] { all().filter { $0.draft != true } }

    private func all() -> [ShareJob] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var jobs: [ShareJob] = []
        for id in ids where Self.isID(id) {
            guard let d = try? Data(contentsOf: jobFile(id)), d.count <= 1 << 20, let j = try? dec.decode(ShareJob.self, from: d), j.id == id else { continue }
            if j.kind == "text" { guard j.text != nil else { continue } }
            else { guard let p = payload(j), FileManager.default.fileExists(atPath: p.path) else { continue } }
            jobs.append(j)
        }
        return jobs.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// One computer has it: cross it off. Returns true when the job is finished (nobody left); the payload is
    /// then kept (for the history's thumbnail) until `sweep` unless `keepFile` is false.
    @discardableResult
    public func delivered(_ job: ShareJob, to partner: String, keepFile: Bool = true) -> Bool {
        var j = job
        j.to = (j.to ?? []).filter { $0 != partner }
        if j.to?.isEmpty ?? true { finish(j.id, keepFile: keepFile); return true }
        try? write(j)
        return false
    }

    /// Update a job's remaining computers (the share sheet turns "everyone" into the list it is sending to).
    public func update(_ job: ShareJob) { if FileManager.default.fileExists(atPath: jobFile(job.id).path) { try? write(job) } }

    /// The job is done or given up: it no longer counts as waiting.
    public func finish(_ id: String, keepFile: Bool) {
        guard Self.isID(id) else { return }
        if keepFile { try? FileManager.default.removeItem(at: jobFile(id)) }
        else { try? FileManager.default.removeItem(at: folder(id)) }
    }

    /// Take a job out of the queue to send it from somewhere else (the app): its file is moved to
    /// `into/<id>/<name>`. Returns the file's new place (nil for text), or throws when another program got there first.
    public func claim(_ job: ShareJob, into: URL) throws -> URL? {
        let fm = FileManager.default
        let mine = dir.appendingPathComponent(".claim-\(job.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.moveItem(at: folder(job.id), to: mine)   // the rename decides who has it
        defer { try? fm.removeItem(at: mine) }
        guard job.kind != "text", let n = job.name else { return nil }
        let dest = into.appendingPathComponent(job.id, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let out = dest.appendingPathComponent(n)
        try? fm.removeItem(at: out)
        try fm.moveItem(at: mine.appendingPathComponent("payload", isDirectory: true).appendingPathComponent(n), to: out)
        return out
    }

    /// Tidy up: finished jobs' kept files, half-made jobs and stale claims older than `age`, and drafts nobody
    /// answered within `draftAge` (the sheet was swiped away or closed by iOS while it was still asking).
    public func sweep(olderThan age: TimeInterval = 7 * 86_400, draftAge: TimeInterval = 3600, now: Date = Date()) {
        let fm = FileManager.default
        for j in all() where j.draft == true && now.timeIntervalSince(j.at) > draftAge { finish(j.id, keepFile: false) }
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let f = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: f.appendingPathComponent("job.json").path) { continue }   // still waiting
            let made = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? .distantPast
            if now.timeIntervalSince(made) > age { try? fm.removeItem(at: f) }
        }
    }
}

/// A knock between the app and its share sheet (a system-wide notification by name; it carries nothing).
public final class ShareSignal: @unchecked Sendable {
    /// The share sheet is about to connect. The app answers `appActive` when it is in front (then it does the
    /// sending itself), or steps off the line when it is in the background.
    public static let hello = "com.avery.lan-line.share.hello"
    public static let appActive = "com.avery.lan-line.share.app-active"
    /// The share sheet queued something for the app in front to send.
    public static let queued = "com.avery.lan-line.share.queued"

    public static func post(_ name: String) { notify_post(name) }

    private var token: Int32 = NOTIFY_TOKEN_INVALID
    public init(_ name: String, queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        notify_register_dispatch(name, &token, queue) { _ in handler() }
    }
    deinit { if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) } }
}
