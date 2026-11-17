import AVFoundation
import Foundation

// SyncPlay phase 2: the bridge between a group and the player. The group only sees this protocol, so its
// scheduling and reports are tested with a fake player. These calls act on the player directly: they are the
// group's commands, never routed back to the group (PlayerModel.togglePlay / seek do that for the user's own).

@MainActor
protocol SyncPlayPlayback: AnyObject {
    /// Position in ticks (100 ns)
    var syncPlayTicks: Int64 { get }
    var syncPlayIsPlaying: Bool { get }
    /// The item playing (nil while nothing is loaded)
    var syncPlayItemId: String? { get }
    /// The stream is ready to play
    var syncPlayReady: Bool { get }
    func syncPlayPlay()
    func syncPlayPause()
    func syncPlaySeek(ticks: Int64)
    /// Phase 3: the player is waiting for data while it should be playing (a mid-playback stall)
    var syncPlayStalled: Bool { get }
    /// Phase 3: drift correction's playback rate (1.0 = normal); only while playing
    func syncPlaySetRate(_ rate: Double)
    // MARK: Timing (exact start, Ready sooner) ↓
    /// Starts playback on the group's clock: at item time `atItemSeconds` (nil = from where the player is) exactly
    /// `hostDelay` seconds from now on the host clock (AVPlayer.setRate(_:time:atHostTime:)). False = not possible
    /// right now (item not ready, stalling-avoidance on): the caller falls back to play() at the scheduled time.
    func syncPlayPlay(atItemSeconds: Double?, hostDelay: TimeInterval) -> Bool
    /// In a group (true) the player starts exactly when told (no automatic waiting to minimise stalls)
    func syncPlaySetGroupMode(_ on: Bool)
    /// A group seek hasn't completed yet
    var syncPlaySeeking: Bool { get }
    /// Seconds loaded past the current position
    var syncPlayBufferedAhead: Double { get }
    var syncPlayLikelyToKeepUp: Bool { get }
    // ↑ timing
}

extension SyncPlayPlayback {
    var syncPlayStalled: Bool { false }
    func syncPlaySetRate(_ rate: Double) {}
    // Timing ↓
    func syncPlayPlay(atItemSeconds: Double?, hostDelay: TimeInterval) -> Bool { false }
    func syncPlaySetGroupMode(_ on: Bool) {}
    var syncPlaySeeking: Bool { false }
    var syncPlayBufferedAhead: Double { .infinity }
    var syncPlayLikelyToKeepUp: Bool { true }
    // ↑ timing
}

extension PlayerModel: SyncPlayPlayback {
    var syncPlayTicks: Int64 {
        let t = now
        return Int64((t.isFinite ? max(0, t) : 0) * SyncPlayGroup.ticksPerSecond)
    }
    var syncPlayIsPlaying: Bool { (player?.rate ?? 0) > 0 }
    var syncPlayItemId: String? { currentItemId }
    var syncPlayReady: Bool { isReady }
    func syncPlayPlay() { if !syncPlayIsPlaying { localTogglePlay() } }
    func syncPlayPause() { if syncPlayIsPlaying { localTogglePlay() }; syncPreroll() }   // timing: preload the next start
    func syncPlaySeek(ticks: Int64) { syncPlayTimedSeek(to: Double(ticks) / SyncPlayGroup.ticksPerSecond) }   // timing: SyncPlayTiming.swift
    var syncPlayStalled: Bool { player?.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    func syncPlaySetRate(_ rate: Double) {
        guard let p = player, p.rate > 0 else { return }
        p.rate = speed * Float(rate)
    }
}

extension Emby {
    /// A group's PlayQueue points at an item: open the player on it, paused at `start` seconds (the group
    /// starts it with an Unpause once everyone is ready).
    func syncPlayOpen(_ itemId: String, start: Double) async {
        guard let it: Item = try? await get("/Users/\(userId)/Items/\(itemId)") else {
            DebugLog.write("SyncPlay: couldn't load the group's item")
            return
        }
        playing = PlayRequest(item: it, start: start > 0 ? start : nil, startPaused: true)
    }
}
