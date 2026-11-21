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
}
