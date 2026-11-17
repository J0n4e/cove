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
}

extension SyncPlayPlayback {
    var syncPlayStalled: Bool { false }
    func syncPlaySetRate(_ rate: Double) {}
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
    func syncPlayPause() { if syncPlayIsPlaying { localTogglePlay() } }
    func syncPlaySeek(ticks: Int64) { localSeek(to: Double(ticks) / SyncPlayGroup.ticksPerSecond) }
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
