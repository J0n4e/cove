import Foundation

// New-media notifications: the pure part (no network, no UserNotifications). What counts as new, how a library's
// "already known" state is kept, and how several new items become one notification. Tested in
// Tests/NotificationsTests.swift with Emby- and Jellyfin-shaped answers.

/// A movie or episode as /Users/{id}/Items returns it (Emby and Jellyfin send the same fields).
struct NewMediaItem: Decodable, Equatable, Hashable {
    let Id: String
    let Name: String
    let `Type`: String?
    let SeriesId: String?
    let SeriesName: String?
    let ParentIndexNumber: Int?
    let IndexNumber: Int?
    let ProductionYear: Int?
    let DateCreated: String?
    let UserData: UD?
    struct UD: Decodable, Equatable, Hashable { let Played: Bool?; let PlayedPercentage: Double?; let PlaybackPositionTicks: Int64? }

    init(Id: String, Name: String, type: String?, SeriesId: String? = nil, SeriesName: String? = nil,
         ParentIndexNumber: Int? = nil, IndexNumber: Int? = nil, ProductionYear: Int? = nil,
         DateCreated: String? = nil, UserData: UD? = nil) {
        self.Id = Id; self.Name = Name; self.`Type` = type; self.SeriesId = SeriesId; self.SeriesName = SeriesName
        self.ParentIndexNumber = ParentIndexNumber; self.IndexNumber = IndexNumber; self.ProductionYear = ProductionYear
        self.DateCreated = DateCreated; self.UserData = UserData
    }

    var isMovie: Bool { `Type` == "Movie" }
    var isEpisode: Bool { `Type` == "Episode" }
    /// Started or finished: never announce it.
    var played: Bool {
        guard let u = UserData else { return false }
        return u.Played == true || (u.PlaybackPositionTicks ?? 0) > 0
    }
    var created: Date? { DateCreated.flatMap(NewMediaDetector.parseDate) }
}

struct NewMediaItemList: Decodable { let Items: [NewMediaItem] }

/// What Cove already knows about one library on one server for one user.
struct NewMediaLibraryState: Codable, Equatable {
    /// Newest DateCreated seen (seconds since 1970)
    var newest: Double
    /// Ids already seen (newest last), bounded
    var seen: [String]
    /// When the library was last checked (seconds since 1970)
    var checked: Double
}

/// Where a click on a notification goes.
enum NewMediaTarget: Equatable {
    case item(String)          // a movie page
    case episode(String, series: String?, season: Int?)   // the episode's show, on its season
    case series(String)        // the show (several episodes of it)
    case library(String)       // the library (several movies, or episodes of many shows)
    case test                  // Settings' test notification: just brings Cove to the front
}

/// One notification, ready to post.
struct NewMediaNotification: Equatable {
    let id: String
    let title: String
    let body: String
    /// Notifications with the same thread are grouped by macOS (one per show, one for movies).
    let thread: String
    let target: NewMediaTarget
    /// Pictures to attach, best first (the first one the server has is used)
    let images: [NewMediaImage]
    /// The first candidate's item id
    var posterId: String? { images.first?.id }
    let server: String
    let userId: String
    let libraryId: String
}

/// One picture the notification can show: an item's image of one kind.
struct NewMediaImage: Equatable, Hashable {
    let id: String
    let kind: String   // "Primary", "Backdrop" (never "Thumb")

    /// Width asked for: a wide 16:9 picture this size keeps the expanded banner sharp.
    static let width = 1200

    // Never "Thumb": on some servers an art plugin bakes a TV-set frame into it (owner). Wide pictures first.

