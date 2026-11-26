import Foundation

/// Lan-Line's two small sounds (beta.10), made in code so both apps sound the same and ship no audio files:
/// `arrive`, two soft notes rising (A5 → E6), and `sent`, one short quiet tick. 16-bit mono PCM WAV, 44.1 kHz.
/// The same recipe as `Chime` in LanLine.Core; the tests pin the length, the header and the loudness.
public enum Chime {
    public enum Kind: Sendable { case arrive, sent }
    public static let sampleRate = 44_100

    /// Times in whole milliseconds, so both platforms get exactly the same number of samples.
    struct Note { let hz: Double; let startMs: Int; let lengthMs: Int; let level: Double }

    static func notes(_ k: Kind) -> [Note] {
        switch k {
        case .arrive: return [Note(hz: 880, startMs: 0, lengthMs: 160, level: 0.32), Note(hz: 1318.51, startMs: 85, lengthMs: 340, level: 0.30)]
        case .sent: return [Note(hz: 1567.98, startMs: 0, lengthMs: 70, level: 0.12)]
        }
    }

    /// The samples, in order: each note is a sine with a 4 ms fade-in and an exponential fade-out, plus a quiet
    /// octave above for warmth; notes overlap and add.
    public static func samples(_ k: Kind) -> [Int16] {
        let ns = notes(k)
        let endMs = ns.map { $0.startMs + $0.lengthMs }.max() ?? 0
        let count = endMs * sampleRate / 1000
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            var v = 0.0
            for n in ns {
                let first = n.startMs * sampleRate / 1000, last = (n.startMs + n.lengthMs) * sampleRate / 1000
                guard i >= first, i < last else { continue }
                let u = Double(i - first) / Double(sampleRate), len = Double(n.lengthMs) / 1000
                let attack = min(1, u / 0.004)
                let decay = exp(-u * 5.0 / len)
                v += n.level * attack * decay * (sin(2 * .pi * n.hz * u) + 0.18 * sin(4 * .pi * n.hz * u))
            }
            out[i] = Int16(max(-1, min(1, v)) * 32_000)
        }
        return out
    }

    /// A complete WAV file.
    public static func wav(_ k: Kind) -> Data {
        let s = samples(k)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for v in s { u16(UInt16(bitPattern: v)) }
        return d
    }
}

/// When the app plays a sound (beta.10). Pure: the apps ask, then play.
public struct SoundGate: Sendable {
    public private(set) var lastArrive: Date?
    public init() {}
    /// Bursts get one chime: at most one per this many seconds.
    public static let gap: TimeInterval = 1.5

    /// Something arrived. A notification plays its own sound, so only chime when none is shown.
    public mutating func arrive(soundsOn: Bool, notificationShown: Bool, at now: Date) -> Bool {
        guard soundsOn, !notificationShown else { return false }
        if let l = lastArrive, now.timeIntervalSince(l) < Self.gap { return false }
        lastArrive = now
        return true
    }
}
