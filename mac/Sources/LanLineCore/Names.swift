import Foundation

public enum Names {
    /// Reduce a peer-supplied file name to a safe base name (PROTOCOL.md "Rules").
    public static func sanitize(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        var s = unified.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let bad = CharacterSet(charactersIn: "<>:\"|?*").union(.controlCharacters)
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !bad.contains($0) }))
        while s.contains("..") { s = s.replacingOccurrences(of: "..", with: ".") }
        s = s.trimmingCharacters(in: .whitespaces)
        while let f = s.first, f == "." || f == " " { s.removeFirst() }
        while let l = s.last, l == "." || l == " " { s.removeLast() }
        if s.count > 200 {
            let ext = (s as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 20 ? "" : "." + ext
            s = String(s.prefix(200 - keep.count)) + keep
        }
        return s.isEmpty ? "file" : s
    }

    /// A name a person can read for a photo or video that came with a machine-made one (beta.11). Photos and the photo
    /// picker sometimes hand over "AE54C04B-B03D-4001-9031-43ABB62B1F37.MP4" or "trim.<id>.MOV"; those become
    /// "Video 2026-11-26 at 10.27.21.MP4" (the time it was shared, in this time zone). A name that looks chosen
    /// (IMG_0042.HEIC, holiday.jpg) is kept as it is. No colons: they aren't allowed in names on the Mac or Windows.
    public static func readableMedia(_ name: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        var stem = ext.isEmpty ? name : ns.deletingPathExtension
        if stem.lowercased().hasPrefix("trim.") { stem = String(stem.dropFirst(5)) }
        guard looksMachineMade(stem) else { return name }
        let videos: Set<String> = ["mov", "mp4", "m4v", "hevc", "avi", "3gp", "mkv", "webm"]
        let photos: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "gif", "tif", "tiff", "webp", "dng", "avif"]
        let kind = videos.contains(ext.lowercased()) ? "Video" : photos.contains(ext.lowercased()) ? "Photo" : nil
        guard let kind else { return name }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(kind) \(f.string(from: date)).\(ext)"
    }

    /// A UUID, or a long run of hex and dashes: nobody typed that.
    static func looksMachineMade(_ stem: String) -> Bool {
        let hexOrDash = stem.allSatisfy { ($0.isASCII && $0.isHexDigit) || $0 == "-" }
        guard hexOrDash else { return false }
        let digits = stem.filter { $0 != "-" }.count
        return digits >= 16
    }

    /// `dir/name`, or `dir/name (2).ext`, `dir/name (3).ext`, ... if it already exists.
    public static func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    /// A peer-supplied path inside a received folder ("/"-separated), as safe components; nil if it is absolute,
    /// empty, has an empty, "." or ".." part or a backslash, or is deeper than 64.
    public static func safePath(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, parts.count <= 64,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { return nil }
        return parts.map(sanitize)
    }
}
