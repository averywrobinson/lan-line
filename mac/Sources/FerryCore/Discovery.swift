import Foundation
import Darwin

/// A Lan-Line found on the local network.
public struct DiscoveredPeer: Sendable, Equatable, Hashable {
    public let name: String
    public let host: String
    public let port: UInt16
    public let pairID: String

    public init(name: String, host: String, port: UInt16, pairID: String) {
        self.name = name; self.host = host; self.port = port; self.pairID = pairID
    }
}

/// UDP discovery on the Lan-Line port: a waiting computer answers `LANLINE?1` with its name, TCP port
/// and pair id. It reveals nothing secret; the code is still needed to connect.
public enum Discovery {
    public static let probe = "LANLINE?1"

    public static func reply(name: String, port: UInt16, pairID: String) -> Data {
        let obj: [String: Any] = ["lanline": 1, "name": String(name.prefix(64)), "port": Int(port), "pair": pairID]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public static func parse(_ data: Data, from host: String) -> DiscoveredPeer? {
        guard data.count < 1024,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["lanline"] as? Int) == 1,
              let name = o["name"] as? String, let port = o["port"] as? Int, (1...65535).contains(port),
              let pair = o["pair"] as? String else { return nil }
        return DiscoveredPeer(name: String(name.prefix(64)), host: host, port: UInt16(port), pairID: String(pair.prefix(16)))
    }

    /// This computer's IPv4 addresses worth showing (up, not loopback, not link-local), LAN ones first.
    public static func localAddresses() -> [String] {
        interfaces().map(\.addr).sorted { rank($0) < rank($1) }
    }

    /// Broadcast a probe and collect answers for `timeout` seconds. `targets` overrides the broadcast
    /// addresses (tests use 127.0.0.1). The completion runs on `queue`.
    public static func search(port: UInt16 = FerryConfig.defaultPort, timeout: TimeInterval = 1.2,
                              targets: [String]? = nil, queue: DispatchQueue,
                              completion: @escaping @Sendable ([DiscoveredPeer]) -> Void) {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { queue.async { completion([]) }; return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        let dests = targets ?? (["255.255.255.255"] + interfaces().compactMap(\.broadcast))
        let msg = Array(probe.utf8)
        for d in Set(dests) {
            var a = sockaddr_in.make(host: d, port: port)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(s, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        let box = PeerBox()
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 1024)
            while true {
                var from = sockaddr_in()
                var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(s, &buf, buf.count, 0, $0, &flen) } }
                if n <= 0 { return }
                let host = String(cString: inet_ntoa(from.sin_addr))
                if let p = parse(Data(buf[0..<n]), from: host), !box.peers.contains(p) { box.peers.append(p) }
            }
        }
        src.setCancelHandler { Darwin.close(s) }
        src.resume()
        queue.asyncAfter(deadline: .now() + timeout) {
            src.cancel()
            completion(box.peers)
        }
    }

    private final class PeerBox: @unchecked Sendable { var peers: [DiscoveredPeer] = [] }   // queue-confined

    private static func rank(_ a: String) -> Int {
        if a.hasPrefix("192.168.") || a.hasPrefix("10.") { return 0 }
        if a.hasPrefix("172.") { return 1 }
        if a.hasPrefix("100.") { return 3 }   // CGNAT / Tailscale: works, but not "the LAN"
        return 2
    }

    struct Interface { let addr: String; let broadcast: String? }

    static func interfaces() -> [Interface] {
        var out: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            if addr.hasPrefix("169.254.") { continue }
            var bcast: String?
            if i.ifa_flags & UInt32(IFF_BROADCAST) != 0, let b = i.ifa_dstaddr {
                bcast = b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            }
            if !out.contains(where: { $0.addr == addr }) { out.append(Interface(addr: addr, broadcast: bcast)) }
        }
        return out
    }
}

/// Answers discovery probes while this computer waits for its partner. Close it when done.
public final class DiscoveryResponder: @unchecked Sendable {
    private var source: DispatchSourceRead?

    public init(port: UInt16 = FerryConfig.defaultPort, name: String, pairID: String, queue: DispatchQueue) throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in.make(host: nil, port: port)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        let answer = Array(Discovery.reply(name: name, port: port, pairID: pairID))
        let probe = Array(Discovery.probe.utf8)
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 64)
            while true {
                var from = sockaddr_in()
                var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(s, &buf, buf.count, 0, $0, &flen) } }
                if n <= 0 { return }
                guard Array(buf[0..<n]) == probe else { continue }
                _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, answer, answer.count, 0, $0, flen) } }
            }
        }
        src.setCancelHandler { Darwin.close(s) }
        source = src
        src.resume()
    }

    public func close() { source?.cancel(); source = nil }
    deinit { source?.cancel() }
}

extension sockaddr_in {
    static func make(host: String?, port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = host.map { inet_addr($0) } ?? INADDR_ANY
        return a
    }
}
