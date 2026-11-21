import Foundation

/// One JSON control frame (see PROTOCOL.md). Unused fields stay nil and are left out of the JSON.
public struct Frame: Codable, Sendable, Equatable {
    public var type: String
    public var v: Int?
    public var token: String?
    public var name: String?
    public var id: String?
    public var text: String?
    public var size: Int64?
    public var sha256: String?
    public var ok: Bool?
    public var err: String?
    /// In `hello_ok` right after pairing: the long-term secret that replaces the short pairing code.
    public var rekey: String?

    public init(type: String, v: Int? = nil, token: String? = nil, name: String? = nil, id: String? = nil,
                text: String? = nil, size: Int64? = nil, sha256: String? = nil, ok: Bool? = nil, err: String? = nil,
                rekey: String? = nil) {
        self.type = type; self.v = v; self.token = token; self.name = name; self.id = id
        self.text = text; self.size = size; self.sha256 = sha256; self.ok = ok; self.err = err; self.rekey = rekey
    }

    public static let protocolVersion = 1

    /// `rekey: "?"` in a hello says "I can take a new long-term secret" (0.9.0-beta.2 and later).
    public static func hello(token: String, name: String) -> Frame { Frame(type: "hello", v: protocolVersion, token: token, name: name, rekey: "?") }
    public static func helloOK(name: String, rekey: String? = nil) -> Frame { Frame(type: "hello_ok", name: name, rekey: rekey) }
    public static func text(id: String, text: String) -> Frame { Frame(type: "text", id: id, text: text) }
    public static func fileBegin(id: String, name: String, size: Int64, sha256: String) -> Frame {
        Frame(type: "file_begin", name: name, id: id, size: size, sha256: sha256)
    }
    public static func fileEnd(id: String) -> Frame { Frame(type: "file_end", id: id) }
    public static func ack(id: String, ok: Bool, err: String? = nil) -> Frame { Frame(type: "ack", id: id, ok: ok, err: err) }
    public static let beat = Frame(type: "beat")

    public var json: String {
        // Encoding a struct of strings, numbers and bools cannot fail.
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public static func decode(_ s: String) -> Frame? {
        try? JSONDecoder().decode(Frame.self, from: Data(s.utf8))
    }
}
