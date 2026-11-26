import XCTest
@testable import LanLineCore

/// The QR pairing link (beta.10); the PC runs the same cases ("pair link").
final class PairLinkTests: XCTestCase {
    /// The iPhone asks before pairing from a link, and warns when the link points outside a local network.
    func testLocalNetworkAddresses() {
        for h in ["192.168.1.42", "10.0.0.5", "172.16.0.1", "172.31.255.254", "169.254.10.10", "100.100.50.7", "127.0.0.1"] {
            XCTAssertTrue(PairLink.isLocalNetworkAddress(h), h)
        }
        for h in ["8.8.8.8", "203.0.113.5", "172.32.0.1", "172.15.0.1", "100.63.0.1", "100.128.0.1", "192.169.1.1", "1.2.3", "example.com", ""] {
            XCTAssertFalse(PairLink.isLocalNetworkAddress(h), h)
        }
        XCTAssertTrue(PairLink(code: "ABCDE12345", name: "PC", port: 47830, hosts: ["192.168.1.42", "100.100.50.7"]).isLocal)
        XCTAssertFalse(PairLink(code: "ABCDE12345", name: "PC", port: 47830, hosts: ["192.168.1.42", "203.0.113.5"]).isLocal)
    }

    func testRoundTrip() {
        let l = PairLink(code: "7QK4M2XH9C", name: "Studio PC", port: 47830, hosts: ["192.168.1.20", "100.64.0.5"])
        XCTAssertEqual(l.url, "lanline://pair?v=1&c=7QK4M2XH9C&n=Studio%20PC&p=47830&h=192.168.1.20,100.64.0.5")
        XCTAssertEqual(PairLink.parse(l.url), l)
        XCTAssertEqual(PairLink.parse("lanline://pair?v=1&c=7qk4m-2xh9c&n=Mac&p=47830&h=10.0.0.2")?.code, "7QK4M2XH9C", "typed forms normalise")
        let odd = PairLink(code: "7QK4M2XH9C", name: "Mac & PC = ✓", port: 1, hosts: ["10.0.0.2"])
        XCTAssertEqual(odd.url, "lanline://pair?v=1&c=7QK4M2XH9C&n=Mac%20%26%20PC%20%3D%20%E2%9C%93&p=1&h=10.0.0.2", "the same as .NET's EscapeDataString")
        XCTAssertEqual(PairLink.parse(odd.url)?.name, "Mac & PC = ✓")
    }

    func testRefusals() {
        for bad in ["https://pair?v=1&c=7QK4M2XH9C&p=1&h=10.0.0.2", "lanline://stage?v=1&c=7QK4M2XH9C&p=1&h=10.0.0.2",
                    "lanline://pair?v=2&c=7QK4M2XH9C&p=47830&h=10.0.0.2", "lanline://pair?v=1&c=SHORT&p=47830&h=10.0.0.2",
                    "lanline://pair?v=1&c=7QK4M2XH9C&p=0&h=10.0.0.2", "lanline://pair?v=1&c=7QK4M2XH9C&p=47830&h=evil.example.com",
                    "lanline://pair?v=1&c=7QK4M2XH9C&p=47830", ""] {
            XCTAssertNil(PairLink.parse(bad), bad)
        }
        XCTAssertEqual(PairLink.parse("lanline://pair?v=1&c=7QK4M2XH9C&p=47830&h=10.0.0.2,evil,10.0.0.3")?.hosts, ["10.0.0.2", "10.0.0.3"])
        XCTAssertEqual(PairLink.parse("lanline://pair?v=1&c=7QK4M2XH9C&p=47830&h=10.0.0.2")?.name, "Computer")
    }
}
