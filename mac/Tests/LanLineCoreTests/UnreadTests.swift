import XCTest
@testable import LanLineCore

/// The unread badge (beta.10); the PC runs the same cases ("unread badge").
final class UnreadTests: XCTestCase {
    func testCountsOnlyWhatArrivedUnseen() {
        var u = Unread()
        XCTAssertNil(u.badge); XCTAssertNil(u.phrase)
        u.arrived(inUse: true)
        XCTAssertEqual(u.count, 0)
        u.arrived(inUse: false); u.arrived(inUse: false)
        XCTAssertEqual(u.badge, "2"); XCTAssertEqual(u.phrase, "2 new")
        u.seen()
        XCTAssertEqual(u, Unread())
    }

    func testCapsAt99Plus() {
        var u = Unread()
        for _ in 0..<99 { u.arrived(inUse: false) }
        XCTAssertEqual(u.badge, "99")
        u.arrived(inUse: false)
        XCTAssertEqual(u.badge, "99+"); XCTAssertEqual(u.phrase, "99+ new")
    }
}
