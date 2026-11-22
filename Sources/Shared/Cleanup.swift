import Foundation

// Activity → Cleanup (admins only, Emby and Jellyfin): every movie and series of the server, sortable from
// "never watched by anyone" to "watched by most", by rating, date added, last played and size, with Delete…
// per row and for a selection (the Delete… flow of DeleteEverywhereService).
//
// Data (CleanupStore), cached 10 min per server:
//  - one light id call per library as the signed-in admin (ParentId=library, MediaSources for the size,
//    ratings, DateCreated): which library every title is in and its facts;
//  - then per enabled user (GET /Users) ONE paged call over all libraries for their UserData (page 500, at most
//    3 users at once). Each user's state is a WatchActivityEntry, so watched/progress use #259's rules.
// Pure rules here, tested in Tests/CleanupTests.swift; view in Classic/Glass3DCleanup.swift.

struct CleanupItem: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String          // "Movie" | "Series"
    let year: Int?
    let libraryId: String?
    let communityRating: Double?
    let criticRating: Double?
    let dateAdded: Date?
    let sizeBytes: Int64?
    /// The item as the pages know it (navigation, Delete…)
    let item: Item?
    /// One entry per user who can see it (enabled and disabled)
    var entries: [WatchActivityEntry] = []
    /// YOUR star rating (1–10, the ★ on the detail page, kept in Trakt); filled in by the view
    var myRating: Int? = nil
    /// TMDB id from ProviderIds (matches Nexview requests)
    var tmdbId: Int? = nil
    /// Nexview requests for this title, oldest first; filled in by the store when Nexview is connected
    var requests: [NexviewRequest] = []

    /// The Rating column: YOUR ★ if you rated it, else the server's community rating
    var shownRating: Double? { myRating.map(Double.init) ?? communityRating }
    /// When it was first requested in Nexview
    var requestedAt: Date? { requests.compactMap(\.requestedAt).min() }
    /// "movie" / "tv", Nexview's media_type
    var nexviewMediaType: String { isSeries ? "tv" : "movie" }

    var isSeries: Bool { type == "Series" }
    private var counted: [WatchActivityEntry] { entries.filter { !$0.user.disabled } }
    var watchedBy: [String] { counted.filter { WatchActivity.state($0, folder: isSeries) == .watched }.map(\.user.name) }
    var inProgressBy: [String] {
        counted.filter { if case .progress = WatchActivity.state($0, folder: isSeries) { return true }; return false }.map(\.user.name)
    }
    var userCount: Int { counted.count }
    var playCount: Int { counted.reduce(0) { $0 + $1.playCount } }
    var lastPlayed: Date? { entries.compactMap(\.lastPlayed).max() }
    var favourites: Int { counted.filter(\.favorite).count }
    /// Last played column: a title marked as watched (or played in another app that kept no date) has no play date,
    /// so it reads "Watched", not "Never" (owner: 1/13 watched but "Never").
    static func lastPlayedText(_ e: CleanupItem) -> String {
        if let d = e.lastPlayed { return LastActive.ago(d) }
        if !e.watchedBy.isEmpty || !e.inProgressBy.isEmpty || e.playCount > 0 { return "Watched" }
        return "Never"
    }
    static func lastPlayedTip(_ e: CleanupItem) -> String {
        if let d = e.lastPlayed { return "Last played " + LastActive.exact(d) }
        if !e.watchedBy.isEmpty || !e.inProgressBy.isEmpty || e.playCount > 0 {
            return "Watched by " + (e.watchedBy + e.inProgressBy).joined(separator: ", ") + " (marked as watched, no play date on the server)"
        }
        return "Never played"
    }
    /// 0…1: how many of the users who can see it watched it all
    var watchedFraction: Double { userCount == 0 ? 0 : Double(watchedBy.count) / Double(userCount) }
    /// Nobody watched any of it (no play, no progress)
    var neverWatched: Bool { watchedBy.isEmpty && inProgressBy.isEmpty && playCount == 0 && lastPlayed == nil }
    /// "0/10"
    var watchedText: String { "\(watchedBy.count)/\(userCount)" }
}