    /// A movie: its backdrop, else its poster.
    static func movie(_ id: String) -> [NewMediaImage] { [.init(id: id, kind: "Backdrop"), .init(id: id, kind: "Primary")] }
    /// An episode: the show's wide backdrop first (a clean 16:9 picture; a new episode's own "still" is often
    /// a placeholder the server's art plugin draws inside a TV set, owner), then its own still, then the poster.
    static func episode(_ id: String, series: String?) -> [NewMediaImage] {
        guard let series else { return [.init(id: id, kind: "Primary")] }
        return [.init(id: series, kind: "Backdrop"), .init(id: id, kind: "Primary"), .init(id: series, kind: "Primary")]
    }
    /// A show (batches of episodes): its backdrop, else its poster.
    static func show(_ id: String) -> [NewMediaImage] { [.init(id: id, kind: "Backdrop"), .init(id: id, kind: "Primary")] }
}

/// Per library: which new episodes notify.
enum NewMediaTVMode: String, CaseIterable {
    case all            // every new episode (the default, as before)
    case followed       // only shows being watched or in Favorites
}

/// The user's choices (Settings → General → Notifications).
struct NewMediaPrefs: Equatable {
    var movies = true
    var episodes = true
    var onlyFollowed = false
    /// Libraries switched off: "server|library" (and plain library ids from before 1.18.10, on every server)
    var libsOff: Set<String> = []
    /// "server|library" → the TV choice for that library (missing: `onlyFollowed` decides, i.e. All by default)
    var tvModes: [String: NewMediaTVMode] = [:]
    var anyOn: Bool { movies || episodes }

    /// The key of one library on one server.
    static func libKey(server: String, library: String) -> String { server.lowercased() + "|" + library }

    func libraryOn(server: String, library: String) -> Bool {
        !libsOff.contains(library) && !libsOff.contains(Self.libKey(server: server, library: library))
    }

    func tvMode(server: String, library: String) -> NewMediaTVMode {
        tvModes[Self.libKey(server: server, library: library)] ?? (onlyFollowed ? .followed : .all)
    }

    static let moviesKey = "notifyNewMovies"
    static let episodesKey = "notifyNewEpisodes"
    static let followedKey = "notifyOnlyFollowed"
    static let libsOffKey = "notifyLibsOff"
    static let tvModesKey = "notifyTVModes"

    /// "key=mode" lines (the server address can't hold a newline)
    static func decodeModes(_ s: String) -> [String: NewMediaTVMode] {
        var out: [String: NewMediaTVMode] = [:]
        for line in s.split(separator: "\n") {
            guard let eq = line.lastIndex(of: "=") else { continue }
            if let m = NewMediaTVMode(rawValue: String(line[line.index(after: eq)...])) { out[String(line[..<eq])] = m }
        }
        return out
    }
    static func encodeModes(_ d: [String: NewMediaTVMode]) -> String {
        d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: "\n")
    }

    static func load(_ d: UserDefaults = .standard) -> NewMediaPrefs {
        NewMediaPrefs(movies: d.object(forKey: moviesKey) as? Bool ?? true,
                      episodes: d.object(forKey: episodesKey) as? Bool ?? true,
                      onlyFollowed: d.bool(forKey: followedKey),
                      libsOff: Set((d.string(forKey: libsOffKey) ?? "").split(separator: ",").map(String.init)),
                      tvModes: decodeModes(d.string(forKey: tvModesKey) ?? ""))
    }
}

/// A library that can have new movies or episodes.
struct NewMediaLibrary: Equatable {
    let id: String
    let name: String
    let kind: String?   // "movies", "tvshows", nil (mixed)

    /// Only movie, show and mixed libraries (no music, photos, live TV…)
    static func eligible(kind: String?) -> Bool { kind == nil || kind == "movies" || kind == "tvshows" || kind == "mixed" }
    /// What to ask the server for in this library, given the settings; nil = nothing to watch.
    func includeTypes(_ p: NewMediaPrefs) -> String? {
        var t: [String] = []
        if p.movies, kind != "tvshows" { t.append("Movie") }
        if p.episodes, kind != "movies" { t.append("Episode") }
        return t.isEmpty ? nil : t.joined(separator: ",")
    }
}

