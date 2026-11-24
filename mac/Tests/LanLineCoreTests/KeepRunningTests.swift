import XCTest
@testable import LanLineCore

/// "Keep running in the menu bar when closed" (beta.9): on unless the user turns it off; older files read as on.
final class KeepRunningTests: XCTestCase {
    func testOnByDefault() {
        let s = StorageSettings()
        XCTAssertNil(s.keepRunningWhenClosed)
        XCTAssertTrue(s.keepRunningWhenClosedValue)
    }

    func testOldFileReadsAsOnAndOffRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // a beta.8 file: no keepRunningWhenClosed key
        try #"{"retentionDays":0,"limitGB":10,"overLimit":"warn","trashReminder":true,"confirmed":true,"glassOpacity":0.5}"#
            .write(to: url, atomically: true, encoding: .utf8)
        var s = StorageSettings.load(from: url)
        XCTAssertTrue(s.keepRunningWhenClosedValue)
        XCTAssertEqual(s.glassOpacityValue, 0.5, accuracy: 1e-9)
        s.keepRunningWhenClosed = false
        try s.save(to: url)
        XCTAssertFalse(StorageSettings.load(from: url).keepRunningWhenClosedValue)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"keepRunningWhenClosed\" : false"))   // same key as Windows
    }

    func testWindowsOnlyKeysAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"retentionDays":5,"limitGB":10,"overLimit":"warn","trashReminder":true,"confirmed":true,"keepRunningWhenClosed":true,"trayHintShown":true}"#.write(to: url, atomically: true, encoding: .utf8)
        let s = StorageSettings.load(from: url)
        XCTAssertEqual(s.retentionDays, 5)
        XCTAssertTrue(s.keepRunningWhenClosedValue)
    }
}
