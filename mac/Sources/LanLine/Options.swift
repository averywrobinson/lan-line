import Foundation
import FerryCore

struct Options: Sendable {
    let args: [String]
    init<S: Sequence>(_ a: S) where S.Element == String { args = Array(a) }

    func flag(_ f: String) -> Bool { args.contains(f) }
    func value(_ f: String) -> String? {
        guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var configURL: URL { value("--config").map { URL(fileURLWithPath: $0) } ?? FerryConfig.defaultURL }

    func loadConfig() -> FerryConfig {
        let url = configURL
        do { return try FerryConfig.load(from: url) } catch {
            FileHandle.standardError.write(Data("ferry: cannot read config \(url.path): \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    var name: String { value("--name") ?? (Host.current().localizedName ?? "Mac") }

    func role(_ cfg: FerryConfig) -> Role {
        let port = value("--port").flatMap(UInt16.init) ?? cfg.port
        if let hosts = value("--connect") {
            return .dialer(hosts: hosts.split(separator: ",").map(String.init), port: port)
        }
        if cfg.connects { return .dialer(hosts: cfg.hosts ?? [], port: port) }
        return .listener(port: port, bindHost: value("--bind"))
    }
}