/// The Cleanup list's columns; a click on a header sorts by it, a second click reverses.
enum CleanupColumn: String, CaseIterable, Identifiable {
    case title, watched, rating, added, lastPlayed, size, requested
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Title"
        case .watched: return "Watched"
        case .rating: return "Rating"
        case .added: return "Added"
        case .lastPlayed: return "Last played"
        case .size: return "Size"
        case .requested: return "Requested by"
        }
    }
    /// First click on a header
    var defaultSort: CleanupSort {
        switch self {
        case .title: return .titleAZ
        case .watched: return .leastWatched
        case .rating: return .ratingHighest
        case .added: return .newestAdded
        case .lastPlayed: return .lastPlayedLongAgo
        case .size: return .largest
        case .requested: return .requestedNewest
        }
    }
}

/// One sort state (column + direction), shared by the header row and the Sort dropdown (which keeps its presets).
enum CleanupSort: String, CaseIterable, Identifiable {
    case titleAZ, titleZA, leastWatched, mostWatched, ratingHighest, ratingLowest, myLowest, myHighest, lowestRating, highestRating,
         newestAdded, oldestAdded, lastPlayedLongAgo, lastPlayedRecent, largest, smallest, requestedNewest, requestedOldest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .titleAZ: return "Title A\u{2013}Z"
        case .titleZA: return "Title Z\u{2013}A"
        case .leastWatched: return "Least watched first"
        case .mostWatched: return "Most watched first"
        case .ratingHighest: return "Rating: highest"
        case .ratingLowest: return "Rating: lowest"
        case .myLowest: return "Your rating: lowest"
        case .myHighest: return "Your rating: highest"
        case .lowestRating: return "Server rating: lowest"
        case .highestRating: return "Server rating: highest"
        case .newestAdded: return "Newest added"
        case .oldestAdded: return "Oldest added"
        case .lastPlayedLongAgo: return "Last played long ago"
        case .lastPlayedRecent: return "Last played recently"
        case .largest: return "Largest"
        case .smallest: return "Smallest"
        case .requestedNewest: return "Requested: newest"
        case .requestedOldest: return "Requested: oldest"
        }
    }
    var column: CleanupColumn {
        switch self {
        case .titleAZ, .titleZA: return .title
        case .leastWatched, .mostWatched: return .watched
        case .ratingHighest, .ratingLowest, .myLowest, .myHighest, .lowestRating, .highestRating: return .rating
        case .newestAdded, .oldestAdded: return .added
        case .lastPlayedLongAgo, .lastPlayedRecent: return .lastPlayed
        case .largest, .smallest: return .size
        case .requestedNewest, .requestedOldest: return .requested
        }
    }
    /// Smallest / oldest / A first
    var ascending: Bool {
        switch self {
        case .titleAZ, .leastWatched, .ratingLowest, .myLowest, .lowestRating, .oldestAdded, .lastPlayedLongAgo, .smallest, .requestedOldest:
            return true
        default: return false
        }
    }
    var reversed: CleanupSort {
        switch self {
        case .titleAZ: return .titleZA
        case .titleZA: return .titleAZ
        case .leastWatched: return .mostWatched
        case .mostWatched: return .leastWatched
        case .ratingHighest: return .ratingLowest
        case .ratingLowest: return .ratingHighest
        case .myLowest: return .myHighest
        case .myHighest: return .myLowest
        case .lowestRating: return .highestRating
        case .highestRating: return .lowestRating
        case .newestAdded: return .oldestAdded
        case .oldestAdded: return .newestAdded
        case .lastPlayedLongAgo: return .lastPlayedRecent
        case .lastPlayedRecent: return .lastPlayedLongAgo
        case .largest: return .smallest
        case .smallest: return .largest
        case .requestedNewest: return .requestedOldest
        case .requestedOldest: return .requestedNewest
        }
    }
    /// A header click: same column → reversed, another column → that column's first sort.
    func clicked(_ c: CleanupColumn) -> CleanupSort { column == c ? reversed : c.defaultSort }
}

