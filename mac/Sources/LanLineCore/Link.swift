import Foundation
import Darwin

/// Events from one WebSocket connection, always delivered on the owning Session's queue.
enum LinkEvent: Sendable {
    case ready
    case text(String)
    case data(Data)
    case closed(String)
}

/// Make a socket non-blocking, SIGPIPE-free and Nagle-free.
private func tune(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func errnoText() -> String { String(cString: strerror(errno)) }

/// One WebSocket connection on a BSD socket (kernel TCP), framed by `WSFrame`/`WSParser`.
/// Confined to the Session queue: every method is called there and every callback runs there.
/// Send completions fire (asynchronously, on the queue) once the frame is fully handed to the kernel.
final class Link: @unchecked Sendable {
    private enum Side { case server, client(host: String, port: UInt16) }

    let queue: DispatchQueue
    let openedAt: Date
    private(set) var peerDescription: String
    private let side: Side
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSuspended = true
    private var connecting = false
    private var handshaken = false
    private var head: [UInt8] = []
    private var clientKey = ""
    private var parser: WSParser
    private var outQ: [(data: Data, offset: Int, done: (@Sendable (Bool) -> Void)?)] = []
    private var handler: (@Sendable (LinkEvent) -> Void)?
    private(set) var isClosed = false
    /// Set once the v2 handshake is done: from then on every message is sealed and plaintext is refused.
    var channel: Channel?

    static let maxMessage = 2 << 20   // well above the 256 KiB chunk size
    private static let readSize = 256 * 1024

    private init(side: Side, fd: Int32, peer: String, queue: DispatchQueue, openedAt: Date) {
        self.side = side; self.fd = fd; self.peerDescription = peer; self.queue = queue; self.openedAt = openedAt
        if case .server = side { parser = WSParser(expectMasked: true, maxMessage: Link.maxMessage) }
        else { parser = WSParser(expectMasked: false, maxMessage: Link.maxMessage) }
    }

    /// A connection the listener accepted; the client's upgrade request comes next.
    static func accepted(fd: Int32, peer: String, queue: DispatchQueue, openedAt: Date) -> Link {
        Link(side: .server, fd: fd, peer: peer, queue: queue, openedAt: openedAt)
    }

    static func dial(host: String, port: UInt16, queue: DispatchQueue, openedAt: Date) -> Link {
        Link(side: .client(host: host, port: port), fd: -1, peer: "\(host):\(port)", queue: queue, openedAt: openedAt)
    }

    /// Hand the link's events to someone else (the Hub routes an accepted link to the right partner's Session).
    func retarget(_ handler: @escaping @Sendable (LinkEvent) -> Void) { if !isClosed { self.handler = handler } }

    func start(_ handler: @escaping @Sendable (LinkEvent) -> Void) {
        self.handler = handler
        switch side {
        case .server: attach()
        case .client(let host, let port): resolveAndConnect(host: host, port: port)
        }
    }

    // MARK: connect (client side)

    private func resolveAndConnect(host: String, port: UInt16) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in   // getaddrinfo can block; the link waits for it
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, String(port), &hints, &res)
            let addr: (family: Int32, bytes: Data)? = (rc == 0 ? res : nil).map {
                ($0.pointee.ai_family, Data(bytes: $0.pointee.ai_addr, count: Int($0.pointee.ai_addrlen)))
            }
            if res != nil { freeaddrinfo(res) }
            let failure = rc == 0 ? nil : String(cString: gai_strerror(rc))
            queue.async { self.connect(addr, failure: failure) }
        }
    }

    private func connect(_ addr: (family: Int32, bytes: Data)?, failure: String?) {
        guard !isClosed else { return }
        guard let addr else { finish("unreachable: \(failure ?? "no address")"); return }
        let s = socket(addr.family, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { finish("socket: \(errnoText())"); return }
        tune(s)
        fd = s
        let rc = addr.bytes.withUnsafeBytes { raw in
            Darwin.connect(s, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(addr.bytes.count))
        }
        if rc != 0 && errno != EINPROGRESS { finish("unreachable: \(errnoText())"); return }
        connecting = true
        attach()
        wantWrite()   // writable = connected (or failed)
    }

    // MARK: sources

    private func attach() {
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        r.setEventHandler { [weak self] in self?.readable() }
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        w.setEventHandler { [weak self] in self?.writable() }
        // close the descriptor only after both sources have let go of it
        let s = fd
        let group = DispatchGroup()
        group.enter(); group.enter()
        r.setCancelHandler { group.leave() }
        w.setCancelHandler { group.leave() }
        group.notify(queue: queue) { Darwin.close(s) }
        readSource = r
        writeSource = w
        r.resume()
        // the write source stays suspended until there is something to write
    }

    private func wantWrite() {
        if writeSuspended, let w = writeSource { writeSuspended = false; w.resume() }
    }

    private func idleWrite() {
        if !writeSuspended, let w = writeSource { writeSuspended = true; w.suspend() }
    }

    // MARK: reading

    private func readable() {
        guard !isClosed else { return }
        var buf = [UInt8](repeating: 0, count: Link.readSize)
        while !isClosed {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, Link.readSize) }
            if n > 0 {
                buf.withUnsafeBytes { incoming(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                if n < Link.readSize { return }     // drained for now
            } else if n == 0 {
                finish("closed by peer"); return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                finish("receive: \(errnoText())"); return
            }
        }
    }

    private func incoming(_ bytes: UnsafeRawBufferPointer) {
        if !handshaken {
            head.append(contentsOf: bytes)
            guard let (lines, rest) = WSHandshake.split(head) else {
                if head.count > 16 * 1024 { finish("handshake too long") }
                return
            }
            head = []
            switch side {
            case .server:
                guard let resp = WSHandshake.respond(to: lines) else {
                    enqueue(Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8), done: nil)
                    finish("not a WebSocket upgrade"); return
                }
                enqueue(Data(resp.utf8), done: nil)
            case .client:
                guard WSHandshake.accepts(lines, key: clientKey) else { finish("handshake refused"); return }
            }
            handshaken = true
            handler?(.ready)
            if !rest.isEmpty, !isClosed { rest.withUnsafeBytes { frames($0) } }
            return
        }
        frames(bytes)
    }

    private func frames(_ bytes: UnsafeRawBufferPointer) {
        let events: [WSEvent]
        do { events = try parser.feed(bytes) } catch let e as WSError {
            close(code: e.code, reason: "protocol error: \(e.description)"); return
        } catch { finish("protocol error"); return }
        for ev in events {
            guard !isClosed else { return }
            switch ev {
            case .text(let s):
                if channel != nil { close(code: 1008, reason: "plaintext after the handshake"); return }
                handler?(.text(s))
            case .binary(let d):
                guard let ch = channel else { handler?(.data(d)); continue }
                guard let (kind, body) = ch.open(d) else { close(code: 1008, reason: "decrypt failed"); return }
                if kind == .chunk { handler?(.data(body)) } else { handler?(.text(String(decoding: body, as: UTF8.self))) }
            case .ping(let p): sendFrame(.pong, p, done: nil)
            case .pong: break
            case .close: close(code: 1000, reason: "closed by peer")
            }
        }
    }

    // MARK: writing

    private var maskKey: UInt32? {
        if case .client = side { return UInt32.random(in: 0...UInt32.max) }
        return nil
    }

    func send(text: String, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        if channel != nil { sendSealed(.control, Data(text.utf8), done: completion) }
        else { sendFrame(.text, Data(text.utf8), done: completion) }
    }

    func send(data: Data, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        if channel != nil { sendSealed(.chunk, data, done: completion) }
        else { sendFrame(.binary, data, done: completion) }
    }

    /// Seal at enqueue time: the write queue is FIFO, so counters reach the wire in order.
    private func sendSealed(_ kind: Channel.Kind, _ payload: Data, done: @escaping @Sendable (Bool) -> Void) {
        guard !isClosed, handshaken, let ch = channel else { queue.async { done(false) }; return }
        guard let sealed = ch.seal(kind, payload) else {
            queue.async { done(false) }
            close("message limit reached; reconnecting for fresh keys")
            return
        }
        sendFrame(.binary, sealed, done: done)
    }

    private func sendFrame(_ op: WSOpcode, _ payload: Data, done: (@Sendable (Bool) -> Void)?) {
        guard !isClosed, handshaken else {
            if let done { queue.async { done(false) } }
            return
        }
        enqueue(WSFrame.encode(op, payload, maskKey: maskKey), done: done)
    }

    private func enqueue(_ d: Data, done: (@Sendable (Bool) -> Void)?) {
        outQ.append((d, 0, done))
        if !connecting { flush() }
    }

    private func writable() {
        guard !isClosed else { return }
        if connecting {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { finish("unreachable: \(String(cString: strerror(err)))"); return }
            connecting = false
            if case .client(let host, let port) = side {
                let (text, key) = WSHandshake.request(host: host, port: port)
                clientKey = key
                outQ.insert((Data(text.utf8), 0, nil), at: 0)
            }
        }
        flush()
    }

    private func flush() {
        while !isClosed, !outQ.isEmpty {
            let (data, offset, done) = outQ[0]
            let n = data.withUnsafeBytes { raw in write(fd, raw.baseAddress! + offset, data.count - offset) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { wantWrite(); return }
                finish("send failed: \(errnoText())"); return
            }
            if offset + n < data.count { outQ[0].offset = offset + n; continue }
            outQ.removeFirst()
            if let done { queue.async { done(true) } }   // async: no recursion through the sender
        }
        if !isClosed { idleWrite() }
    }

    // MARK: closing

    /// Close politely (close frame, best effort), then tear down. Reports `.closed(reason)` once.
    func close(_ reason: String) { close(code: 1000, reason: reason) }

    private func close(code: UInt16, reason: String) {
        guard !isClosed else { return }
        if handshaken, fd >= 0, !connecting {
            let frame = WSFrame.encode(.close, WSFrame.closePayload(code), maskKey: maskKey)
            _ = frame.withUnsafeBytes { write(fd, $0.baseAddress!, frame.count) }   // best effort, non-blocking
        }
        finish(reason)
    }

    private func finish(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        outQ.removeAll()
        if let r = readSource, let w = writeSource {
            if writeSuspended { w.resume(); writeSuspended = false }
            r.cancel(); w.cancel()           // the group closes the fd after both cancel handlers ran
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        readSource = nil; writeSource = nil; fd = -1
        let h = handler
        handler = nil
        h?(.closed(reason))
    }
}

/// A listening TCP socket; each accepted connection becomes a server-side `Link`.
final class SocketListener: @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    let port: UInt16

    /// Bind and listen. `bindHost` nil = all IPv4 interfaces. `port` 0 = any free port.
    init(bindHost: String?, port: UInt16, queue: DispatchQueue,
         onAccept: @escaping @Sendable (Int32, String) -> Void) throws {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = bindHost.map { inet_addr($0) } ?? INADDR_ANY
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(s, 16) == 0 else {
            let e = errno
            Darwin.close(s)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        self.port = UInt16(bigEndian: bound.sin_port)
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler {
            while true {
                var peer = sockaddr_in()
                var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(s, $0, &plen) } }
                if c < 0 { return }   // EAGAIN: no more pending connections
                tune(c)
                let ip = String(cString: inet_ntoa(peer.sin_addr))
                onAccept(c, "\(ip):\(UInt16(bigEndian: peer.sin_port))")
            }
        }
        src.setCancelHandler { Darwin.close(s) }
        source = src
        src.resume()
    }

    func cancel() { source?.cancel(); source = nil }
}
