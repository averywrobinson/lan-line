import XCTest
@testable import LanLineCore

/// Global shortcuts and the shortcut list (beta.10); the PC runs the same cases ("shortcuts").
final class ShortcutTests: XCTestCase {
    func testParseAndText() {
        XCTAssertEqual(Shortcut("ctrl+alt+L"), Shortcut(ctrl: true, alt: true, key: "L"))
        XCTAssertEqual(Shortcut("Alt + Ctrl + l")?.text, "ctrl+alt+L", "any order and case in, fixed order out")
        XCTAssertEqual(Shortcut("cmd+shift+space")?.text, "shift+cmd+Space")
        XCTAssertEqual(Shortcut("ctrl+f12")?.key, "F12")
        for bad in ["", "ctrl+alt", "ctrl+L+K", "ctrl+Enter", "ctrl+F13", "hyper+L", "ctrl+é"] { XCTAssertNil(Shortcut(bad), bad) }
    }

    func testDisplay() {
        let s = Shortcut(ctrl: true, alt: true, shift: true, key: "V")
        XCTAssertEqual(s.display(mac: true), "⌃⌥⇧V")
        XCTAssertEqual(s.display(mac: false), "Ctrl+Alt+Shift+V")
        XCTAssertEqual(Shortcut(cmd: true, key: "Space").display(mac: true), "⌘Space")
    }

    func testProblems() {
        XCTAssertNil(Shortcut.defaultShow.problem(mac: true))
        XCTAssertNil(Shortcut.defaultShow.problem(mac: false))
        XCTAssertNotNil(Shortcut(shift: true, key: "L").problem(mac: true), "shift alone catches typing")
        XCTAssertNotNil(Shortcut(key: "F5").problem(mac: false))
        XCTAssertEqual(Shortcut(cmd: true, key: "Q").problem(mac: true), "⌘Q is used by every app.")
        XCTAssertEqual(Shortcut(ctrl: true, key: "C").problem(mac: false), "Ctrl+C is used by every app.")
        XCTAssertEqual(Shortcut(cmd: true, key: "L").problem(mac: false), "Windows has no ⌘ key.")
        XCTAssertNotNil(Shortcut(ctrl: true, key: "Space").problem(mac: true))
        XCTAssertNotNil(Shortcut(alt: true, key: "F4").problem(mac: false))
        XCTAssertNil(Shortcut(ctrl: true, key: "C").problem(mac: true), "⌃C is free on a Mac")
    }

    func testSettingsDefaults() throws {
        var s = StorageSettings()
        XCTAssertEqual(s.showShortcut, .defaultShow)
        XCTAssertNil(s.sendShortcut, "off until chosen")
        s.shortcutShow = ""; s.shortcutSend = "ctrl+alt+V"
        XCTAssertNil(s.showShortcut, "turned off")
        XCTAssertEqual(s.sendShortcut, .suggestedSend)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try s.save(to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"shortcutSend\" : \"ctrl+alt+V\"") && json.contains("\"shortcutShow\" : \"\""))
        XCTAssertNil(StorageSettings.load(from: url).showShortcut)
    }

    func testHelpRows() {
        let mac = KeyboardHelp.rows(mac: true, show: .defaultShow, send: nil)
        let win = KeyboardHelp.rows(mac: false, show: .defaultShow, send: nil)
        XCTAssertEqual(mac.map(\.section), ["Anywhere", "Sending", "Items", "Window"])
        XCTAssertEqual(mac.map(\.rows.count), win.map(\.rows.count), "the same list on both")
        XCTAssertEqual(mac[0].rows[0].keys, "⌃⌥L"); XCTAssertEqual(win[0].rows[0].keys, "Ctrl+Alt+L")
        XCTAssertEqual(mac[0].rows[1].keys, "Off (Settings)")
        XCTAssertEqual(mac.flatMap(\.rows).count, 19)
    }
}