enum NewMediaDetector {
    /// Ids remembered per library (the poll asks for 50 at most, so this covers a few rounds)
    static let maxSeen = 200
    /// A library not checked for this long gets a fresh baseline instead of a burst of old news
    static let staleAfter: TimeInterval = 3 * 24 * 3600
    /// At most this many show notifications per library and round; more become one library notification
    static let maxSeriesBatches = 3

    // MARK: Dates

    /// Emby / Jellyfin dates: "2024-05-01T10:20:30.1234567Z" (7 fraction digits, which ISO8601DateFormatter
    /// can't read), sometimes "+00:00" or no zone at all (then UTC).
    static func parseDate(_ s: String) -> Date? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 19 else { return nil }
        var frac = 0.0
        if let dot = t.firstIndex(of: "."), dot > t.index(t.startIndex, offsetBy: 18) {
            var end = t.index(after: dot)
            while end < t.endIndex, t[end].isNumber { end = t.index(after: end) }
            frac = Double("0" + String(t[dot..<end])) ?? 0
            t.removeSubrange(dot..<end)
        }
        let tail = t.dropFirst(19)
        if tail.isEmpty { t += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t).map { $0.addingTimeInterval(frac) }
    }

    // MARK: Baseline and diff

    /// First look at a library: remember what's there, announce nothing.
    static func baseline(_ items: [NewMediaItem], now: Date) -> NewMediaLibraryState {
        // An empty library: anything that shows up later is new
        let newest = items.compactMap(\.created).max()?.timeIntervalSince1970 ?? 0
        return NewMediaLibraryState(newest: newest,
                                    seen: Array(items.map(\.Id).reversed().suffix(maxSeen)),
                                    checked: now.timeIntervalSince1970)
    }

    /// The items to announce from a poll (newest first, as the server sorted them) and the new state. New =
    /// added at or after the newest date already known, not seen before, a movie or an episode, never played.
    /// `stale` (not checked for days, e.g. the server was not used): baseline again, nothing to announce.
    static func diff(_ state: NewMediaLibraryState?, _ items: [NewMediaItem], now: Date)
        -> (new: [NewMediaItem], state: NewMediaLibraryState) {
        guard let state, now.timeIntervalSince1970 - state.checked < staleAfter else { return ([], baseline(items, now: now)) }
        let seen = Set(state.seen)
        var new: [NewMediaItem] = []
        var ids = Set<String>()
        for it in items {
            guard let c = it.created, c.timeIntervalSince1970 >= state.newest, !seen.contains(it.Id),
                  !ids.contains(it.Id), it.isMovie || it.isEpisode, !it.played else { continue }
            new.append(it); ids.insert(it.Id)
        }
        return (new, remember(items, in: state, now: now))
    }

    /// Adds items to the seen list and moves the newest date forward (never back).
    static func remember(_ items: [NewMediaItem], in state: NewMediaLibraryState, now: Date) -> NewMediaLibraryState {
        var s = state
        let newest = items.compactMap(\.created).map(\.timeIntervalSince1970).max() ?? s.newest
        s.newest = max(s.newest, newest)
        let known = Set(s.seen)
        var added = Set<String>()
        for it in items.reversed() where !known.contains(it.Id) && !added.contains(it.Id) { s.seen.append(it.Id); added.insert(it.Id) }
        if s.seen.count > maxSeen { s.seen.removeFirst(s.seen.count - maxSeen) }
        s.checked = now.timeIntervalSince1970
        return s
    }

    /// The settings' filter: movies / episodes on or off, and "only shows I follow".
    static func filter(_ items: [NewMediaItem], prefs: NewMediaPrefs, followed: Set<String>) -> [NewMediaItem] {
        items.filter { it in
            if it.isMovie { return prefs.movies }
            guard it.isEpisode, prefs.episodes else { return false }
            return !prefs.onlyFollowed || followed.contains(it.SeriesId ?? "")
        }
    }

    /// Per library: switched off → nothing; a TV choice of "only shows I watch / in Favorites" → only those
    /// shows' episodes. Runs before batching.
    static func filter(_ items: [NewMediaItem], library: String, server: String, prefs: NewMediaPrefs,
                       followed: Set<String>) -> [NewMediaItem] {
        guard prefs.libraryOn(server: server, library: library) else { return [] }
        var p = prefs
        p.onlyFollowed = prefs.tvMode(server: server, library: library) == .followed
        return filter(items, prefs: p, followed: followed)
    }

    // MARK: Text and batching

    /// Several episodes of one show: "S2:E4–E6" when they run on in one season, else a short list
    /// ("S2:E4, E6 · S3:E1", at most `max` codes, then …).
    static func episodeSpan(_ eps: [NewMediaItem], max n: Int = 4) -> String {
        let sorted = eps.sorted { ($0.ParentIndexNumber ?? -1, $0.IndexNumber ?? -1) < ($1.ParentIndexNumber ?? -1, $1.IndexNumber ?? -1) }
        let seasons = Set(sorted.map { $0.ParentIndexNumber ?? -1 })
        let nums = sorted.compactMap(\.IndexNumber)
        if seasons.count == 1, nums.count == sorted.count, nums.count >= 2,
           zip(nums, nums.dropFirst()).allSatisfy({ $1 == $0 + 1 }), let first = sorted.first {
            let s = first.ParentIndexNumber.map { "S\($0):" } ?? ""
            return "\(s)E\(nums[0])–E\(nums[nums.count - 1])"
        }
        var groups: [String] = []
        var shown = 0
        var started = false
        var lastSeason: Int? = nil
        var cur: [String] = []
        for e in sorted where shown < n {
            if !started || lastSeason != e.ParentIndexNumber {
                if !cur.isEmpty { groups.append(cur.joined(separator: ", ")) }
                cur = []
                started = true
                lastSeason = e.ParentIndexNumber
                cur.append(episodeCode(e) ?? e.Name)
            } else {
                cur.append(e.IndexNumber.map { "E\($0)" } ?? e.Name)
            }
            shown += 1
        }
        if !cur.isEmpty { groups.append(cur.joined(separator: ", ")) }
        return groups.joined(separator: " · ") + (sorted.count > n ? "…" : "")
    }

    /// At least this many new movies at once become one notification (fewer: one each)
    static let movieBatchMin = 4

    /// "S18:E12" (or "S1" / "E3" when the server doesn't know one of them)
    static func episodeCode(_ it: NewMediaItem) -> String? {
        switch (it.ParentIndexNumber, it.IndexNumber) {
        case let (s?, e?): return "S\(s):E\(e)"
        case let (s?, nil): return "S\(s)"
        case let (nil, e?): return "E\(e)"
        default: return nil
        }
    }

    /// "Name (2024)" for a movie; "Series — S18:E12 · Title" for an episode.
    static func line(_ it: NewMediaItem) -> String {
        if it.isEpisode {
            var parts = [it.SeriesName ?? it.Name]
            let code = episodeCode(it)
            let detail = [code, it.SeriesName == nil ? nil : it.Name].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty { parts.append(detail) }
            return parts.joined(separator: " — ")
        }
        if let y = it.ProductionYear { return "\(it.Name) (\(y))" }
        return it.Name
    }

    /// "A, B, C…" (the first three names, … when there are more)
    static func names(_ items: [NewMediaItem], max n: Int = 3) -> String {
        let shown = items.prefix(n).map(\.Name).joined(separator: ", ")
        return items.count > n ? shown + "…" : shown
    }

    /// One library's new items as notifications: one for all new movies, one per show; more than
    /// `maxSeriesBatches` shows become one notification for the library.
    static func batches(_ items: [NewMediaItem], library: NewMediaLibrary, server: String, userId: String) -> [NewMediaNotification] {
        func note(_ key: String, _ title: String, _ body: String, _ thread: String, _ target: NewMediaTarget, _ images: [NewMediaImage]) -> NewMediaNotification {
            NewMediaNotification(id: "\(server)|\(userId)|\(library.id)|\(key)", title: title, body: body, thread: thread,
                                 target: target, images: images, server: server, userId: userId, libraryId: library.id)
        }
        var out: [NewMediaNotification] = []
        let movies = items.filter(\.isMovie)
        if movies.count >= movieBatchMin {
            out.append(note(movies.map(\.Id).joined(separator: ","), "\(movies.count) new movies", names(movies),
                            "cove-movies", .library(library.id), movies.first.map { NewMediaImage.movie($0.Id) } ?? []))
        } else {
            for m in movies { out.append(note(m.Id, "New movie", line(m), "cove-movies", .item(m.Id), NewMediaImage.movie(m.Id))) }
        }
        let episodes = items.filter(\.isEpisode)
        var order: [String] = []
        var bySeries: [String: [NewMediaItem]] = [:]
        for e in episodes {
            let k = e.SeriesId ?? e.Id
            if bySeries[k] == nil { order.append(k) }
            bySeries[k, default: []].append(e)
        }
        if order.count > maxSeriesBatches {
            let shows = order.compactMap { bySeries[$0]?.first?.SeriesName }
            let shown = shows.prefix(3).joined(separator: ", ") + (shows.count > 3 ? "…" : "")
            out.append(note(episodes.map(\.Id).joined(separator: ","), "New episodes",
                            "\(episodes.count) new episodes: \(shown)", "cove-library-\(library.id)", .library(library.id),
                            order.first.map(NewMediaImage.show) ?? []))
            return out
        }
        for k in order {
            guard let eps = bySeries[k], let first = eps.first else { continue }
            // The show's id: macOS groups its notifications in Notification Center
            let thread = k
            if eps.count == 1 {
                out.append(note(first.Id, "New episode", line(first), thread,
                                .episode(first.Id, series: first.SeriesId, season: first.ParentIndexNumber),
                                NewMediaImage.episode(first.Id, series: first.SeriesId)))
            } else {
                let span = episodeSpan(eps)
                out.append(note(eps.map(\.Id).joined(separator: ","), first.SeriesName ?? "New episodes",
                                "\(eps.count) new episodes" + (span.isEmpty ? "" : " · " + span),
                                thread, first.SeriesId.map { .series($0) } ?? .library(library.id),
                                first.SeriesId.map(NewMediaImage.show) ?? NewMediaImage.episode(first.Id, series: nil)))
            }
        }
        return out
    }

    // MARK: Storage

    /// UserDefaults key of one library's state: per server, user and library, so a server switch never mixes them.
    static func stateKey(server: String, userId: String, library: String) -> String {
        "\(server.lowercased())|\(userId)|\(library)"
    }
}

/// The states of every library, kept as one dictionary in the preferences ("newMediaState").
struct NewMediaStore {
    static let key = "newMediaState"
    let defaults: UserDefaults

    func get(_ k: String) -> NewMediaLibraryState? {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([String: NewMediaLibraryState].self, from: data) else { return nil }
        return all[k]
    }

    func set(_ s: NewMediaLibraryState, for k: String) {
        var all: [String: NewMediaLibraryState] = [:]
        if let data = defaults.data(forKey: Self.key),
           let old = try? JSONDecoder().decode([String: NewMediaLibraryState].self, from: data) { all = old }
        all[k] = s
        // Bounded: keep the 60 most recently checked libraries
        if all.count > 60 {
            for old in all.sorted(by: { $0.value.checked < $1.value.checked }).prefix(all.count - 60) { all[old.key] = nil }
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    /// Forgets one server's states (used when it's removed).
    func removeServer(_ server: String) {
        guard let data = defaults.data(forKey: Self.key),
              var all = try? JSONDecoder().decode([String: NewMediaLibraryState].self, from: data) else { return }
        let prefix = server.lowercased() + "|"
        all = all.filter { !$0.key.hasPrefix(prefix) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }
}
