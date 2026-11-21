import Foundation
import CryptoKit

// A small RFC 6455 WebSocket codec, used because Network.framework measured ~0.5 MB/s Mac → Windows PC on our
// test LAN while BSD sockets on the same path ran at 300+ MB/s.
// Scope: no extensions, no subprotocols. Tested against URLSessionWebSocketTask and .NET's WebSocket.

enum WSOpcode: UInt8, Sendable {
    case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
}

enum WSEvent: Equatable, Sendable {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(code: UInt16?)
}

struct WSError: Error, Equatable, CustomStringConvertible {
    let code: UInt16        // close code to send back (1002 protocol, 1007 bad UTF-8, 1009 too big)
    let description: String
}

/// XOR `bytes` with the 4-byte mask key, 8 bytes at a time (the mask is applied to every client frame).
func wsApplyMask(_ bytes: UnsafeMutableRawBufferPointer, _ k: [UInt8]) {
    let n = bytes.count
    guard n > 0, let base = bytes.baseAddress else { return }
    var k8: UInt64 = 0
    withUnsafeMutableBytes(of: &k8) { w in for i in 0..<8 { w[i] = k[i & 3] } }
    var i = 0
    while i + 8 <= n {
        let v = base.loadUnaligned(fromByteOffset: i, as: UInt64.self)
        base.storeBytes(of: v ^ k8, toByteOffset: i, as: UInt64.self)
        i += 8
    }
    while i < n { bytes[i] ^= k[i & 3]; i += 1 }
}

enum WSFrame {
    /// Encode one complete (FIN) frame. Clients must pass a mask key; servers must not.
    static func encode(_ op: WSOpcode, _ payload: Data, maskKey: UInt32? = nil) -> Data {
        var out = Data(capacity: payload.count + 14)
        out.append(0x80 | op.rawValue)
        let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
        let n = payload.count
        if n < 126 {
            out.append(maskBit | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) }
        }
        guard let key = maskKey else { out.append(payload); return out }
        let k = [UInt8((key >> 24) & 0xFF), UInt8((key >> 16) & 0xFF), UInt8((key >> 8) & 0xFF), UInt8(key & 0xFF)]
        out.append(contentsOf: k)
        let start = out.count
        out.append(payload)
        out.withUnsafeMutableBytes { raw in wsApplyMask(UnsafeMutableRawBufferPointer(rebasing: raw[start...]), k) }
        return out
    }

    static func closePayload(_ code: UInt16) -> Data { Data([UInt8(code >> 8), UInt8(code & 0xFF)]) }

    /// Sec-WebSocket-Accept for a Sec-WebSocket-Key (RFC 6455 §4.2.2).
    static func acceptKey(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
}

/// Incremental frame parser. Feed it bytes as they arrive; it returns whole messages and control frames.
struct WSParser {
    let expectMasked: Bool      // true on the server side: every client frame must be masked
    let maxMessage: Int
    private var buf: [UInt8] = []
    private var pos = 0
    private var fragOp: WSOpcode?
    private var frag = Data()

    init(expectMasked: Bool, maxMessage: Int) { self.expectMasked = expectMasked; self.maxMessage = maxMessage }

    mutating func feed(_ bytes: UnsafeRawBufferPointer) throws -> [WSEvent] {
        buf.append(contentsOf: bytes)
        return try drain()
    }

    mutating func feed(_ d: Data) throws -> [WSEvent] {
        try d.withUnsafeBytes { try feed($0) }
    }

