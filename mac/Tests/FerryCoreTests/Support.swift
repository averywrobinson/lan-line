import Foundation
import XCTest
@testable import FerryCore

/// Thread-safe event log for one Session.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SessionEvent] = []
    /// Runs on the session queue for every event (tests use it to act at an exact moment).
    var hook: (@Sendable (SessionEvent) -> Void)?
    func add(_ e: SessionEvent) { lock.lock(); events.append(e); let h = hook; lock.unlock(); h?(e) }
    var all: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return events }

    var port: UInt16? {
        for case .listening(let p) in all { return p }
        return nil
    }
    var connectedCount: Int { all.filter { if case .connected = $0 { return true }; return false }.count }
    var disconnects: [String] { all.compactMap { if case .disconnected(let r) = $0 { return r }; return nil } }
    var received: [Item] { all.compactMap { if case .received(let i) = $0 { return i }; return nil } }
    func lastState(_ id: String) -> ItemState? {
        for case .outgoing(let i) in all.reversed() where i.id == id { return i.state }
        return nil
    }
    var receiveFailures: [String] { all.compactMap { if case .receiveFailed(_, let r) = $0 { return r }; return nil } }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

let testToken = String(repeating: "ab", count: 32)

func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-test-\(tag)-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func makeConfig(_ tag: String, fast: Bool = true) -> SessionConfig {
    var c = SessionConfig(token: testToken, name: tag, downloadDir: tempDir(tag))
    if fast { c.backoff = [0.2, 0.4]; c.dialTimeout = 2 }
    return c
}

/// Poll until `cond` is true or the timeout passes.
func waitUntil(_ timeout: TimeInterval = 10, _ what: String = "condition", _ cond: () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

/// A listener on 127.0.0.1 with an ephemeral port.
func startListener(_ tag: String, config: SessionConfig? = nil, clock: FakeClock? = nil) async -> (Session, Recorder, UInt16) {
    let rec = Recorder()
    let cfg = config ?? makeConfig(tag)
    let s: Session
    if let clock {
        s = Session(role: .listener(port: 0, bindHost: "127.0.0.1"), config: cfg, clock: { clock.now() }) { rec.add($0) }
    } else {
        s = Session(role: .listener(port: 0, bindHost: "127.0.0.1"), config: cfg) { rec.add($0) }
    }
    s.start()
    await waitUntil(5, "listening") { rec.port != nil }
    return (s, rec, rec.port ?? 0)
}

func startDialer(_ tag: String, port: UInt16, config: SessionConfig? = nil) -> (Session, Recorder) {
    let rec = Recorder()
    let s = Session(role: .dialer(hosts: ["127.0.0.1"], port: port), config: config ?? makeConfig(tag)) { rec.add($0) }
    s.start()
    return (s, rec)
}

/// A raw protocol client on URLSessionWebSocketTask, independent of Network.framework.
final class RawClient: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(port: UInt16) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ferry")!)
        task.maximumMessageSize = 4 << 20
        task.resume()
    }
    func send(_ f: Frame) async throws { try await task.send(.string(f.json)) }
    func send(_ d: Data) async throws { try await task.send(.data(d)) }
    /// Next control frame, or nil if the socket closed.
    func next(timeout: TimeInterval = 5) async -> Frame? {
        await withTaskGroup(of: Frame?.self) { g in
            g.addTask {
                guard let m = try? await self.task.receive() else { return nil }
                if case .string(let s) = m { return Frame.decode(s) }
                return Frame(type: "binary")
            }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); return Frame(type: "timeout") }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
    /// Next frame that is not a beat.
    func nextNonBeat(timeout: TimeInterval = 5) async -> Frame? {
        while true {
            let f = await next(timeout: timeout)
            if f?.type != "beat" { return f }
        }
    }
    func hello(token: String = testToken) async throws -> Frame? {
        try await send(.hello(token: token, name: "raw"))
        return await nextNonBeat()
    }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

func randomFile(_ dir: URL, name: String, bytes: Int) throws -> URL {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    var left = bytes
    var g = SystemRandomNumberGenerator()
    while left > 0 {
        let n = min(left, 1 << 20)
        var d = Data(count: n)
        d.withUnsafeMutableBytes { buf in
            let words = buf.bindMemory(to: UInt64.self)
            for i in 0..<words.count { words[i] = g.next() }
        }
        try h.write(contentsOf: d)
        left -= n
    }
    try h.close()
    return url
}