enum CleanupFilter: String, CaseIterable, Identifiable {
    case all, neverWatched, notInAYear, lowRated, oldUnwatched, requested, requestedUnwatched
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .neverWatched: return "Never watched by anyone"
        case .notInAYear: return "Watched by nobody in 1 year"
        case .lowRated: return "Low rated (<6\u{2605})"
        case .oldUnwatched: return "Not watched, added > 6 months ago"
        case .requested: return "Requested via Nexview"
        case .requestedUnwatched: return "Requested, requester never watched it"
        }
    }
    /// The Nexview filters only when Nexview is connected
    nonisolated static func options(nexview: Bool) -> [CleanupFilter] {
        allCases.filter { nexview || ($0 != .requested && $0 != .requestedUnwatched) }
    }
}

/// Rated or not (owner: tell apart what was rated from what has no rating at all).
enum CleanupRated: String, CaseIterable, Identifiable {
    case any, mine, rated, unrated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: return "Any rating"
        case .mine: return "Rated by you"
        case .rated: return "Has a server rating"
        case .unrated: return "No server rating"
        }
    }
    nonisolated func matches(_ i: CleanupItem) -> Bool {
        switch self {
        case .any: return true
        case .mine: return i.myRating != nil
        case .rated: return i.communityRating != nil
        case .unrated: return i.communityRating == nil
        }
    }
}

enum CleanupKind: String, CaseIterable, Identifiable {
    case both, movies, series
    var id: String { rawValue }
    var title: String {
        switch self { case .both: return "Movies & series"; case .movies: return "Movies"; case .series: return "Series" }
    }
}

enum Cleanup {
    nonisolated static let pageSize = 500
    nonisolated static let maxConcurrentUsers = 3
    nonisolated static let cacheSeconds: TimeInterval = 600
    nonisolated static let lowRating = 6.0
    nonisolated static let year: TimeInterval = 365 * 86_400
    nonisolated static let sixMonths: TimeInterval = 182 * 86_400

    // MARK: Requests

    /// The admin's facts call for one library (one page).
    nonisolated static func libraryPath(userId: String, libraryId: String, start: Int) -> String {
        "/Users/\(userId)/Items?ParentId=\(libraryId)&Recursive=true&IncludeItemTypes=Movie,Series"
            + "&Fields=DateCreated,ProviderIds,MediaSources,CriticRating,CommunityRating,RecursiveItemCount,Path"
            + "&EnableUserData=false&EnableImageTypes=Primary&ImageTypeLimit=1"
            + "&SortBy=SortName&StartIndex=\(start)&Limit=\(pageSize)"
    }

    /// One user's watch state over all libraries (one page).
    nonisolated static func userPath(userId: String, start: Int) -> String {
        "/Users/\(userId)/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=RecursiveItemCount,UserDataPlayCount,UserDataLastPlayedDate"
            + "&EnableUserData=true&EnableImages=false&SortBy=SortName&StartIndex=\(start)&Limit=\(pageSize)"
    }

