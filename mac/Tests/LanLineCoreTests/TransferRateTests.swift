import XCTest
@testable import LanLineCore

/// Speed and time left (beta.10); the PC runs the same cases ("transfer rate").
final class TransferRateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testSteadySpeedAndTimeLeft() {
        var r = TransferRate()
        XCTAssertEqual(r.describe(done: 0, total: 100_000_000), "0%")
        r.update(done: 0, at: t0)
        r.update(done: 10_000_000, at: t0 + 1)          // 10 MB/s
        XCTAssertEqual(r.bytesPerSecond, 10_000_000)
        r.update(done: 20_000_000, at: t0 + 2)
        XCTAssertEqual(r.bytesPerSecond, 10_000_000)
        XCTAssertEqual(r.remaining(done: 20_000_000, total: 100_000_000), 8)
        XCTAssertEqual(r.describe(done: 20_000_000, total: 100_000_000), "20% · 10 MB/s · 8 s left")
    }

    func testSmoothingAndNoise() {
        var r = TransferRate()
        r.update(done: 0, at: t0)
        r.update(done: 10_000_000, at: t0 + 1)
        r.update(done: 10_500_000, at: t0 + 1.1)        // under minGap: skipped
        XCTAssertEqual(r.bytesPerSecond, 10_000_000)
        r.update(done: 30_000_000, at: t0 + 2)          // 20 MB/s now → 0.7·10 + 0.3·20 = 13
        XCTAssertEqual(r.bytesPerSecond!, 13_000_000, accuracy: 1)
    }

    func testRestartResets() {
        var r = TransferRate()
        r.update(done: 0, at: t0); r.update(done: 50_000_000, at: t0 + 1)
        r.update(done: 1_000, at: t0 + 2)               // the sender started over
        XCTAssertNil(r.bytesPerSecond)
    }

    func testWording() {
        XCTAssertEqual(TransferRate.timeLeft(3), "a few seconds left")
        XCTAssertEqual(TransferRate.timeLeft(12.4), "12 s left")
        XCTAssertEqual(TransferRate.timeLeft(170), "3 min left")
        XCTAssertEqual(TransferRate.timeLeft(3600), "1 h left")
        XCTAssertEqual(TransferRate.timeLeft(3900), "1 h 5 min left")
        var r = TransferRate()
        r.update(done: 0, at: t0); r.update(done: 1_500_000_000, at: t0 + 1)
        XCTAssertEqual(r.describe(done: 1_500_000_000, total: 3_000_000_000), "50% · 1.5 GB/s · a few seconds left")
    }
}
