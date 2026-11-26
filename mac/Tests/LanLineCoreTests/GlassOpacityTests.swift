import XCTest
@testable import LanLineCore

/// The smoked-glass opacity setting (beta.8): 40–100 %, default = the look before the setting existed.
final class GlassOpacityTests: XCTestCase {
    func testDefaultIsTodaysLook() {
        let s = StorageSettings()
        XCTAssertNil(s.glassOpacity)
        XCTAssertEqual(s.glassOpacityValue, 0.74, accuracy: 1e-9)
        XCTAssertEqual(StorageSettings.tintAlpha(s.glassOpacityValue, dark: true), 0.74, accuracy: 1e-9)
        XCTAssertEqual(StorageSettings.tintAlpha(s.glassOpacityValue, dark: false), 0.80, accuracy: 1e-9)
    }

    func testBlurFadesOnlyBelowTheDefault() {
        XCTAssertEqual(StorageSettings.blurAlpha(StorageSettings.defaultGlassOpacity), 1, accuracy: 1e-9)   // today's look
        XCTAssertEqual(StorageSettings.blurAlpha(1.0), 1, accuracy: 1e-9)
        XCTAssertEqual(StorageSettings.blurAlpha(0.40), 0.35, accuracy: 1e-9)
        XCTAssertLessThan(StorageSettings.blurAlpha(0.50), StorageSettings.blurAlpha(0.60))
        XCTAssertEqual(StorageSettings.blurAlpha(0.1), 0.35, accuracy: 1e-9)   // clamped
    }

    func testClampedToRange() {
        var s = StorageSettings()
        for (v, want) in [(0.1, 0.40), (0.40, 0.40), (0.55, 0.55), (1.0, 1.0), (1.7, 1.0), (-3, 0.40), (.nan, 0.74), (.infinity, 0.74)] {
            s.glassOpacity = v
            XCTAssertEqual(s.glassOpacityValue, want, accuracy: 1e-9, "\(v)")
        }
        XCTAssertEqual(StorageSettings.tintAlpha(1.0, dark: false), 1.0, accuracy: 1e-9)   // never above 1
        XCTAssertEqual(StorageSettings.tintAlpha(0.40, dark: false), 0.46, accuracy: 1e-9)
    }

    func testOldSettingsFileStillLoadsAndValueRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // a beta.7 file: no glassOpacity key
        try #"{"retentionDays":30,"limitGB":10,"overLimit":"warn","trashReminder":true,"confirmed":true}"#.write(to: url, atomically: true, encoding: .utf8)
        var s = StorageSettings.load(from: url)
        XCTAssertEqual(s.retentionDays, 30)
        XCTAssertEqual(s.glassOpacityValue, 0.74, accuracy: 1e-9)
        s.glassOpacity = 0.5
        try s.save(to: url)
        XCTAssertEqual(StorageSettings.load(from: url).glassOpacityValue, 0.5, accuracy: 1e-9)
        XCTAssertEqual(StorageSettings.load(from: url).retentionDays, 30)
    }

    /// Accessibility pass (beta.10): the text size is always one of the choices.
    func testTextScaleSnapsToAChoice() {
        var s = StorageSettings()
        XCTAssertEqual(s.textScaleValue, 1)
        s.textScale = 1.3; XCTAssertEqual(s.textScaleValue, 1.3)
        s.textScale = 1.22; XCTAssertEqual(s.textScaleValue, 1.15)
        s.textScale = 9; XCTAssertEqual(s.textScaleValue, 1.5)
        s.textScale = -3; XCTAssertEqual(s.textScaleValue, 0.9)
        s.textScale = .nan; XCTAssertEqual(s.textScaleValue, 1)
        XCTAssertEqual(StorageSettings.textScaleChoices, [0.9, 1.0, 1.15, 1.3, 1.5])
    }

    /// Design refresh (beta.10): text on the window body gets a scrim only when the window is more see-through
    /// than the default, rising evenly to full strength at the minimum.
    func testScrimStrength() {
        XCTAssertEqual(StorageSettings.scrimStrength(1.0), 0)
        XCTAssertEqual(StorageSettings.scrimStrength(StorageSettings.defaultGlassOpacity), 0)
        XCTAssertEqual(StorageSettings.scrimStrength(0.57), 0.5, accuracy: 1e-9)
        XCTAssertEqual(StorageSettings.scrimStrength(0.40), 1, accuracy: 1e-9)
        XCTAssertEqual(StorageSettings.scrimStrength(0.10), 1, accuracy: 1e-9, "clamped like the setting")
        XCTAssertEqual(StorageSettings.scrimStrength(.nan), 0, "a bad value means the default")
    }
}
