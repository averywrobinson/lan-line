import AppKit
import LanLineCore

/// One-click update on the Mac (beta.10). Install fetches the signed update.json, downloads the DMG it names
/// and checks its size and SHA-256, copies Lan-Line.app out of it next to the running copy, checks that copy's
/// bundle id and version, then quits; a small helper swaps the two apps once Lan-Line has exited and opens the
/// new one. If anything fails, the running app stays as it was and the notice offers the release page instead.
enum MacUpdater {
    enum Step: Equatable { case checking, downloading(Double), installing, failed(String) }

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lan-Line/update", isDirectory: true)
    }

    /// Why this copy can't replace itself (nil = it can).
    static func blocker(app: URL = Bundle.main.bundleURL) -> String? {
        guard app.pathExtension == "app" else { return "this isn't an installed app" }
        if app.path.contains("/AppTranslocation/") { return "macOS is running it from a temporary place; move Lan-Line to Applications first" }
        if app.path.hasPrefix("/Volumes/") { return "it's running from the disk image; drag it to Applications first" }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            return "the folder it's in can't be changed without an administrator"
        }
        return nil
    }

    /// Download and check; returns the staged new app beside the running one.
    static func prepare(_ offer: SignedUpdate.Offer, current: String, app: URL = Bundle.main.bundleURL,
                        progress: @escaping @Sendable (Double) -> Void) async -> Result<URL, UpdateError> {
        if let b = blocker(app: app) { return .failure(.install(b)) }
        let dmg: URL
        switch await SignedUpdate.download(offer, current: current, into: cacheDir, progress: progress) {
        case .success(let u): dmg = u
        case .failure(let e): return .failure(e)
        }
        return await Task.detached { stage(dmg: dmg, version: offer.version, beside: app) }.value
    }

    /// Mount the DMG read-only (no Finder window), copy the app out, unmount, check the copy.
    nonisolated static func stage(dmg: URL, version: LanLineVersion, beside app: URL) -> Result<URL, UpdateError> {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path, dmg.path]) == 0 else {
            return .failure(.install("the disk image wouldn't open"))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]); try? FileManager.default.removeItem(at: mount) }
        let src = mount.appendingPathComponent("Lan-Line.app")
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Lan-Line-update.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [src.path, staged.path]) == 0 else { return .failure(.install("couldn't copy the new app")) }
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        let id = info?["CFBundleIdentifier"] as? String, full = info?["LanLineVersion"] as? String
        guard id == (Bundle.main.bundleIdentifier ?? "com.avery.lan-line"), full == version.description else {
            try? FileManager.default.removeItem(at: staged)
            return .failure(.install("the new app isn't Lan-Line \(version)"))
        }
        return .success(staged)
    }

    /// Start the helper that waits for this process to exit, swaps the apps (restoring the old one if the move
    /// fails) and opens the result. The caller quits right after.
    nonisolated static func swapAfterExit(staged: URL, app: URL = Bundle.main.bundleURL, pid: Int32 = ProcessInfo.processInfo.processIdentifier, reopen: Bool = true) -> Bool {
        let script = """
        pid=$1; app=$2; new=$3; old="$2.old-$$"
        for i in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if mv "$app" "$old"; then
          if mv "$new" "$app"; then rm -rf "$old"; else mv "$old" "$app"; fi
        fi
        [ "$4" = 1 ] && open "$app"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "lan-line-update", "\(pid)", app.path, staged.path, reopen ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch { return false }
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
