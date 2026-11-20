import Foundation
import Combine

/// Settings → Playback "Play on a TV with" (owner): only the chosen TV button shows on the Glass3D
/// detail page and in the player bar. Cast is the default.
enum TvTarget {
    static let key = "tvTarget"
    static let cast = "cast", airplay = "airplay"
    static let options: [(String, String)] = [(cast, "Google Cast"), (airplay, "AirPlay")]

    /// Unknown/missing values fall back to Cast.
    static func normalized(_ raw: String?) -> String { raw == airplay ? airplay : cast }
    static var current: String { normalized(UserDefaults.standard.string(forKey: key)) }

    /// Whether the TV button `id` ("cast"/"airplay") shows. Other ids always show. A running cast keeps the Cast
    /// button (remote/stop stay reachable); active AirPlay keeps the AirPlay button.
    static func shows(_ id: String, tvTarget: String, casting: Bool = false, airPlayActive: Bool = false) -> Bool {
        let t = normalized(tvTarget)
        switch id {
        case cast: return t == cast || casting
        case airplay: return t == airplay || airPlayActive
        default: return true
        }
    }
}

/// The Glass3D player bar's items filtered for the TV choice (pure, tested in TvTargetTests).
enum PlayerBarItems {
    static func ids(_ ids: [String], tvTarget: String, casting: Bool = false, airPlayActive: Bool = false) -> [String] {
        ids.filter { TvTarget.shows($0, tvTarget: tvTarget, casting: casting, airPlayActive: airPlayActive) }
    }
    static func items(_ items: [Glass3DBarItem], tvTarget: String, casting: Bool = false) -> [Glass3DBarItem] {
        // The AirPlay item's `on` is the player's isExternalPlaybackActive
        let airOn = items.contains { $0.id == TvTarget.airplay && $0.on }
        return items.filter { TvTarget.shows($0.id, tvTarget: tvTarget, casting: casting, airPlayActive: airOn) }
    }
    static func items(tvTarget: String, casting: Bool = false, airPlayActive: Bool = false) -> [String] {
        ids(Glass3DBarItem.order, tvTarget: tvTarget, casting: casting, airPlayActive: airPlayActive)
    }
}

/// Live "is a TV session running" state Settings reads to lock the TV choice.
final class TvRouteState: ObservableObject {
    static let shared = TvRouteState()
    /// The player's isExternalPlaybackActive (set from AirPlaySleep.set, which follows it).
    @Published private(set) var airPlayActive = false

    static func setAirPlay(_ on: Bool) {
        if Thread.isMainThread { if shared.airPlayActive != on { shared.airPlayActive = on } }
        else { DispatchQueue.main.async { setAirPlay(on) } }
    }
}

extension TvTarget {
    /// Why the choice is locked (nil = free to change). A running session must be stopped first.
    static func lockReason(casting: Bool, airPlayActive: Bool) -> String? {
        if casting { return "Stop casting to change this" }
        if airPlayActive { return "Stop AirPlay to change this" }
        return nil
    }
    /// The value to store for a change request: ignored (old value kept) while a session is active.
    static func apply(_ new: String, current: String, casting: Bool, airPlayActive: Bool) -> String {
        lockReason(casting: casting, airPlayActive: airPlayActive) == nil ? normalized(new) : normalized(current)
    }
}
