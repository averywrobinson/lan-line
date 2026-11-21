import Foundation

/// A Lan-Line version: `MAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH-beta.N`, parsed strictly (no "v", no spaces,
/// no leading zeros, at most 6 digits per number). A release sorts after every beta of the same number.
public struct LanLineVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public let beta: Int?

    public init?(_ s: String) {
        guard s.count <= 32, s.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        let main: Substring, b: Substring?
        if let dash = s.firstIndex(of: "-") {
            main = s[..<dash]
            let rest = s[s.index(after: dash)...]
            guard rest.hasPrefix("beta.") else { return nil }
            b = rest.dropFirst(5)
        } else { main = Substring(s); b = nil }
        func num(_ t: Substring) -> Int? {
            guard !t.isEmpty, t.count <= 6, t.allSatisfy({ $0.isASCII && $0.isNumber }), t == "0" || t.first != "0" else { return nil }
            return Int(t)
        }
        let parts = main.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let x = num(parts[0]), let y = num(parts[1]), let z = num(parts[2]) else { return nil }
        if let b { guard let n = num(b) else { return nil }; beta = n } else { beta = nil }
        major = x; minor = y; patch = z
    }

    public var description: String { "\(major).\(minor).\(patch)" + (beta.map { "-beta.\($0)" } ?? "") }

    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.beta, b.beta) {
        case let (x?, y?): return x < y
        case (_?, nil): return true      // a beta comes before its release
        default: return false
        }
    }
}

/// Update notices. Lan-Line never downloads or installs anything: it only shows a link to the release page.
/// The only network call is `fetchLatest`, and only when the user asks (or turned on the daily check).
public enum Updates {
    /// The one file the update check fetches: `{version, released, url, notes_url}`.
    public static let versionURL = URL(string: "https://averywrobinson.com/lan-line/version.json")!
    static let allowedPrefixes = ["https://averywrobinson.com/lan-line/", "https://github.com/averywrobinson/lan-line/"]

    public struct Available: Sendable, Equatable {
        public let version: LanLineVersion
        public let url: String
        public init(version: LanLineVersion, url: String) { self.version = version; self.url = url }
    }

    public enum CheckResult: Sendable, Equatable {
        case upToDate(LanLineVersion)
        case available(Available)
        case failed
    }

    /// Only Lan-Line's own pages, so a peer or a tampered file can't make the window show an arbitrary link.
    public static func isAllowedURL(_ s: String) -> Bool {
        guard s.count <= 300, let prefix = allowedPrefixes.first(where: { s.hasPrefix($0) }) else { return false }
        let rest = s.dropFirst(prefix.count)
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-~/#")
        return rest.allSatisfy { ok.contains($0) } && !rest.contains("..") && !rest.contains("//") && !rest.hasPrefix("/")
    }

    public static func releasePage(_ v: LanLineVersion) -> String { "https://github.com/averywrobinson/lan-line/releases/tag/v\(v)" }

    /// A version.json body → what it announces, or nil if anything about it is off.
    public static func parse(versionJSON d: Data) -> Available? {
        struct File: Decodable { let version: String; let url: String }
        guard d.count <= 64 * 1024, let f = try? JSONDecoder().decode(File.self, from: d),
              let v = LanLineVersion(f.version), isAllowedURL(f.url) else { return nil }
        return Available(version: v, url: f.url)
    }

    /// Fetch version.json: one GET, no cookies, no query string, user agent "Lan-Line/<version>". Never throws.
    public static func fetchLatest(current: String, from url: URL = versionURL) async -> CheckResult {
        guard let own = LanLineVersion(current) else { return .failed }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("Lan-Line/\(current)", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let a = parse(versionJSON: data) else { return .failed }
        return a.version > own ? .available(a) : .upToDate(own)
    }

    /// What the window says after a check. Automatic checks stay quiet unless there is something new.
    public static func message(_ r: CheckResult, manual: Bool) -> String? {
        switch r {
        case .available(let a): return "Lan-Line \(a.version) is available"
        case .upToDate(let v): return manual ? "Lan-Line \(v) is up to date" : nil
        case .failed: return manual ? "Couldn't check for updates. Try again later." : nil
        }
    }

    /// The daily check runs only if the user turned it on, at most once a day.
    public static func dueForAutoCheck(_ s: StorageSettings, now: Date) -> Bool {
        guard s.autoUpdateCheck == true else { return false }
        guard let last = s.lastUpdateCheck else { return true }
        return now.timeIntervalSince(last) >= 24 * 3600
    }
}
