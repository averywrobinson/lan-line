import Foundation

/// Speed and time left for a transfer (beta.10), from the progress events the cards already get. Smoothed so the
/// numbers don't jump with every chunk; the same rules and wording on Windows (`TransferRate` in LanLine.Core).
public struct TransferRate: Equatable, Sendable {
    /// Bytes per second, smoothed; nil until there are two samples far enough apart.
    public private(set) var bytesPerSecond: Double?
    private var last: (bytes: Int64, at: Date)?

    /// How much a new measurement counts (the rest is the running average).
    public static let weight = 0.3
    /// Samples closer than this are skipped (too noisy to measure).
    public static let minGap: TimeInterval = 0.2

    public init() {}

    public static func == (a: TransferRate, b: TransferRate) -> Bool { a.bytesPerSecond == b.bytesPerSecond }

    public mutating func update(done: Int64, at t: Date) {
        guard let l = last else { last = (done, t); return }
        let dt = t.timeIntervalSince(l.at)
        if done < l.bytes { self = TransferRate(); last = (done, t); return }   // started again (a resend)
        guard dt >= Self.minGap else { return }
        let now = Double(done - l.bytes) / dt
        bytesPerSecond = bytesPerSecond.map { $0 * (1 - Self.weight) + now * Self.weight } ?? now
        last = (done, t)
    }

    /// Seconds left at the current speed; nil when unknown or stalled.
    public func remaining(done: Int64, total: Int64) -> TimeInterval? {
        guard let r = bytesPerSecond, r > 1 else { return nil }
        return Double(max(total - done, 0)) / r
    }

    /// "42% · 85 MB/s · 12 s left" (each part only when known).
    public func describe(done: Int64, total: Int64) -> String {
        var parts = ["\(total > 0 ? Int(Double(done) * 100 / Double(total)) : 0)%"]
        if let r = bytesPerSecond, r > 1 { parts.append("\(Cleanup.formatBytes(Int64(r)))/s") }
        if let s = remaining(done: done, total: total) { parts.append(Self.timeLeft(s)) }
        return parts.joined(separator: " · ")
    }

    /// "a few seconds left", "12 s left", "3 min left", "1 h 5 min left".
    public static func timeLeft(_ s: TimeInterval) -> String {
        if s < 5 { return "a few seconds left" }
        if s < 60 { return "\(Int(s.rounded())) s left" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min left" }
        let m = Int((s / 60).rounded())
        return m % 60 == 0 ? "\(m / 60) h left" : "\(m / 60) h \(m % 60) min left"
    }
}
