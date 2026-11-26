import XCTest
@testable import LanLineCore

final class PairingBookTests: XCTestCase {
    private func book(_ peers: [Partner] = []) -> PairingBook { PairingBook(config: DeviceConfig(deviceID: "device-self", peers: peers)) }
    private let existing = Partner(id: "device-pc01", name: "STUDIO-PC", secret: Secrets.newToken(), role: "connect", hosts: ["10.0.0.2"])

    /// The beta.7 bug: peerDevice renames the pairing partner, then `.connected` arrives with the OLD id.
    func testConnectedWithOldIdAfterRenameFinishesPairing() {
        var b = book([existing])
        b.begin(Partner(id: "pairing-1", name: "New computer", secret: "ABCDE12345", role: "listen", hosts: []))
        let r1 = b.handle(.peerDevice(partner: "pairing-1", device: "device-m3m3"))
        XCTAssertEqual(r1.effects, [.hubRename("pairing-1", "device-m3m3"), .renamedLocally("pairing-1", "device-m3m3")])
        let r2 = b.handle(.connected(partner: "pairing-1", name: "M3 MacBook"))   // late, old id
        XCTAssertEqual(r2.event, .connected(partner: "device-m3m3", name: "M3 MacBook"))
        guard case .finished(let p)? = r2.effects.last else { return XCTFail("pairing did not finish: \(r2.effects)") }
        XCTAssertEqual(p.id, "device-m3m3"); XCTAssertEqual(p.name, "M3 MacBook")
        XCTAssertTrue(r2.effects.contains(.save))
        XCTAssertNil(b.pending)
        XCTAssertEqual(b.config.peers.map(\.id), ["device-pc01", "device-m3m3"], "the existing partner stays, the new one is saved")
    }

    func testConnectedBeforePeerDeviceAlsoWorks() {
        var b = book()
        b.begin(Partner(id: "pairing-1", name: "x", secret: "ABCDE12345", role: "connect", hosts: ["10.0.0.9"]))
        let r1 = b.handle(.connected(partner: "pairing-1", name: "Intel Mac"))
        XCTAssertTrue(r1.effects.contains { if case .finished = $0 { return true }; return false })
        let r2 = b.handle(.peerDevice(partner: "pairing-1", device: "device-intel"))
        XCTAssertTrue(r2.effects.contains(.save))
        XCTAssertEqual(b.config.peers.map(\.id), ["device-intel"])
    }

    /// The pairing code is swapped for a long-term secret; that event may also carry the old id.
    func testLateRekeyWithOldIdReachesRenamedPartner() {
        var b = book()
        b.begin(Partner(id: "pairing-1", name: "x", secret: "ABCDE12345", role: "listen", hosts: []))
        _ = b.handle(.peerDevice(partner: "pairing-1", device: "device-m3m3"))
        let tok = Secrets.newToken()
        _ = b.handle(.rekeyed(partner: "pairing-1", token: tok))   // before connected: goes to pending
        _ = b.handle(.connected(partner: "pairing-1", name: "M3"))
        XCTAssertEqual(b.config.partner("device-m3m3")?.secret, tok)
        let tok2 = Secrets.newToken()
        let r = b.handle(.rekeyed(partner: "pairing-1", token: tok2))   // after: goes to the saved partner
        XCTAssertTrue(r.effects.contains(.save))
        XCTAssertEqual(b.config.partner("device-m3m3")?.secret, tok2)
    }

    /// Pairing the same computer again replaces the old pairing: the old Session goes before the rename.
    func testRePairingSameComputerReplacesIt() {
        var b = book([existing])
        b.begin(Partner(id: "pairing-2", name: "x", secret: "ZZZZZ99999", role: "listen", hosts: []))
        let r = b.handle(.peerDevice(partner: "pairing-2", device: "device-pc01"))
        XCTAssertEqual(r.effects.first, .hubRemove("device-pc01"))
        XCTAssertTrue(r.effects.contains(.hubRename("pairing-2", "device-pc01")))
        _ = b.handle(.connected(partner: "pairing-2", name: "STUDIO-PC"))
        XCTAssertEqual(b.config.peers.count, 1)
        XCTAssertEqual(b.config.peers[0].id, "device-pc01"); XCTAssertEqual(b.config.peers[0].secret, "ZZZZZ99999")
        XCTAssertEqual(b.config.peers[0].role, "listen")
    }

