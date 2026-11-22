import SwiftUI

/// Activity → Insights and Year in review: their state, kept while switching tabs. The plays come from
/// StatsModel's cached per-user day loader (the same requests as the Users tab), so no new raw-data paths.
@MainActor
final class InsightsModel: ObservableObject {
    /// Insights offers 30 days · 12 months · All (as Graphs).
    static let ranges: [StatsRange] = [.month, .year, .all]

    @Published var range: StatsRange = .month
    @Published var data: InsightsData?
    @Published var dataRange: StatsRange?
    @Published var loading = false
    @Published var maxDataAge: Int?             // months the plugin keeps (nil = unknown, -1 = everything)

    // Year in review
    @Published var users: [StatsServerUser] = []
    @Published var yearUserId: String = ""      // whose year (admins can pick; others: themselves)
    @Published var years: [Int] = []
    @Published var year: Int = Calendar.current.component(.year, from: Date())
    @Published var review: YearReview?
    @Published var reviewKey = ""               // "user|year" the review is for
    @Published var reviewLoading = false
    @Published var limited = false              // built from the normal API (no plugin data)

    private var sessionKey = ""
    private var genreMap: [String: [String]] = [:]   // item id → genres (episodes: their series' genres)
    private var fallbackPlays: [StatsPlay]?
    private var retentionLoaded = false
    /// Genres are looked up for at most this many distinct played items per load (the most recent ones).
    static let genreLimit = 1500

    private func reset(_ stats: StatsModel) {
        guard stats.currentSessionKey != sessionKey else { return }
        sessionKey = stats.currentSessionKey
        data = nil; dataRange = nil; maxDataAge = nil; retentionLoaded = false
        users = []; yearUserId = ""; years = []; review = nil; reviewKey = ""; limited = false
        genreMap = [:]; fallbackPlays = nil
    }

    // MARK: Insights

    func loadInsights(_ stats: StatsModel, _ emby: Emby) async {
        reset(stats)
        guard let service = stats.statsService, stats.availability == .available, dataRange != range || data == nil else { return }
        let range = self.range
        loading = true
        defer { loading = false }
        await loadRetention(service.fetch)
        if users.isEmpty, let u = try? await service.serverUsers() { users = u }
        let usage = (try? await service.activityAll(days: Insights.lookback(range))) ?? [:]
        let current = Set(StatsAggregate.days(range)), previous = Set(Insights.previousDays(range))
        var cur: [StatsPlay] = [], prev: [StatsPlay] = []
        for u in users {
            if Task.isCancelled { return }
            let days = StatsAggregate.activeDays(usage[StatsDecode.norm(u.id)] ?? [:])
            guard !days.isEmpty else { continue }
            let ps = await stats.cachedUserPlays(u.id, name: u.name, days: days)
            cur += ps.filter { current.contains($0.day) }
            prev += ps.filter { previous.contains($0.day) }
        }
        await loadGenres(cur, emby: emby, fetch: service.fetch)
        guard !Task.isCancelled, range == self.range else { return }
        let genres = genreMap, hasPrev = range != .all, c = cur, p = prev
        let out = await Task.detached(priority: .userInitiated) {
            Insights.data(current: c, previous: p, hasPrevious: hasPrev, genres: genres)
        }.value
        guard !Task.isCancelled, range == self.range else { return }
        data = out
        dataRange = range
    }

    /// The plugin's Max data age (admin only): Emby's named configuration, then Jellyfin's plugin configuration.
    private func loadRetention(_ fetch: StatsFetch) async {
        guard !retentionLoaded else { return }
        retentionLoaded = true
        if let r = await fetch("/System/Configuration/playback_reporting", [:]), (200..<300).contains(r.status),
           let m = InsightsRetention.maxDataAge(r.data) { maxDataAge = m; return }
        if let r = await fetch("/Plugins", [:]), (200..<300).contains(r.status), let id = InsightsRetention.pluginId(r.data),
           let c = await fetch("/Plugins/\(id)/Configuration", [:]), (200..<300).contains(c.status) {
            maxDataAge = InsightsRetention.maxDataAge(c.data)
        }
    }

