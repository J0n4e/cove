import Foundation

// Activity → Libraries (admins + Playback Reporting): one card per movie / TV / music library with its size,
// plays and watch time in the range, top titles and the latest additions. Pure rules here (tested in
// StatsGraphsTests); loading in StatsModel.loadLibraries, the views in StatsLibraries.swift.

/// A library from the app's library list (the user's views).
struct StatsLibraryInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String?
}

/// "1,234 Movies", "56 Series", "2,345 Episodes".
struct StatsLibCount: Hashable, Sendable {
    let label: String
    let count: Int
}

/// A top title inside one library: a movie / song by item, episodes collapsed to their series.
struct StatsLibraryTop: Identifiable, Hashable, Sendable {
    let top: StatsTop
    let show: Bool
    var id: String { top.id }
}

/// One library's card.
struct StatsLibraryUsage: Identifiable, Hashable, Sendable {
    let lib: StatsLibraryInfo
    var counts: [StatsLibCount] = []
    let plays: Int
    let seconds: Int
    let tops: [StatsLibraryTop]
    var id: String { lib.id }
}

enum StatsLibrariesAggregate {
    /// Only movie, TV and music libraries get a card.
    static func eligible(_ kind: String?) -> Bool {
        ["movies", "tvshows", "music"].contains((kind ?? "").lowercased())
    }

    /// What a library's size line counts (IncludeItemTypes, label).
    static func countTypes(_ kind: String?) -> [(type: String, label: String)] {
        switch (kind ?? "").lowercased() {
        case "movies": return [("Movie", "Movies")]
        case "tvshows": return [("Series", "Series"), ("Episode", "Episodes")]
        case "music": return [("MusicAlbum", "Albums"), ("Audio", "Songs")]
        default: return []
        }
    }

    /// Distinct item ids of the plays that aren't mapped to a library yet, the most recent plays first, at most
    /// `limit` (the rest is left out and reported as truncated).
    static func unmapped(_ plays: [StatsPlay], known: [String: String], limit: Int) -> (ids: [String], truncated: Bool) {
        var seen = Set<String>(), out: [String] = []
        for p in plays.sorted(by: { $0.start > $1.start }) where !p.itemId.isEmpty && known[p.itemId] == nil {
            guard seen.insert(p.itemId).inserted else { continue }
            out.append(p.itemId)
        }
        return (Array(out.prefix(limit)), out.count > limit)
    }

    /// Top titles by watch time (ties: plays, then title).
    static func tops(_ plays: [StatsPlay], limit: Int = 3) -> [StatsLibraryTop] {
        let g = Dictionary(grouping: plays, by: { $0.isEpisode ? "s:" + $0.displayTitle : "i:" + $0.itemId })
        return g.map { key, ps in
            let latest = ps.max { $0.start < $1.start } ?? ps[0]
            let show = key.hasPrefix("s:")
            return StatsLibraryTop(top: StatsTop(id: key, title: show ? latest.displayTitle : latest.name, itemId: latest.itemId,
                                                 seconds: StatsAggregate.totalSeconds(ps), plays: ps.count), show: show)
        }
        .sorted {
            if $0.top.seconds != $1.top.seconds { return $0.top.seconds > $1.top.seconds }
            if $0.top.plays != $1.top.plays { return $0.top.plays > $1.top.plays }
            return $0.top.title < $1.top.title
        }
        .prefix(limit).map { $0 }
    }

    /// One card per library: the plays whose item maps to it (`map`: item id → library id; "" = in none).
    /// Most watch time first, then most plays, then the name.
    static func usage(_ libs: [StatsLibraryInfo], plays: [StatsPlay], map: [String: String],
                      counts: [String: [StatsLibCount]] = [:]) -> [StatsLibraryUsage] {
        let byLib = Dictionary(grouping: plays.filter { !(map[$0.itemId] ?? "").isEmpty }, by: { map[$0.itemId]! })
        return libs.map { l in
            let ps = byLib[l.id] ?? []
            return StatsLibraryUsage(lib: l, counts: counts[l.id] ?? [], plays: ps.count,
                                     seconds: StatsAggregate.totalSeconds(ps), tops: tops(ps))
        }
        .sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            return $0.lib.name.localizedCaseInsensitiveCompare($1.lib.name) == .orderedAscending
        }
    }

    /// After asking one library which of `asked` it holds: those ids map to it.
    static func record(found: [String], library: String, into map: inout [String: String]) {
        for id in found { map[id] = library }
    }

    /// Ids asked of every library and found in none (deleted items, other library kinds): "" so they aren't
    /// asked again.
    static func markMissing(_ asked: [String], into map: inout [String: String]) {
        for id in asked where map[id] == nil { map[id] = "" }
    }

    /// `/Users/{id}/Items` answer: the item ids in it.
    static func ids(_ data: Data) -> [String] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = o["Items"] as? [[String: Any]] else { return [] }
        return items.map { StatsDecode.string($0["Id"]) }.filter { !$0.isEmpty }
    }

    /// `TotalRecordCount` of an Items answer (nil when unreadable).
    static func total(_ data: Data) -> Int? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], o["TotalRecordCount"] != nil else { return nil }
        return StatsDecode.int(o["TotalRecordCount"])
    }

    /// "1,234 Movies · 56 Series · 2,345 Episodes".
    static func countsText(_ counts: [StatsLibCount]) -> String {
        counts.map { "\($0.count.formatted()) \($0.label)" }.joined(separator: " · ")
    }
}
