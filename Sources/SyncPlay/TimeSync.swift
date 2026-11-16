import Foundation

// SyncPlay phase 1: estimating the server clock, the way jellyfin-web does it
// (src/plugins/syncPlay/core/timeSync/TimeSync.js): NTP-style samples against GET /GetUtcTime, keep the last 8,
// trust the one with the lowest round-trip delay. Poll every second for the first 3 samples, then every minute.

/// One round trip. t0 = request sent (local), t1 = request received (server), t2 = response sent (server),
/// t3 = response received (local).
struct TimeSample: Equatable {
    let t0: Date, t1: Date, t2: Date, t3: Date

    /// How far the server clock is ahead of ours, in seconds: ((t1 − t0) + (t2 − t3)) / 2
    var offset: TimeInterval { (t1.timeIntervalSince(t0) + t2.timeIntervalSince(t3)) / 2 }
    /// Network round trip without the server's own processing time: (t3 − t0) − (t2 − t1)
    var delay: TimeInterval { t3.timeIntervalSince(t0) - t2.timeIntervalSince(t1) }
}

struct TimeSync: Equatable {
    static let window = 8
    static let greedyCount = 3
    static let greedyInterval: TimeInterval = 1
    static let slowInterval: TimeInterval = 60

    private(set) var samples: [TimeSample] = []

    mutating func add(_ s: TimeSample) {
        samples.append(s)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// The sample with the lowest delay in the window (the least distorted by the network).
    var best: TimeSample? { samples.min { $0.delay < $1.delay } }
    var isReady: Bool { best != nil }
    /// Seconds the server clock is ahead of ours (0 until the first sample).
    var offset: TimeInterval { best?.offset ?? 0 }

    func serverNow(local: Date = Date()) -> Date { local.addingTimeInterval(offset) }
    /// When a server timestamp (e.g. a SyncPlay command's `When`) happens on our clock.
    func localDate(forServer d: Date) -> Date { d.addingTimeInterval(-offset) }

    /// Wait before the next poll, given how many pings were made so far.
    static func pollInterval(afterPings n: Int) -> TimeInterval { n < greedyCount ? greedyInterval : slowInterval }

    /// The server's .NET DateTime in ISO 8601, with up to 7 fractional digits ("2026-11-16T10:00:00.1234567Z"),
    /// which ISO8601DateFormatter can't read on its own. A missing zone means UTC.
    static func parseDate(_ s: String) -> Date? {
        var base = s, frac = 0.0
        if let dot = s.firstIndex(of: ".") {
            let after = s[s.index(after: dot)...]
            let digits = after.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            frac = Double("0." + digits) ?? 0
            base = String(s[..<dot]) + after.dropFirst(digits.count)
        }
        if let t = base.firstIndex(of: "T") {
            let time = base[t...]
            if !(time.contains("Z") || time.contains("+") || time.contains("-")) { base += "Z" }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: base)?.addingTimeInterval(frac)
    }
}

/// The body of GET /GetUtcTime (Jellyfin's UtcTimeResponse).
struct UtcTimeResponse: Decodable {
    let RequestReceptionTime: String
    let ResponseTransmissionTime: String

    func sample(sent t0: Date, received t3: Date) -> TimeSample? {
        guard let t1 = TimeSync.parseDate(RequestReceptionTime),
              let t2 = TimeSync.parseDate(ResponseTransmissionTime) else { return nil }
        return TimeSample(t0: t0, t1: t1, t2: t2, t3: t3)
    }
}
