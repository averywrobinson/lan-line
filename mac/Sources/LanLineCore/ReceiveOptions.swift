import Foundation

/// What happens when a file arrives (beta.10, polish item 11): nothing (the default), show it in Finder / Explorer,
/// or open it. Opening is only for kinds that can't run anything: pictures, PDFs, plain text and media.
public enum AfterReceive: String, CaseIterable, Sendable {
    case nothing, reveal, open
}

/// Where received files go and what to do after (beta.10). The same rules as `ReceiveOptions` in LanLine.Core.
public enum ReceiveOptions {
    /// Kinds that open in a viewer and can't run code. Everything else (apps, scripts, installers, archives, Office
    /// files with macros…) is shown in its folder instead.
    public static let openable: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
        "pdf", "txt", "md", "csv", "rtf",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "flac",
    ]
    /// In one burst, at most this many files open; the rest are shown in the folder.
    public static let maxOpensPerBurst = 3

    /// The folder a partner's files go to: the chosen folder, or a folder per computer inside it.
    public static func folder(base: URL, perComputer: Bool, partner: String) -> URL {
        guard perComputer else { return base }
        return base.appendingPathComponent(Names.sanitize(partner), isDirectory: true)
    }

    /// What to really do for one arrived item: "open" falls back to "reveal" for folders and kinds that could run
    /// code, and after `maxOpensPerBurst` opens.
    public static func action(_ setting: AfterReceive, name: String, isFolder: Bool, opensSoFar: Int) -> AfterReceive {
        guard setting == .open else { return setting }
        if isFolder || opensSoFar >= maxOpensPerBurst { return .reveal }
        let ext = (name as NSString).pathExtension.lowercased()
        return openable.contains(ext) ? .open : .reveal
    }
}

/// One burst of arrivals (beta.10): how many files were opened and shown. A burst ends after `quiet` seconds
/// without an *arrival* (not without an open), so a long stream of files never opens more than the cap, and
/// the folder is shown once, not once per file. The same rule as `ArrivalBurst` in LanLine.Core.
public struct ArrivalBurst: Sendable {
    public static let quiet: TimeInterval = 5
    /// Finder / Explorer comes forward once per burst; the other files are in that same window.
    public static let maxRevealsPerBurst = 1
    private var lastArrival = Date.distantPast
    public private(set) var opens = 0
    public private(set) var reveals = 0
    public init() {}

    /// What to do for this arrival, counting it.
    public mutating func next(_ setting: AfterReceive, name: String, isFolder: Bool, at now: Date = Date()) -> AfterReceive {
        guard setting != .nothing else { return .nothing }
        if now.timeIntervalSince(lastArrival) > Self.quiet { opens = 0; reveals = 0 }
        lastArrival = now
        switch ReceiveOptions.action(setting, name: name, isFolder: isFolder, opensSoFar: opens) {
        case .open: opens += 1; return .open
        case .reveal:
            guard reveals < Self.maxRevealsPerBurst else { return .nothing }
            reveals += 1
            return .reveal
        case .nothing: return .nothing
        }
    }
}
