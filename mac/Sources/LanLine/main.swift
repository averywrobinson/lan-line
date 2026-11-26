import AppKit
import LanLineCore

// Lan-Line entry point.
//   Lan-Line                        the window (listens on the config port)
//   Lan-Line --headless [--echo]     no window; prints events as JSON lines
//   Lan-Line --selftest              sends a text and a random file to an echo peer and checks they come back
//   Lan-Line --discover              lists Lan-Lines waiting on the network (JSON lines), then exits
//   Lan-Line --respond CODE          answers discovery probes as a computer showing CODE (until killed)
// Common options: --listen | --connect HOST[,HOST]  --port N  --config PATH  --downloads DIR  --name NAME
//   --size MB (selftest file, default 50)  --timeout S (selftest, default 180)  --duration S (headless: exit after S)

let options = Options(CommandLine.arguments.dropFirst())

if options.flag("--discover") {
    let port = options.value("--port").flatMap(UInt16.init) ?? LanLineConfig.defaultPort
    Discovery.search(port: port, timeout: 2, queue: .main) { peers in
        for p in peers { print("{\"found\":\"\(p.name)\",\"host\":\"\(p.host)\",\"port\":\(p.port),\"pair\":\"\(p.pairID)\"}") }
        print("{\"event\":\"discover_done\",\"count\":\(peers.count)}")
        exit(0)
    }
    dispatchMain()
}
if let code = options.value("--respond") {
    let port = options.value("--port").flatMap(UInt16.init) ?? LanLineConfig.defaultPort
    let r = try DiscoveryResponder(port: port, name: options.name, pairID: PairCode.pairID(token: code), queue: .main)
    print("{\"event\":\"responding\",\"pair\":\"\(PairCode.pairID(token: code))\"}")
    withExtendedLifetime(r) { dispatchMain() }
}

// --update-test MANIFEST BASE APP: the one-click update without the swap into this app (beta.10 tests).
// Verifies MANIFEST (a signed update.json file, built-in key) as 0.9.0-beta.10, downloads the Mac file from BASE
// (a local server standing in for GitHub), checks it, stages it beside APP (a dummy .app), and swaps it in after
// a stand-in process exits. Prints one JSON line per step.
if options.flag("--update-test") {
    let a = Array(CommandLine.arguments.drop { $0 != "--update-test" }.dropFirst().prefix(3))
    guard a.count == 3, let data = try? Data(contentsOf: URL(fileURLWithPath: a[0])),
          let offer = SignedUpdate.verify(data, current: LanLineVersion("0.9.0-beta.10")!, platform: .mac) else { print("{\"step\":\"verify\",\"ok\":false}"); exit(1) }
    print("{\"step\":\"verify\",\"ok\":true,\"version\":\"\(offer.version)\"}")
    let file = URL(string: offer.asset.url)!.lastPathComponent
    let local = SignedUpdate.Offer(version: offer.version, asset: .init(url: a[1] + "/" + file, size: offer.asset.size, sha256: offer.asset.sha256), notesURL: nil)
    let app = URL(fileURLWithPath: a[2])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lan-line-update-test-\(UUID().uuidString)")
        switch await SignedUpdate.download(local, current: "0.9.0-beta.10", into: dir) {
        case .failure(let e): print("{\"step\":\"download\",\"ok\":false,\"why\":\"\(e)\"}"); exit(1)
        case .success(let dmg):
            print("{\"step\":\"download\",\"ok\":true}")
            switch MacUpdater.stage(dmg: dmg, version: offer.version, beside: app) {
            case .failure(let e): print("{\"step\":\"stage\",\"ok\":false,\"why\":\"\(e)\"}"); exit(1)
            case .success(let staged):
                print("{\"step\":\"stage\",\"ok\":true}")
                let stand = Process(); stand.executableURL = URL(fileURLWithPath: "/bin/sleep"); stand.arguments = ["1"]
                try? stand.run()
                let started = MacUpdater.swapAfterExit(staged: staged, app: app, pid: stand.processIdentifier, reopen: false)
                print("{\"step\":\"swap-started\",\"ok\":\(started)}")
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// --check-updates [URL]: run the update check once (default: the real version.json), print the outcome, exit.
if options.flag("--check-updates") {
    let arg = CommandLine.arguments.drop { $0 != "--check-updates" }.dropFirst().first
    let url = arg.flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil } ?? Updates.versionURL
    let current = options.value("--app-version") ?? AppInfo.version
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let r = await Updates.fetchLatest(current: current, from: url)
        let line: String
        switch r {
        case .available(let a): line = "available \(a.version) \(a.url)"
        case .upToDate(let v): line = "up-to-date \(v)"
        case .failed: line = "failed"
        }
        print(line)
        done.signal()
    }
    done.wait()
    exit(0)
}
if options.flag("--hub"), options.flag("--headless") || options.flag("--selftest") {
    HubHeadless.run(options)   // never returns
}
if options.flag("--headless") || options.flag("--selftest") {
    Headless.run(options)   // never returns
}

// --render-menubar PATH: the four menu bar icon states (apart/joined, without/with the unread dot) side by side on
// a light and a dark strip, 4x, then exit. Design checks without opening a window.
if let out = options.value("--render-menubar") {
    MainActor.assumeIsolated {
        let states = [(false, false), (true, false), (false, true), (true, true)]
        let scale: CGFloat = 4, cell = NSSize(width: 44, height: 24)
        let img = NSImage(size: NSSize(width: cell.width * 4 * scale, height: cell.height * 2 * scale), flipped: false) { _ in
            for (row, dark) in [false, true].enumerated() {
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: CGFloat(row) * cell.height * scale, width: cell.width * 4 * scale, height: cell.height * scale).fill()
                for (i, st) in states.enumerated() {
                    let icon = MenuBarItem.icon(connected: st.0, unread: st.1)
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r); (dark ? NSColor.white : NSColor.black).set(); r.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: (CGFloat(i) * cell.width + (cell.width - icon.size.width) / 2) * scale,
                                           y: (CGFloat(row) * cell.height + (cell.height - icon.size.height) / 2) * scale,
                                           width: icon.size.width * scale, height: icon.size.height * scale))
                }
            }
            return true
        }
        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let controller = AppController(options: options)
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