    private mutating func drain() throws -> [WSEvent] {
        var events: [WSEvent] = []
        while true {
            let avail = buf.count - pos
            guard avail >= 2 else { break }
            let b0 = buf[pos], b1 = buf[pos + 1]
            let fin = b0 & 0x80 != 0
            guard b0 & 0x70 == 0 else { throw WSError(code: 1002, description: "reserved bits set") }
            guard let op = WSOpcode(rawValue: b0 & 0x0F) else { throw WSError(code: 1002, description: "unknown opcode \(b0 & 0x0F)") }
            let masked = b1 & 0x80 != 0
            guard masked == expectMasked else {
                throw WSError(code: 1002, description: masked ? "masked frame from server" : "unmasked frame from client")
            }
            var len = Int(b1 & 0x7F)
            var head = 2
            if len == 126 {
                guard avail >= 4 else { break }
                len = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3])
                head = 4
            } else if len == 127 {
                guard avail >= 10 else { break }
                var v: UInt64 = 0
                for i in 0..<8 { v = v << 8 | UInt64(buf[pos + 2 + i]) }
                guard v >> 63 == 0, v <= UInt64(maxMessage) else { throw WSError(code: 1009, description: "frame too big") }
                len = Int(v)
                head = 10
            }
            if op.rawValue >= 8 {
                guard fin, len <= 125 else { throw WSError(code: 1002, description: "bad control frame") }
            }
            guard len <= maxMessage else { throw WSError(code: 1009, description: "frame too big") }
            let maskLen = masked ? 4 : 0
            guard avail >= head + maskLen + len else { break }
            let payloadStart = pos + head + maskLen
            var payload = Data(buf[payloadStart..<(payloadStart + len)])
            if masked {
                let k = Array(buf[(pos + head)..<(pos + head + 4)])
                payload.withUnsafeMutableBytes { wsApplyMask($0, k) }
            }
            pos = payloadStart + len

            switch op {
            case .ping: events.append(.ping(payload))
            case .pong: events.append(.pong(payload))
            case .close:
                let code = payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil
                events.append(.close(code: code))
            case .text, .binary:
                guard fragOp == nil else { throw WSError(code: 1002, description: "new message inside a fragmented one") }
                if fin { events.append(try message(op, payload)) } else { fragOp = op; frag = payload }
            case .continuation:
                guard let fop = fragOp else { throw WSError(code: 1002, description: "continuation without a start") }
                guard frag.count + payload.count <= maxMessage else { throw WSError(code: 1009, description: "message too big") }
                frag.append(payload)
                if fin {
                    let whole = frag
                    fragOp = nil; frag = Data()
                    events.append(try message(fop, whole))
                }
            }
        }
        if pos > 0 && (pos == buf.count || pos > 1 << 20) {   // drop consumed bytes now and then
            buf.removeFirst(pos)
            pos = 0
        }
        return events
    }

    private func message(_ op: WSOpcode, _ payload: Data) throws -> WSEvent {
        if op == .binary { return .binary(payload) }
        guard let s = String(data: payload, encoding: .utf8) else { throw WSError(code: 1007, description: "text is not UTF-8") }
        return .text(s)
    }
}

/// The HTTP/1.1 upgrade exchange.
enum WSHandshake {
    /// Split a header block ending in CRLFCRLF. Returns nil until the block is complete.
    static func split(_ bytes: [UInt8]) -> (lines: [String], rest: [UInt8])? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            let head = String(decoding: bytes[0..<i], as: UTF8.self)
            return (head.components(separatedBy: "\r\n"), Array(bytes[(i + 4)...]))
        }
        return nil
    }

    static func headers(_ lines: [String]) -> [String: String] {
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            h[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return h
    }

    /// Server: validate a client's request; returns the 101 response, or nil if it isn't a WebSocket upgrade.
    static func respond(to lines: [String]) -> String? {
        guard let first = lines.first, first.hasPrefix("GET ") else { return nil }
        let h = headers(lines)
        guard h["upgrade"]?.lowercased().contains("websocket") == true,
              h["connection"]?.lowercased().contains("upgrade") == true,
              h["sec-websocket-version"] == "13",
              let key = h["sec-websocket-key"], !key.isEmpty else { return nil }
        return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WSFrame.acceptKey(for: key))\r\n\r\n"
    }

    /// Client: the request, plus the key whose accept value the server must echo.
    static func request(host: String, port: UInt16) -> (text: String, key: String) {
        var raw = [UInt8](repeating: 0, count: 16)
        for i in raw.indices { raw[i] = UInt8.random(in: 0...255) }
        let key = Data(raw).base64EncodedString()
        let text = "GET /lan-line HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        return (text, key)
    }

    /// Client: check the server's answer.
    static func accepts(_ lines: [String], key: String) -> Bool {
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 101") else { return false }
        return headers(lines)["sec-websocket-accept"] == WSFrame.acceptKey(for: key)
    }
}
