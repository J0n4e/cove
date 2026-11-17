import Foundation

// SyncPlay phase 3: keeping in step while the group plays, the way jellyfin-web does it
// (src/plugins/syncPlay/core/PlaybackCore.js, syncPlaybackTime + loadPreferences):
// - expected position = the last Unpause's PositionTicks + (server now − its When) (estimateCurrentTicks);
// - delay = expected − ours, in ms (positive: we're behind);
// - SpeedToSync for 60 ms ≤ |delay| < 3000 ms: rate 1 + delay / 1000 ms for 1000 ms, then back to 1.0;
// - else SkipToSync for |delay| ≥ 400 ms: seek to the expected position;
// - at most one check per maxDelaySpeedToSync / 2 = 1.5 s, none while a correction runs, none in the first
//   1.5 s after the Unpause (scheduleUnpause's enableSyncTimeout), none while buffering or not after an Unpause.
// Web clamps the slow side at 0.2× by stretching the duration; Cove clamps both sides (0.5×–2×) the same way so
// AVPlayer's audio stays listenable, stretching the duration so the whole delay is still recovered.

enum SyncCorrection {
    struct Settings: Equatable {
        var minDelaySpeedToSync: Double = 60      // ms
        var maxDelaySpeedToSync: Double = 3000    // ms
        var speedToSyncDuration: Double = 1000    // ms
        var minDelaySkipToSync: Double = 400      // ms
        var useSpeedToSync = true
        var useSkipToSync = true
        var minRate: Double = 0.5
        var maxRate: Double = 2.0
        /// Pause between checks, and the quiet time after an Unpause or a skip (web: maxDelaySpeedToSync / 2)
        var checkInterval: TimeInterval { maxDelaySpeedToSync / 2000 }
        static let web = Settings()
    }

    enum Action: Equatable {
        case none
        /// Play at `rate` for `duration` seconds, then back to 1.0
        case speed(rate: Double, duration: TimeInterval)
        case skip(ticks: Int64)
    }

    static let ticksPerMs: Double = 10_000

    /// Where the group is now: the command's position plus the server time since its `When`.
    static func expectedTicks(positionTicks: Int64, when: Date, serverNow: Date) -> Int64 {
        positionTicks + Int64((serverNow.timeIntervalSince(when) * 1000 * ticksPerMs).rounded())
    }

    /// Milliseconds we're behind the group (negative: ahead).
    static func delayMs(expected: Int64, current: Int64) -> Double { Double(expected - current) / ticksPerMs }

    static func decide(delayMs d: Double, expectedTicks: Int64, settings s: Settings = .web) -> Action {
        let a = abs(d)
        if s.useSpeedToSync, a >= s.minDelaySpeedToSync, a < s.maxDelaySpeedToSync {
            var duration = s.speedToSyncDuration
            var rate = 1 + d / duration
            if rate > s.maxRate { rate = s.maxRate; duration = d / (s.maxRate - 1) }
            if rate < s.minRate { rate = s.minRate; duration = -d / (1 - s.minRate) }
            return .speed(rate: rate, duration: duration / 1000)
        }
        if s.useSkipToSync, a >= s.minDelaySkipToSync { return .skip(ticks: max(0, expectedTicks)) }
        return .none
    }
}

/// Drives the corrections and the mid-playback Buffering / Ready reports for a group. Pure state: the group
/// calls `step` about every 0.25 s with the time and the player's state; `step` says what to do.
struct SyncDriver {
    /// The Unpause the group is playing from
    struct Anchor: Equatable {
        let positionTicks: Int64
        /// Server time
        let when: Date
        let playlistItemId: String?
        /// Local time it was applied
        let appliedAt: Date
    }

    enum Output: Equatable {
        case correct(SyncCorrection.Action, delayMs: Double)
        /// Speed correction is over
        case resetRate
        case buffering
        case ready
    }

    /// Web (ui/players/HtmlVideoPlayer.js, minBufferingThresholdMillis): a stall is reported after 3 s.
    static let bufferingThreshold: TimeInterval = 3

    var settings = SyncCorrection.Settings.web
    private(set) var anchor: Anchor?
    private(set) var speedUntil: Date?
    private(set) var quietUntil: Date?
    private(set) var lastCheck: Date?
    private(set) var stallSince: Date?
    private(set) var reportedBuffering = false

    var isBuffering: Bool { reportedBuffering }

    /// An Unpause ran: correct from it, after a quiet time.
    mutating func unpaused(_ a: Anchor) {
        anchor = a
        quietUntil = a.appliedAt.addingTimeInterval(settings.checkInterval)
        lastCheck = nil
    }

    /// Pause / Seek / Stop / a new item / leaving: nothing to correct from. Returns true when a speed-up was
    /// running (the rate must go back to 1.0).
    @discardableResult
    mutating func stopped() -> Bool {
        let wasSpeeding = speedUntil != nil
        anchor = nil; speedUntil = nil; quietUntil = nil; lastCheck = nil
        stallSince = nil; reportedBuffering = false
        return wasSpeeding
    }

    /// `busy`: loading or seeking (a Buffering / Ready report of a load or seek is running).
    mutating func step(now: Date, serverNow: Date, ticks: Int64, playing: Bool, stalled: Bool, busy: Bool,
                       playlistItemId: String?) -> [Output] {
        var out: [Output] = []
        if let u = speedUntil, now >= u {
            speedUntil = nil
            out.append(.resetRate)
        }
        // Mid-playback stall: only while the group plays and we're not loading / seeking ourselves
        if anchor != nil, playing, stalled, !busy {
            if stallSince == nil { stallSince = now }
            if !reportedBuffering, let s = stallSince, now.timeIntervalSince(s) >= Self.bufferingThreshold {
                reportedBuffering = true
                if speedUntil != nil { speedUntil = nil; out.append(.resetRate) }
                out.append(.buffering)
            }
        } else {
            stallSince = nil
            if reportedBuffering, !stalled {
                reportedBuffering = false
                // The group will send a new Unpause; don't correct from the old one meanwhile
                quietUntil = now.addingTimeInterval(settings.checkInterval)
                out.append(.ready)
            }
        }
        guard let a = anchor, playing, !stalled, !busy, !reportedBuffering, speedUntil == nil,
              a.playlistItemId == nil || a.playlistItemId == playlistItemId else { return out }
        if let q = quietUntil, now < q { return out }
        if let l = lastCheck, now.timeIntervalSince(l) < settings.checkInterval { return out }
        lastCheck = now
        let expected = SyncCorrection.expectedTicks(positionTicks: a.positionTicks, when: a.when, serverNow: serverNow)
        let d = SyncCorrection.delayMs(expected: expected, current: ticks)
        let action = SyncCorrection.decide(delayMs: d, expectedTicks: expected, settings: settings)
        switch action {
        case .none: return out
        case .speed(_, let duration): speedUntil = now.addingTimeInterval(duration)
        case .skip: quietUntil = now.addingTimeInterval(settings.checkInterval)
        }
        out.append(.correct(action, delayMs: d))
        return out
    }
}
