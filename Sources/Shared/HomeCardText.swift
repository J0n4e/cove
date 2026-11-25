import Foundation

/// Text of the wide Home cards (Continue Watching, Up Next), shown UNDER the picture.
enum HomeCardText {
    /// The rows drawn with the wide 16:9 card.
    static func isWideRow(_ feed: Feed?) -> Bool { feed == .resume || feed == .nextUp }

    /// The grey line under the title.
    /// Episodes: "S2·E3 · Episode name · 23m left" (no "left" when `timeLeft` is nil, e.g. not started).
    /// Movies: "1h 12m left", or the year when there is no time left to show.
    static func subtitle(isEpisode: Bool, season: Int?, episode: Int?, name: String,
                         timeLeft: String?, year: Int?) -> String {
        if isEpisode {
            var parts: [String] = []
            if season != nil || episode != nil { parts.append("S\(season ?? 0)·E\(episode ?? 0)") }
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { parts.append(n) }
            if let timeLeft, !timeLeft.isEmpty { parts.append(timeLeft) }
            return parts.joined(separator: " · ")
        }
        if let timeLeft, !timeLeft.isEmpty { return timeLeft }
        return year.map(String.init) ?? ""
    }
}