    /// One page → its item objects and the total (nil when the server didn't say).
    nonisolated static func page(_ data: Data) -> (items: [[String: Any]], total: Int?) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        return (o["Items"] as? [[String: Any]] ?? [], (o["TotalRecordCount"] as? NSNumber)?.intValue)
    }

    /// Whether another page is needed after `fetched` items, the last page having `lastCount`.
    nonisolated static func needsMore(fetched: Int, lastCount: Int, total: Int?) -> Bool {
        guard lastCount > 0 else { return false }
        if let total { return fetched < total }
        return lastCount >= pageSize
    }

    /// The admin's library call item → the facts.
    nonisolated static func item(_ o: [String: Any], libraryId: String?) -> CleanupItem? {
        guard let id = o["Id"] as? String, let type = o["Type"] as? String, ["Movie", "Series"].contains(type) else { return nil }
        let sizes = (o["MediaSources"] as? [[String: Any]] ?? []).compactMap { ($0["Size"] as? NSNumber)?.int64Value }
        let decoded = (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
        return CleanupItem(id: id, name: o["Name"] as? String ?? "", type: type,
                           year: (o["ProductionYear"] as? NSNumber)?.intValue, libraryId: libraryId,
                           communityRating: (o["CommunityRating"] as? NSNumber)?.doubleValue,
                           criticRating: (o["CriticRating"] as? NSNumber)?.doubleValue,
                           dateAdded: (o["DateCreated"] as? String).flatMap(WatchActivity.isoDate),
                           sizeBytes: type == "Movie" && !sizes.isEmpty ? sizes.reduce(0, +) : nil,
                           item: decoded,
                           tmdbId: tmdbId(o["ProviderIds"] as? [String: Any]))
    }

    /// ProviderIds "Tmdb" (any case) → Int
    nonisolated static func tmdbId(_ ids: [String: Any]?) -> Int? {
        guard let v = ids?.first(where: { $0.key.lowercased() == "tmdb" })?.value else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        return (v as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Adds one user's page to the items (titles the admin can't see are skipped).
    nonisolated static func merge(_ userItems: [[String: Any]], user: WatchActivityUser, into items: inout [String: CleanupItem]) {
        for o in userItems {
            guard let id = o["Id"] as? String, items[id] != nil else { continue }
            let (e, _) = WatchActivity.entry(item: o, user: user)
            items[id]!.entries.removeAll { $0.user.id == user.id }
            items[id]!.entries.append(e)
        }
    }

    // MARK: Filter, sort, summary

    nonisolated static func matches(_ i: CleanupItem, filter: CleanupFilter, now: Date = Date()) -> Bool {
        switch filter {
        case .all: return true
        case .neverWatched: return i.neverWatched
        case .notInAYear: return (i.lastPlayed ?? .distantPast) < now.addingTimeInterval(-year)
        case .lowRated: return (i.communityRating ?? 99) < lowRating
        case .oldUnwatched: return i.watchedBy.isEmpty && (i.dateAdded ?? now) < now.addingTimeInterval(-sixMonths)
        case .requested: return !i.requests.isEmpty
        case .requestedUnwatched: return !i.requests.isEmpty && !NexviewMatch.anyRequesterWatched(i)
        }
    }

    nonisolated static func matches(_ i: CleanupItem, kind: CleanupKind) -> Bool {
        switch kind { case .both: return true; case .movies: return !i.isSeries; case .series: return i.isSeries }
    }

    nonisolated static func filtered(_ items: [CleanupItem], library: String?, kind: CleanupKind, filter: CleanupFilter,
                                     now: Date = Date()) -> [CleanupItem] {
        items.filter { (library == nil || $0.libraryId == library) && matches($0, kind: kind) && matches($0, filter: filter, now: now) }
    }

    /// Title search (any word order, ignores case and accents; also matches the year).
    nonisolated static func searched(_ items: [CleanupItem], _ query: String) -> [CleanupItem] {
        let words = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return items }
        return items.filter { i in
            let hay = i.name + " " + (i.year.map(String.init) ?? "")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Known values in the asked direction, unknown (nil) always last; nil result = tie.
    nonisolated static func order<T: Comparable>(_ x: T?, _ y: T?, ascending: Bool) -> Bool? {
        switch (x, y) {
        case let (a?, b?): return a == b ? nil : (ascending ? a < b : a > b)
        case (nil, _?): return false
        case (_?, nil): return true
        default: return nil
        }
    }

    nonisolated static func sorted(_ items: [CleanupItem], by sort: CleanupSort) -> [CleanupItem] {
        func added(_ i: CleanupItem) -> Date { i.dateAdded ?? .distantPast }
        func name(_ a: CleanupItem, _ b: CleanupItem) -> Bool {
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? a.id < b.id : r == .orderedAscending
        }
        let asc = sort.ascending
        return items.sorted { a, b in
            switch sort {
            case .titleAZ, .titleZA:
                let r = a.name.localizedStandardCompare(b.name)
                if r == .orderedSame { return a.id < b.id }
                return asc ? r == .orderedAscending : r == .orderedDescending
            case .leastWatched, .mostWatched:
                if a.watchedFraction != b.watchedFraction { return asc ? a.watchedFraction < b.watchedFraction : a.watchedFraction > b.watchedFraction }
                if a.playCount != b.playCount { return asc ? a.playCount < b.playCount : a.playCount > b.playCount }
                if added(a) != added(b) { return asc ? added(a) < added(b) : added(a) > added(b) }
                return name(a, b)
            case .ratingHighest, .ratingLowest:
                return order(a.shownRating, b.shownRating, ascending: asc) ?? name(a, b)
            case .myLowest, .myHighest:
                return order(a.myRating, b.myRating, ascending: asc) ?? name(a, b)
            case .lowestRating, .highestRating:
                return order(a.communityRating, b.communityRating, ascending: asc) ?? name(a, b)
            case .oldestAdded, .newestAdded:
                return order(a.dateAdded, b.dateAdded, ascending: asc) ?? name(a, b)
            case .lastPlayedLongAgo, .lastPlayedRecent:
                return order(a.lastPlayed, b.lastPlayed, ascending: asc) ?? name(a, b)
            case .largest, .smallest:
                return order(a.sizeBytes, b.sizeBytes, ascending: asc) ?? name(a, b)
            case .requestedNewest, .requestedOldest:
                return order(a.requestedAt, b.requestedAt, ascending: asc) ?? name(a, b)
            }
        }
    }

    struct Summary: Equatable {
        let titles: Int
        let neverWatched: Int
        let sizeBytes: Int64?
        var text: String {
            var s = "\(titles) title" + (titles == 1 ? "" : "s") + " · \(neverWatched) never watched"
            if let b = sizeBytes, b > 0 { s += " · " + ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            return s
        }
    }

    nonisolated static func summary(_ items: [CleanupItem]) -> Summary {
        let sizes = items.compactMap(\.sizeBytes)
        return Summary(titles: items.count, neverWatched: items.filter(\.neverWatched).count,
                       sizeBytes: sizes.isEmpty ? nil : sizes.reduce(0, +))
    }

    /// "Reading 3 of 5 users…"
    nonisolated static func progressText(done: Int, total: Int) -> String {
        total == 0 ? "Reading the libraries\u{2026}" : "Reading \(min(done + 1, total)) of \(total) users\u{2026}"
    }

    /// The Size sort only makes sense when some title has a size.
    /// The Size sorts only make sense when some title has a size, the Requested ones when Nexview is connected.
    nonisolated static func sorts(hasSize: Bool, hasRequests: Bool = false) -> [CleanupSort] {
        CleanupSort.allCases.filter { (hasSize || $0.column != .size) && (hasRequests || $0.column != .requested) }
    }
}

/// Several deletes one after another; stops at the first error (the rest stay untouched).
@MainActor
enum CleanupDeleteQueue {
    struct Result: Equatable {
        var done: [String] = []
        var failed: (id: String, message: String)?
        var skipped: [String] = []
        static func == (a: Result, b: Result) -> Bool {
            a.done == b.done && a.skipped == b.skipped && a.failed?.id == b.failed?.id && a.failed?.message == b.failed?.message
        }
    }

    static func run(_ ids: [String], progress: (Int, Int) async -> Void = { _, _ in },
                    delete: (String) async -> String?) async -> Result {
        var r = Result()
        for (n, id) in ids.enumerated() {
            if Task.isCancelled { r.skipped = Array(ids[n...]); break }
            await progress(n, ids.count)
            if let m = await delete(id) {
                r.failed = (id, m)
                r.skipped = Array(ids[(n + 1)...])
                break
            }
            r.done.append(id)
        }
        return r
    }
}

/// Loads and caches (10 min per server) the cleanup list.
@MainActor
final class CleanupStore: ObservableObject {
    static let shared = CleanupStore()
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var libraries: [(id: String, name: String)] = []
    @Published private(set) var loading = false
    @Published private(set) var progress: String?
    @Published private(set) var error: String?
    /// Nexview couldn't be read (the list still shows, without requests)
    @Published private(set) var nexviewError: String?
    private var loadedAt: Date?
    private var key = ""

    func remove(_ ids: Set<String>) { items.removeAll { ids.contains($0.id) } }

    func load(_ emby: Emby, force: Bool = false) async {
        let nexview = NexviewConnection.shared
        let k = emby.server.lowercased() + "|" + emby.userId + "|" + (nexview.configured ? "nexview" : "")
        if !force, k == key, let at = loadedAt, Date().timeIntervalSince(at) < Cleanup.cacheSeconds { return }
        guard !loading else { return }
        if k != key { items = []; libraries = [] }
        key = k; loading = true; error = nil
        defer { loading = false; progress = nil }
        await emby.ensureLibs()
        let libs = emby.libs.filter { [nil, "movies", "tvshows", "mixed", "homevideos"].contains($0.kind) }
        let server = emby.server, me = emby.userId
        func get(_ path: String) async -> Data? {
            guard let u = URL(string: server + path) else { return nil }
            var r = URLRequest(url: u, timeoutInterval: 60); emby.authorize(&r)
            guard let (d, resp) = try? await Net.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return d
        }
        func pages(_ path: (Int) -> String) async -> [[String: Any]]? {
            var all: [[String: Any]] = []
            while true {
                guard let d = await get(path(all.count)) else { return all.isEmpty ? nil : all }
                let p = Cleanup.page(d)
                all += p.items
                if !Cleanup.needsMore(fetched: all.count, lastCount: p.items.count, total: p.total) { return all }
            }
        }
        progress = Cleanup.progressText(done: 0, total: 0)
        var map: [String: CleanupItem] = [:]
        for l in libs {
            for o in await pages({ Cleanup.libraryPath(userId: me, libraryId: l.id, start: $0) }) ?? [] {
                if let i = Cleanup.item(o, libraryId: l.id), map[i.id] == nil { map[i.id] = i }
            }
        }
        guard let ud = await get("/Users") else { error = "Couldn't read the server's users."; return }
        let users = WatchActivity.users(ud).filter { !$0.disabled }
        var done = 0
        progress = Cleanup.progressText(done: 0, total: users.count)
        await withTaskGroup(of: (WatchActivityUser, [[String: Any]]?).self) { g in
            var i = 0
            func next() {
                guard i < users.count else { return }
                let u = users[i]; i += 1
                g.addTask { (u, await pages({ Cleanup.userPath(userId: u.id, start: $0) })) }
            }
            for _ in 0..<Cleanup.maxConcurrentUsers { next() }
            while let (u, rows) = await g.next() {
                if let rows { Cleanup.merge(rows, user: u, into: &map) }
                else { DebugLog.write("cleanup: couldn't read user \(u.id.prefix(6))") }
                done += 1
                progress = Cleanup.progressText(done: done, total: users.count)
                next()
            }
        }
        guard key == k else { return }
        nexviewError = nil
        if nexview.configured {
            switch await nexview.requests() {
            case .success(let reqs): NexviewMatch.attach(reqs, to: &map)
            case .failure(let e): nexviewError = e.message
            }
        }
        guard key == k else { return }
        let gone = Set(DeletedItems.shared.records.map(\.itemId))
        items = map.values.filter { !gone.contains($0.id) }
        libraries = libs.map { ($0.id, $0.title) }
        loadedAt = Date()
        DebugLog.write("cleanup: \(items.count) titles, \(users.count) users, \(libs.count) libraries")
    }
}
