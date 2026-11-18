import SwiftUI

/// The Up next card in a SyncPlay group (v1.18.6): the countdown follows the GROUP's position, not this Mac's
/// clock. The group's position is computed as the drift correction does (the last Unpause's position + server
/// time since it, SyncCorrection.expectedTicks), so every Mac in the group shows the same time left.
enum GroupUpNext {
    /// Whole seconds until the group's episode ends.
    nonisolated static func secsLeft(positionTicks: Int64, when: Date, serverNow: Date, duration: Double) -> Int {
        let pos = Double(SyncCorrection.expectedTicks(positionTicks: positionTicks, when: when, serverNow: serverNow))
            / SyncPlayGroup.ticksPerSecond
        return max(0, Int((duration - pos).rounded(.up)))
    }

    /// "0:12", "1:05"
    nonisolated static func clock(_ secs: Int) -> String {
        let s = max(0, secs)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// The card's countdown line in a group.
    /// Films (Play collection): "Next film for everyone in 0:12".
    nonisolated static func text(_ secs: Int, film: Bool = false) -> String {
        "Next \(film ? "film" : "episode") for everyone in \(clock(secs))"
    }
    /// Cancel's tooltip in a group: it only hides the card here.
    static let cancelTip = "Hide on this Mac (the group still moves on)"
}

extension SyncPlayGroup {
    /// Seconds until the group's episode ends: from the group's playing anchor (server time) while it plays, else
    /// (paused, waiting, no time sync yet) this Mac's own `local` count, which is at the group's paused position.
    func upNextSecsLeft(duration: Double, local: Int) -> Int {
        guard isInGroup, let a = driver.anchor, a.playlistItemId == nil || a.playlistItemId == playlistItemId
              else { return local }
        let t = now()
        return GroupUpNext.secsLeft(positionTicks: a.positionTicks, when: a.when, serverNow: clock().serverNow(local: t),
                                    duration: duration)
    }
}

/// The Up next card's countdown line: the group's countdown in a group, else the local "Next starts in 12s"
/// (only with auto play on, as before).
struct UpNextCountdown: View {
    @ObservedObject var group: SyncPlayGroup
    let autoNext: Bool
    let localSecs: Int
    let duration: Double
    /// Glass theme (v1.18.8): the theme's own font instead of the Glass3D one
    var glass = false
    /// The next item is a film (Play collection)
    var film = false
    var body: some View {
        if group.isInGroup {
            line(GroupUpNext.text(group.upNextSecsLeft(duration: duration, local: localSecs), film: film))
        } else if autoNext {
            line(localSecs > 60 ? "Next starts in \(GroupUpNext.clock(localSecs))" : "Next starts in \(localSecs)s")
        }
    }

    @ViewBuilder private func line(_ s: String) -> some View {
        if glass { Text(s).coveFont(size: 11).foregroundColor(.secondary) }
        else { Text(s).cvFont(11).foregroundColor(.white.opacity(0.88)) }
    }
}
