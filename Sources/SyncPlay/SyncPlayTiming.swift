import AVFoundation
import CoreMedia
import Foundation

// SyncPlay timing: start exactly on the group's clock, report Ready sooner.
// - Exact start: a scheduled Unpause used to sleep until its local time and then call play(); AVPlayer then took
//   ~0.3 s to actually start, so every Unpause was followed by a "300 ms behind, SpeedToSync" correction. Now the
//   player is prerolled while paused and started with setRate(_:time:atHostTime:) at the command's host time
//   (requires automaticallyWaitsToMinimizeStalling == false, set while in a group). The measured start lag is
//   logged once per start.
// - Ready: sent once the item is readyToPlay, the group seek has completed and ≥ 2 s are buffered (or the item is
//   likely to keep up), with a 10 s safety timeout.

extension SyncPlayGroup {
    /// How to start for an Unpause at `positionTicks` whose time is `delay` seconds from now (negative: late),
    /// with the player at `currentTicks`. Start from where the player is when that point of the group's timeline
    /// is still ahead (no seek, so the preroll stays valid); else seek to where the group is by then.
    nonisolated static func startPlan(positionTicks: Int64, delay: TimeInterval, currentTicks: Int64)
        -> (itemSeconds: Double?, hostDelay: TimeInterval) {
        let pos = Double(positionTicks) / ticksPerSecond, cur = Double(currentTicks) / ticksPerSecond
        let atCurrent = delay + (cur - pos)
        if abs(cur - pos) <= 0.5, atCurrent >= 0 { return (nil, atCurrent) }
        return (pos + max(0, -delay), max(0, delay))
    }

    nonisolated static let readyBuffer: Double = 2
    nonisolated static let readyTimeout: TimeInterval = 10
    nonisolated static let readyPoll: TimeInterval = 0.1

    /// Ready to tell the group: the item is ready, the seek has landed and enough is loaded.
    nonisolated static func readyToReport(ready: Bool, seeking: Bool, bufferedAhead: Double, likelyToKeepUp: Bool) -> Bool {
        ready && !seeking && (bufferedAhead >= readyBuffer || likelyToKeepUp)
    }
}

extension PlayerModel {
    /// Host-clock time `delay` seconds from now
    nonisolated static func hostTime(after delay: TimeInterval) -> CMTime {
        CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: max(0, delay), preferredTimescale: 1_000_000_000))
    }

    func syncPlaySetGroupMode(_ on: Bool) {
        syncGroupMode = on
        guard let p = player else { return }
        p.automaticallyWaitsToMinimizeStalling = !on
        if on { syncPreroll() } else { syncPrerolled = false }
    }

    var syncPlaySeeking: Bool { syncSeeks > 0 }

    var syncPlayBufferedAhead: Double {
        guard let it = player?.currentItem else { return 0 }
        let t = it.currentTime().seconds
        guard t.isFinite else { return 0 }
        for v in it.loadedTimeRanges {
            let r = v.timeRangeValue
            let s = r.start.seconds, e = CMTimeRangeGetEnd(r).seconds
            if s.isFinite, e.isFinite, t >= s - 0.5, t <= e { return e - t }
        }
        return 0
    }

    var syncPlayLikelyToKeepUp: Bool { player?.currentItem?.isPlaybackLikelyToKeepUp ?? false }

    /// A group seek: small tolerance (drift correction handles the rest), then preroll for the next start.
    func syncPlayTimedSeek(to t: Double) {
        guard let p = player else { return }
        let c = max(0, duration > 0 ? min(t, duration - 1) : t)
        time = c
        syncPrerolled = false
        syncSeeks += 1
        let gen = syncSeekGen &+ 1
        syncSeekGen = gen
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        let done = SyncOnce()
        p.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            guard done.claim() else { return }
            Task { @MainActor in
                guard let self else { return }
                self.syncSeeks = max(0, self.syncSeeks - 1)
                if gen == self.syncSeekGen { self.syncPreroll() }
            }
        }
        localSeekCaption(c)
    }

    /// Paused in a group with a ready item: preload so a timed start begins on time.
    func syncPreroll() {
        guard syncGroupMode, let p = player, p.rate == 0, p.currentItem?.status == .readyToPlay, syncSeeks == 0,
              !p.automaticallyWaitsToMinimizeStalling else { return }
        syncPrerolled = false
        let gen = syncSeekGen
        let done = SyncOnce()
        p.preroll(atRate: speed) { [weak self] finished in
            guard done.claim() else { return }
            Task { @MainActor in
                guard let self, gen == self.syncSeekGen else { return }
                self.syncPrerolled = finished
            }
        }
    }

    func syncPlayPlay(atItemSeconds item: Double?, hostDelay: TimeInterval) -> Bool {
        guard let p = player, syncGroupMode, !p.automaticallyWaitsToMinimizeStalling, p.rate == 0,
              p.currentItem?.status == .readyToPlay, syncSeeks == 0 else { return false }
        // Starting from the current position needs the preroll; a jump (late command) accepts the seek's latency
        if item == nil, !syncPrerolled { return false }
        let host = Self.hostTime(after: hostDelay)
        let itemTime = item.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        let startItem = item ?? p.currentTime().seconds
        p.setRate(speed, time: itemTime, atHostTime: host)
        syncPrerolled = false
        syncTimedStartBegan()
        dlog("SyncPlay: timed start at \(String(format: "%.2f", startItem)) s in \(Int(hostDelay * 1000)) ms")
        // Measure once how far off the start was: item time vs. host time since the planned start
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((max(0, hostDelay) + 1) * 1_000_000_000))
            guard let self, let p = self.player, p.rate > 0 else { return }
            let since = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), host).seconds
            let lag = since * Double(self.speed) - (p.currentTime().seconds - startItem)
            self.dlog("SyncPlay: start lag \(Int((lag * 1000).rounded())) ms")
        }
        return true
    }
}

/// Once-guard for AVFoundation completion handlers
final class SyncOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
