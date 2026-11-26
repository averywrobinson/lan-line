import Foundation

/// The window's bookkeeping for paired computers, kept out of the UI so it can be tested (beta.8 fix).
///
/// A partner's id changes once: from a placeholder ("pairing-…", "legacy-…") to its real device id, when its
/// hello says so (`.peerDevice`). The Hub's events are delivered asynchronously, so events already on their way
/// still carry the old id. Every event therefore goes through `resolve`, which follows old → new ids; a pairing
/// in progress finishes on `.connected` whichever id that event carries.
public struct PairingBook: Sendable {
    public private(set) var config: DeviceConfig
    /// The computer being paired right now (shown on the pairing screen), not saved until it connects.
    public private(set) var pending: Partner?
    private var aliases: [String: String] = [:]

    /// What the app must do after an event, in this order.
    public enum Effect: Sendable, Equatable {
        case save                               // write config.json
        case hubRemove(String)                  // stop that partner's Session (an older pairing with the same computer)
        case hubRename(String, String)          // re-key a partner by its device id
        case finished(Partner)                  // the pairing in progress connected and is saved
        case renamedLocally(String, String)     // the window's list should follow (old id, new id)
    }

    public init(config: DeviceConfig) { self.config = config }

    /// The current id for an id seen in an event (follows any chain of renames).
    public func resolve(_ id: String) -> String {
        var cur = id, hops = 0
        while let next = aliases[cur], hops < 16 { cur = next; hops += 1 }
        return cur
    }

    public mutating func begin(_ p: Partner) { pending = p }

    /// Cancel the pairing in progress; returns its id (the caller removes it from the Hub).
    public mutating func cancel() -> String? {
        defer { pending = nil }
        return pending?.id
    }

    public mutating func forget(_ id: String) -> [Effect] {
        let cur = resolve(id)
        config.forget(cur)
        return [.save, .hubRemove(cur)]
    }

    public mutating func rename(_ id: String, to name: String) -> [Effect] {
        config.rename(resolve(id), to: name)
        return [.save]
    }

    /// Bring an event's partner ids up to date and apply what it means for the saved list.
    public mutating func handle(_ event: HubEvent) -> (event: HubEvent, effects: [Effect]) {
        let e = mapped(event)
        var fx: [Effect] = []
        switch e {
        case .peerDevice(let p, let d) where p != d && Session.isDeviceID(d):
            // An older pairing with this same computer is replaced by this one.
            if let old = config.peers.first(where: { $0.id == d }) {
                config.forget(old.id)
                fx += [.hubRemove(old.id)]
            }
            if pending?.id == p { pending?.id = d }
            if let i = config.peers.firstIndex(where: { $0.id == p }) { config.peers[i].id = d; fx.append(.save) }
            aliases[p] = d
            fx += [.hubRename(p, d), .renamedLocally(p, d)]
            return (.peerDevice(partner: d, device: d), fx)
        case .connected(let p, let name):
            if var q = pending, q.id == p {
                q.name = name
                pending = nil
                do { try config.add(q) } catch { return (e, fx) }
                fx += [.save, .finished(q)]
            } else if let i = config.peers.firstIndex(where: { $0.id == p }), config.peers[i].name != name {
                config.peers[i].name = name
                fx.append(.save)
            }
        case .rekeyed(let p, let t):
            if pending?.id == p { pending?.secret = t }
            else if let i = config.peers.firstIndex(where: { $0.id == p }) { config.peers[i].secret = t; fx.append(.save) }
        case .peerAddresses(let p, let a):
            if let i = config.peers.firstIndex(where: { $0.id == p }), config.peers[i].connects {
                let hosts = config.peers[i].hosts
                var out: [String] = []
                let ordered = (a.first.map { hosts.first != $0 } ?? false) ? a + hosts : hosts + a   // a moved partner's new address first
                for x in ordered where !out.contains(x) { out.append(x) }
                out = Array(out.prefix(6))
                if out != hosts { config.peers[i].hosts = out; fx.append(.save) }
            }
        default: break
        }
        return (e, fx)
    }

    private func mapped(_ e: HubEvent) -> HubEvent {
        switch e {
        case .connected(let p, let n): return .connected(partner: resolve(p), name: n)
        case .disconnected(let p, let r): return .disconnected(partner: resolve(p), reason: r)
        case .received(let p, let i): return .received(partner: resolve(p), i)
        case .incoming(let p, let i): return .incoming(partner: resolve(p), i)
        case .clipboard(let p, let c): return .clipboard(partner: resolve(p), c)
        case .receiveFailed(let p, let n, let r, let i): return .receiveFailed(partner: resolve(p), name: n, reason: r, id: i)
        case .status(let p, let s): return .status(partner: p.isEmpty ? p : resolve(p), s)
        case .rekeyed(let p, let t): return .rekeyed(partner: resolve(p), token: t)
        case .peerAddresses(let p, let a): return .peerAddresses(partner: resolve(p), a)
        case .peerDevice(let p, let d): return .peerDevice(partner: resolve(p), device: d)
        case .outgoing(let h):
            let to = h.to.map(resolve)
            var states: [String: ItemState] = [:]
            for (k, v) in h.states { states[resolve(k)] = v }
            return .outgoing(HubItem(id: h.id, kind: h.kind, to: to, states: states))
        case .listening, .updateAvailable, .error: return e
        }
    }
}
