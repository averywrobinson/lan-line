import XCTest
@testable import LanLineCore

final class TourTests: XCTestCase {
    func testThreeCardsPerPlatformWithTheSameIds() {
        for p in [Tour.Platform.mac, .windows, .iphone] {
            let cards = Tour.cards(p)
            XCTAssertEqual(cards.map(\.id), ["send", "anywhere", "close"])
            for c in cards {
                XCTAssertFalse(c.title.isEmpty); XCTAssertLessThanOrEqual(c.title.count, 28, c.title)
                XCTAssertGreaterThan(c.body.count, 40); XCTAssertLessThanOrEqual(c.body.count, 190, c.body)
                XCTAssertTrue(c.body.hasSuffix("."), c.body)
            }
            XCTAssertEqual(Tour.hints(p).map(\.id), ["type", "drop", "share"])
            XCTAssertTrue(Tour.hints(p).allSatisfy { !$0.text.isEmpty && $0.text.count <= 48 && !$0.text.hasSuffix(".") })
        }
        XCTAssertEqual(Tour.cards(.mac)[0].title, Tour.cards(.windows)[0].title)
        XCTAssertTrue(Tour.cards(.mac)[0].body.contains("Return")); XCTAssertTrue(Tour.cards(.windows)[0].body.contains("Enter"))
        XCTAssertTrue(Tour.cards(.mac)[2].body.contains("menu bar")); XCTAssertTrue(Tour.cards(.windows)[2].body.contains("notification area"))
    }

    func testShownOnceOnANewInstallOnly() {
        XCTAssertTrue(Tour.shouldShow(seen: nil, paired: true, settingsConfirmed: true))
        XCTAssertFalse(Tour.shouldShow(seen: nil, paired: false, settingsConfirmed: true), "not before pairing")
        XCTAssertFalse(Tour.shouldShow(seen: nil, paired: true, settingsConfirmed: false), "not before the first-run settings")
        XCTAssertFalse(Tour.shouldShow(seen: true, paired: true, settingsConfirmed: true), "once")
        XCTAssertEqual(Tour.seenAtLaunch(saved: nil, alreadyPaired: true), true, "paired before the tour existed: not owed")
        XCTAssertNil(Tour.seenAtLaunch(saved: nil, alreadyPaired: false), "a new install still gets it")
        XCTAssertEqual(Tour.seenAtLaunch(saved: true, alreadyPaired: false), true)
    }
}