    /// Item → genres for the played items not looked up yet (60 ids per request); episodes without genres of
    /// their own get their series' genres.
    private func loadGenres(_ plays: [StatsPlay], emby: Emby, fetch: StatsFetch) async {
        var want: [String] = [], seen = Set<String>()
        for p in plays.sorted(by: { $0.start > $1.start }) where genreMap[p.itemId] == nil && !p.itemId.isEmpty {
            if seen.insert(p.itemId).inserted { want.append(p.itemId) }
            if want.count == Self.genreLimit { break }
        }
        guard !want.isEmpty else { return }
        let uid = emby.userId
        let got = await Self.lookup(want, userId: uid, fetch: fetch)
        var series: [String: [String]] = [:]   // series id → episodes needing its genres
        for id in want {
            let g = got[id]
            if let g, !g.genres.isEmpty { genreMap[id] = g.genres }
            else if let s = g?.series { series[s, default: []].append(id) }
            else { genreMap[id] = [] }
        }
        if !series.isEmpty {
            let sg = await Self.lookup(Array(series.keys), userId: uid, fetch: fetch)
            for (s, eps) in series { for e in eps { genreMap[e] = sg[s]?.genres ?? [] } }
        }
    }

    private nonisolated static func lookup(_ ids: [String], userId: String, fetch: StatsFetch) async -> [String: (genres: [String], series: String?)] {
        var out: [String: (genres: [String], series: String?)] = [:]
        for start in stride(from: 0, to: ids.count, by: 60) {
            if Task.isCancelled { break }
            let c = ids[start..<min(start + 60, ids.count)]
            let q = ["Ids": c.joined(separator: ","), "Fields": "Genres", "EnableImages": "false", "EnableUserData": "false"]
            if let r = await fetch("/Users/\(userId)/Items", q), (200..<300).contains(r.status) {
                out.merge(InsightsDecode.genres(r.data)) { a, _ in a }
            }
        }
        return out
    }

    // MARK: Year in review

    var yearKey: String { yearUserId + "|\(year)" }

    /// Admins with the plugin: the users to pick from and the years with data; everyone else: themselves.
    func prepareYear(_ stats: StatsModel, _ emby: Emby) async {
        reset(stats)
        if yearUserId.isEmpty { yearUserId = emby.userId }
        guard years.isEmpty else { return }
        if stats.availability == .available, let service = stats.statsService {
            await loadRetention(service.fetch)
            if users.isEmpty, let u = try? await service.serverUsers() { users = u }
            let usage = (try? await service.activity(userId: yearUserId, days: StatsRange.all.days)) ?? [:]
            years = YearAggregate.years(days: StatsAggregate.activeDays(usage))
        } else {
            let ps = await fallback(emby)
            years = YearAggregate.years(days: ps.map(\.day))
        }
        if !years.contains(year), let y = years.first { year = y }
    }

    func loadYear(_ stats: StatsModel, _ emby: Emby) async {
        reset(stats)
        let key = yearKey, year = self.year, uid = yearUserId
        guard !uid.isEmpty, reviewKey != key || review == nil else { return }
        reviewLoading = true
        defer { reviewLoading = false }
        let plays: [StatsPlay]
        if stats.availability == .available, let service = stats.statsService {
            limited = false
            let days = YearAggregate.days(year)
            guard let last = days.last.flatMap({ StatsDecode.dayFormat.date(from: $0) }) else { return }
            let usage = (try? await service.activity(userId: uid, days: days.count, end: last)) ?? [:]
            let active = Set(days)
            let want = StatsAggregate.activeDays(usage).filter { active.contains($0) }
            let name = users.first { $0.id == uid }?.name ?? ""
            plays = await stats.cachedUserPlays(uid, name: name, days: want)
            await loadGenres(plays, emby: emby, fetch: service.fetch)
        } else {
            limited = true
            plays = await fallback(emby)
        }
        guard !Task.isCancelled, key == yearKey else { return }
        let genres = genreMap, all = plays
        let out = await Task.detached(priority: .userInitiated) { YearAggregate.review(all, year: year, genres: genres) }.value
        guard !Task.isCancelled, key == yearKey else { return }
        review = out
        reviewKey = key
    }

    /// Non-admins: played movies and episodes from the normal API (one entry per item, its last play date).
    private func fallback(_ emby: Emby) async -> [StatsPlay] {
        if let fallbackPlays { return fallbackPlays }
        let q = ["Filters": "IsPlayed", "Recursive": "true", "IncludeItemTypes": "Movie,Episode", "SortBy": "DatePlayed",
                 "SortOrder": "Descending", "Limit": "5000", "Fields": "Genres,RunTimeTicks,UserData", "EnableImages": "false"]
        var out: [StatsPlay] = []
        if let r = await emby.statsFetcher()("/Users/\(emby.userId)/Items", q), (200..<300).contains(r.status) {
            let d = InsightsDecode.playedItems(r.data)
            out = d.plays
            genreMap.merge(d.genres) { a, _ in a }
        }
        fallbackPlays = out
        return out
    }
}
