import XCTest
@testable import LanLineCore

/// Writes the two sounds to LANLINE_CHIME_DIR when set (a listening / afinfo check); otherwise does nothing.
final class ChimeDumpTests: XCTestCase {
    func testDump() throws {
        guard let dir = ProcessInfo.processInfo.environment["LANLINE_CHIME_DIR"] else { return }
        try Chime.wav(.arrive).write(to: URL(fileURLWithPath: dir).appendingPathComponent("arrive.wav"))
        try Chime.wav(.sent).write(to: URL(fileURLWithPath: dir).appendingPathComponent("sent.wav"))
    }
}
