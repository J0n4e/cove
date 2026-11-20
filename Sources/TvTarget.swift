import Foundation

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
