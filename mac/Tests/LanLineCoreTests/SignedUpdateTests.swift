import XCTest
import CryptoKit
@testable import LanLineCore

final class SignedUpdateTests: XCTestCase {
    let key = P256.Signing.PrivateKey()
    var pub: String { key.publicKey.rawRepresentation.base64EncodedString() }
    let cur = LanLineVersion("0.9.0-beta.10")!
    let dl = "https://github.com/averywrobinson/lan-line/releases/download/"

    func payload(_ v: String = "0.9.0-beta.11", macURL: String? = nil, size: Int64 = 1234, hash: String = String(repeating: "a", count: 64)) -> SignedUpdate.Payload {
        SignedUpdate.Payload(version: v,
                             mac: .init(url: macURL ?? "\(dl)v\(v)/Lan-Line-\(v)-mac.dmg", size: size, sha256: hash),
                             windows: .init(url: "\(dl)v\(v)/Lan-Line-\(v)-windows-setup.exe", size: size, sha256: hash),
                             notes_url: "https://github.com/averywrobinson/lan-line/releases/tag/v\(v)")
    }

    func testGoodManifestGivesThePlatformsFile() throws {
        let d = try SignedUpdate.sign(payload(), privateKey: key)
        let m = try XCTUnwrap(SignedUpdate.verify(d, current: cur, platform: .mac, key: pub))
        XCTAssertEqual(m.version.description, "0.9.0-beta.11")
        XCTAssertTrue(m.asset.url.hasSuffix("-mac.dmg"))
        XCTAssertTrue(try XCTUnwrap(SignedUpdate.verify(d, current: cur, platform: .windows, key: pub)).asset.url.hasSuffix("-setup.exe"))
    }

    func testRefusals() throws {
        let other = P256.Signing.PrivateKey()
        XCTAssertNil(SignedUpdate.verify(try SignedUpdate.sign(payload(), privateKey: other), current: cur, platform: .mac, key: pub), "wrong key")
        XCTAssertNil(SignedUpdate.verify(try SignedUpdate.sign(payload("0.9.0-beta.10"), privateKey: key), current: cur, platform: .mac, key: pub), "same version")
        XCTAssertNil(SignedUpdate.verify(try SignedUpdate.sign(payload("0.9.0-beta.9"), privateKey: key), current: cur, platform: .mac, key: pub), "older")
        for bad in ["https://evil.example/x.dmg", "\(dl)v0.9.0-beta.12/x.dmg", "\(dl)v0.9.0-beta.11/../x.dmg", "\(dl)v0.9.0-beta.11/a b.dmg", "\(dl)v0.9.0-beta.11/"] {
            XCTAssertNil(SignedUpdate.verify(try SignedUpdate.sign(payload(macURL: bad), privateKey: key), current: cur, platform: .mac, key: pub), bad)
        }
        XCTAssertNil(SignedUpdate.verify(try SignedUpdate.sign(payload(hash: "xyz"), privateKey: key), current: cur, platform: .mac, key: pub), "hash")
        XCTAssertNil(SignedUpdate.verify(try SignedUpdate.sign(payload(size: 0), privateKey: key), current: cur, platform: .mac, key: pub), "size")
        // a payload changed after signing
        var env = try JSONSerialization.jsonObject(with: try SignedUpdate.sign(payload(), privateKey: key)) as! [String: String]
        var body = Data(base64Encoded: env["payload"]!)!
        body = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "1234", with: "1235").utf8)
        env["payload"] = body.base64EncodedString()
        XCTAssertNil(SignedUpdate.verify(try JSONSerialization.data(withJSONObject: env), current: cur, platform: .mac, key: pub), "tampered")
    }

    func testDownloadedFileMustMatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("x.dmg"); try Data("hello".utf8).write(to: f)
        let good = SignedUpdate.Asset(url: "", size: 5, sha256: Hashing.sha256Hex(Data("hello".utf8)))
        XCTAssertTrue(SignedUpdate.matches(f, good))
        XCTAssertFalse(SignedUpdate.matches(f, .init(url: "", size: 6, sha256: good.sha256)))
        XCTAssertFalse(SignedUpdate.matches(f, .init(url: "", size: 5, sha256: String(repeating: "0", count: 64))))
    }

    /// The release tool's output (written by tools/update-sign.swift with the real key) verifies with the built-in key.
    func testFixtureFromReleaseToolVerifies() throws {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/update-fixture.json")
        let d = try Data(contentsOf: u)
        let m = try XCTUnwrap(SignedUpdate.verify(d, current: LanLineVersion("0.9.0-beta.10")!, platform: .windows))
        XCTAssertEqual(m.version.description, "0.9.0-beta.99")
        XCTAssertEqual(m.asset.size, 5)
    }
}
