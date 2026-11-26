import XCTest
import CryptoKit
@testable import LanLineCore

/// The sounds and when they play (beta.10); the PC runs the same cases ("sounds").
final class ChimeTests: XCTestCase {
    func testWavShape() {
        let a = Chime.wav(.arrive), s = Chime.wav(.sent)
        XCTAssertEqual(String(decoding: a.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: a[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(Chime.samples(.arrive).count, 18_742)   // 425 ms at 44.1 kHz (whole samples)
        XCTAssertEqual(Chime.samples(.sent).count, 3_087)
        XCTAssertEqual(a.count, 44 + 18_742 * 2)
        XCTAssertEqual(s.count, 44 + 3_087 * 2)
        // byte-identical with the Windows app (its "sounds" test pins the same hashes)
        XCTAssertEqual(Data(SHA256.hash(data: a)).hex, "cb7ee53dac2a1d3b409a8dc5be032dd6a230b818ab13093fdd13ae14ae38ae9d")
        XCTAssertEqual(Data(SHA256.hash(data: s)).hex, "18714b8a51eaf264c45d2a601cdcddf0453662fbe81ae5c3596539f310fea352")
    }

    func testLoudnessAndFades() {
        let a = Chime.samples(.arrive), s = Chime.samples(.sent)
        let peakA = a.map { abs(Int($0)) }.max()!, peakS = s.map { abs(Int($0)) }.max()!
        XCTAssertTrue((8_000...16_000).contains(peakA), "soft, never clipping: \(peakA)")
        XCTAssertLessThan(peakS, peakA / 2, "the send tick is quieter")
        XCTAssertEqual(a.first, 0, "starts silent (fade-in)")
        XCTAssertLessThan(abs(Int(a.last!)), 300, "ends faded out")
    }

    func testGate() {
        var g = SoundGate(); let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(g.arrive(soundsOn: true, notificationShown: false, at: t))
        XCTAssertFalse(g.arrive(soundsOn: true, notificationShown: false, at: t + 1), "one chime per burst")
        XCTAssertTrue(g.arrive(soundsOn: true, notificationShown: false, at: t + 2))
        XCTAssertFalse(g.arrive(soundsOn: true, notificationShown: true, at: t + 10), "the notification plays its own")
        XCTAssertFalse(g.arrive(soundsOn: false, notificationShown: false, at: t + 20))
        XCTAssertTrue(StorageSettings().soundsValue)
    }
}