    /// A migrated beta.6 partner ("legacy-…") learns its device id; its later events map over, nothing "finishes".
    func testLegacyPartnerLearnsDeviceID() {
        var b = book([Partner(id: "legacy-abcd1234", name: "PC", secret: Secrets.newToken(), role: "connect", hosts: ["10.0.0.2"])])
        let r1 = b.handle(.peerDevice(partner: "legacy-abcd1234", device: "device-pc01"))
        XCTAssertTrue(r1.effects.contains(.save))
        let r2 = b.handle(.connected(partner: "legacy-abcd1234", name: "PC"))
        XCTAssertEqual(r2.event, .connected(partner: "device-pc01", name: "PC"))
        XCTAssertFalse(r2.effects.contains { if case .finished = $0 { return true }; return false })
        let r3 = b.handle(.disconnected(partner: "legacy-abcd1234", reason: "x"))
        XCTAssertEqual(r3.event, .disconnected(partner: "device-pc01", reason: "x"))
        XCTAssertEqual(b.config.peers.map(\.id), ["device-pc01"])
    }

    func testForgetAndCancel() {
        var b = book([existing])
        XCTAssertEqual(b.forget("device-pc01"), [.save, .hubRemove("device-pc01")])
        XCTAssertTrue(b.config.peers.isEmpty)
        b.begin(Partner(id: "pairing-9", name: "x", secret: "ABCDE12345", role: "listen", hosts: []))
        XCTAssertEqual(b.cancel(), "pairing-9")
        XCTAssertNil(b.pending)
    }

    /// End to end with real Hubs and the same delivery the window uses: Hub events hop to another queue (like the
    /// main thread) and renames go back to the Hub asynchronously. Before the fix this never finished.
    func testPairingThroughHubsWithAsyncDelivery() async throws {
        let ra = HubRecorder(), rd = HubRecorder()
        let main = DispatchQueue(label: "fake-main")
        let state = BookBox(PairingBook(config: DeviceConfig(deviceID: "device-aaaa", peers: [])))
        let hubARef = HubRef()
        hubARef.hub = Hub(config: hubConfig("A", device: "device-aaaa"), partners: []) { e in
            main.async {
                let (ev, fx) = state.handle(e)
                ra.add(ev)
                for f in fx { if case .hubRename(let o, let n) = f { hubARef.hub.rename(partner: o, to: n) }; if case .hubRemove(let id) = f { DispatchQueue.global().async { hubARef.hub.remove(id) } } }
            }
        }
        let hubA = hubARef.hub!
        hubA.start(); defer { hubA.stop() }
        let code = "PAIRM31234"
        let pending = Partner(id: "pairing-x", name: "New computer", secret: code, role: "listen", hosts: [])
        main.sync { state.begin(pending) }
        hubA.add(pending, pairing: true)
        await waitUntil(5, "A listening") { ra.port != nil || hubA.boundPort != nil }
        let port = hubA.boundPort!
        let d = Hub(config: hubConfig("D", device: "device-m3m3"), partners: [
            Partner(id: "pairing-y", name: "A", secret: code, role: "connect", hosts: ["127.0.0.1"], port: port)]) { rd.add($0) }
        d.start(); defer { d.stop() }
        await waitUntil(10, "pairing finished and saved") { main.sync { state.book.pending == nil && state.book.config.partner("device-m3m3") != nil } }
        let saved = try XCTUnwrap(main.sync { state.book.config.partner("device-m3m3") })
        XCTAssertEqual(saved.secret.count, 64, "the long-term secret, not the code")
        // after the rename, the link keeps working under the new id
        let t = d.send(text: "hello A", to: nil)
        await waitUntil(5, "text arrives as from device-m3m3") { ra.received(from: "device-m3m3").count == 1 }
        await waitUntil(5, "delivered") { rd.last(t.id)?.summary == .delivered }
    }
}

