import AppKit
import FerryCore

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
    let port = options.value("--port").flatMap(UInt16.init) ?? FerryConfig.defaultPort
    Discovery.search(port: port, timeout: 2, queue: .main) { peers in
        for p in peers { print("{\"found\":\"\(p.name)\",\"host\":\"\(p.host)\",\"port\":\(p.port),\"pair\":\"\(p.pairID)\"}") }
        print("{\"event\":\"discover_done\",\"count\":\(peers.count)}")
        exit(0)
    }
    dispatchMain()
}
if let code = options.value("--respond") {
    let port = options.value("--port").flatMap(UInt16.init) ?? FerryConfig.defaultPort
    let r = try DiscoveryResponder(port: port, name: options.name, pairID: PairCode.pairID(token: code), queue: .main)
    print("{\"event\":\"responding\",\"pair\":\"\(PairCode.pairID(token: code))\"}")
    withExtendedLifetime(r) { dispatchMain() }
}

if options.flag("--headless") || options.flag("--selftest") {
    Headless.run(options)   // never returns
}

let app = NSApplication.shared
let controller = AppController(options: options)
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