/// The iPhone companion's path (beta.10): no partners yet, a QR pairing link, `book.begin` + `hub.add` (as
/// PhoneModel.pair does), the pairing saved with the long-term secret, then a send after `reconnect()` (the phone
/// coming back to the front).
final class PhonePairingTests: XCTestCase {
    func testQRLinkPairsAndSurvivesReconnect() async throws {
        let main = DispatchQueue(label: "fake-main")
        let desk = BookBox(PairingBook(config: DeviceConfig(deviceID: "device-desk1", peers: [])))
        let rDesk = HubRecorder()
        let hubDeskRef = HubRef()
        hubDeskRef.hub = Hub(config: hubConfig("Desk", device: "device-desk1"), partners: []) { e in
            main.async {
                let (ev, fx) = desk.handle(e); rDesk.add(ev)
                for f in fx { if case .hubRename(let o, let n) = f { hubDeskRef.hub.rename(partner: o, to: n) } }
            }
        }
        let hubDesk = hubDeskRef.hub!
        hubDesk.start(); defer { hubDesk.stop() }
        let code = PairCode.generate()
        let pending = Partner(id: "pairing-desk", name: "New computer", secret: code, role: "listen", hosts: [])
        main.sync { desk.begin(pending) }
        hubDesk.add(pending, pairing: true)
        await waitUntil(5, "desk listening") { hubDesk.boundPort != nil }
        // what the desk's QR code says, as the phone reads it
        let link = try XCTUnwrap(PairLink.parse(PairLink(code: code, name: "Desk", port: hubDesk.boundPort!, hosts: ["127.0.0.1"]).url))

        let phone = BookBox(PairingBook(config: DeviceConfig(deviceID: "device-phone1", peers: [])))
        let rPhone = HubRecorder()
        let hubPhoneRef = HubRef()
        hubPhoneRef.hub = Hub(config: hubConfig("iPhone", device: "device-phone1"), partners: []) { e in
            main.async {
                let (ev, fx) = phone.handle(e); rPhone.add(ev)
                for f in fx { if case .hubRename(let o, let n) = f { hubPhoneRef.hub.rename(partner: o, to: n) } }
            }
        }
        let hubPhone = hubPhoneRef.hub!
        hubPhone.start(); defer { hubPhone.stop() }
        let p = Partner(id: "pairing-q", name: link.name, secret: link.code, role: "connect", hosts: link.hosts, port: link.port)
        main.sync { phone.begin(p) }
        hubPhone.add(p, pairing: false)
        await waitUntil(10, "both sides saved the pairing") {
            main.sync { phone.book.pending == nil && phone.book.config.partner("device-desk1") != nil && desk.book.config.partner("device-phone1") != nil }
        }
        XCTAssertEqual(main.sync { phone.book.config.partner("device-desk1")?.secret.count }, 64, "the long-term secret, not the code")
        let t1 = hubPhone.send(text: "from the phone", to: nil)
        await waitUntil(5, "first text") { rPhone.last(t1.id)?.summary == .delivered }
        hubPhone.reconnect()   // back in front after the background
        let t2 = hubPhone.send(text: "after reconnect", to: nil)
        await waitUntil(10, "second text after the reconnect") { rPhone.last(t2.id)?.summary == .delivered }
        XCTAssertEqual(rDesk.received(from: "device-phone1").count, 2)
    }
}

/// A hub the event closure can reach before `Hub(...)` returns.
final class HubRef: @unchecked Sendable { var hub: Hub! }

/// The book plus the window's queue confinement, for the async test.
final class BookBox: @unchecked Sendable {
    var book: PairingBook
    init(_ b: PairingBook) { book = b }
    func begin(_ p: Partner) { book.begin(p) }
    func handle(_ e: HubEvent) -> (HubEvent, [PairingBook.Effect]) { book.handle(e) }
}
