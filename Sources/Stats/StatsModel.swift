import SwiftUI

/// The Stats tabs' state (Now Playing → Overview / History), kept while switching tabs.
@MainActor
final class StatsModel: ObservableObject {
    @Published var availability: StatsAvailability?
    @Published var range: StatsRange = .month
    @Published var overview: [StatsPlay] = []
    @Published var overviewLoading = false
    @Published var history: [StatsPlay] = []
    @Published var historyLoading = false
    @Published var historyDays: [String] = []      // days with activity, newest first
    @Published var historyShown = 0                // how many of them are loaded
    @Published var users: [StatsUserSummary] = []
    @Published var usersLoading = false
    @Published var usersRange: StatsRange?        // the range `users` was loaded for
    @Published var selectedUser: StatsUserSummary?   // Users tab drill-down: that user's Overview
    @Published var userOverview: [StatsPlay] = []
    @Published var userOverviewLoading = false
    @Published var allPlays: [StatsPlay] = []       // every user's plays in `allPlaysRange` (Users → Graphs / Libraries)
    @Published var allPlaysRange: StatsRange?
    @Published var graphs: StatsGraphsData?
    @Published var graphsRange: StatsRange?
    @Published var graphsLoading = false
    @Published var libraries: [StatsLibraryUsage] = []
    @Published var librariesRange: StatsRange?
    @Published var librariesLoading = false
    @Published var librariesTruncated = false       // more played items than `libraryMapLimit`: the rest left out
    @Published var fallback: [Item] = []
    @Published var fallbackLoaded = false

    /// History loads this many active days at a time ("Show more" adds the next ones).
    static let historyPage = 7
    /// History looks back this far.
    static let historyRange = 90

    private var service: (any StatsService)?
    private var userId = ""
    private var sessionKey = ""
    private var dayCache: [String: [StatsPlay]] = [:]   // closed past days never change
    private var userDayCache: [String: [StatsPlay]] = [:]   // "userId|day" → plays (Users tab)
    private var libraryMap: [String: String] = [:]          // item id → library id ("" = in none)
    private var libraryCounts: [String: [StatsLibCount]] = [:]
    /// Libraries maps at most this many distinct played items per load (the most recent ones).
    static let libraryMapLimit = 1500

    func start(_ emby: Emby) async {
        let key = StatsAvailabilityCache.key(server: emby.server, userId: emby.userId)
        if key != sessionKey {   // another server or user: nothing of the previous one stays
            sessionKey = key
            overview = []; history = []; historyDays = []; historyShown = 0; fallback = []; fallbackLoaded = false
            dayCache = [:]; availability = nil
            users = []; usersRange = nil; userDayCache = [:]; selectedUser = nil; userOverview = []
            allPlays = []; allPlaysRange = nil; graphs = nil; graphsRange = nil
            libraries = []; librariesRange = nil; librariesTruncated = false; libraryMap = [:]; libraryCounts = [:]
        }
        userId = emby.userId
        let fetch = emby.statsFetcher()
        service = StatsServices.make(isJellyfin: emby.isJellyfin, fetch: fetch)
        if let a = StatsAvailabilityCache.results[key] { availability = a; return }
        let a = await StatsServices.detect(userId: emby.userId, fetch: fetch)
        if a != .failed { StatsAvailabilityCache.results[key] = a }   // a failure is tried again next time
        availability = a
    }

    func loadFallback(_ emby: Emby) async {
        guard !fallbackLoaded else { return }
        fallback = await emby.recentlyPlayed()
        fallbackLoaded = true
    }

    func loadOverview() async {
        guard let service, availability == .available else { return }
        overviewLoading = true
        defer { overviewLoading = false }
        let usage = (try? await service.activity(userId: userId, days: range.days)) ?? [:]
        let days = StatsAggregate.activeDays(usage)
        let plays = await fetchDays(days, service)
        guard !Task.isCancelled else { return }
        overview = StatsAggregate.inRange(plays, range)
    }

    /// Users tab drill-down: the selected user's plays in the range (same rules as Overview, cached per user/day).
    func loadUserOverview() async {
        guard let service, availability == .available, let u = selectedUser else { return }
        let range = self.range
        userOverviewLoading = true
        defer { userOverviewLoading = false }
        let usage = (try? await service.activity(userId: u.id, days: range.days)) ?? [:]
        let days = StatsAggregate.activeDays(usage)
        let today = StatsDecode.dayFormat.string(from: Date())
        let missing = days.filter { $0 == today || userDayCache[u.id + "|" + $0] == nil }
        if !missing.isEmpty {
            let got = await service.plays(userId: u.id, days: missing)
            let byDay = Dictionary(grouping: got, by: \.day)
            for d in missing { userDayCache[u.id + "|" + d] = byDay[d] ?? [] }
        }
        guard !Task.isCancelled, u.id == selectedUser?.id, range == self.range else { return }
        userOverview = StatsAggregate.inRange(days.flatMap { userDayCache[u.id + "|" + $0] ?? [] }, range)
    }

    func loadHistory() async {
        guard let service, availability == .available, historyDays.isEmpty else { return }
        historyLoading = true
        defer { historyLoading = false }
        let usage = (try? await service.activity(userId: userId, days: Self.historyRange)) ?? [:]
        historyDays = StatsAggregate.activeDays(usage)
        await loadMoreHistory()
    }

    var hasMoreHistory: Bool { historyShown < historyDays.count }

    func loadMoreHistory() async {
        guard let service, hasMoreHistory else { return }
        historyLoading = true
        defer { historyLoading = false }
        let next = Array(historyDays[historyShown..<min(historyShown + Self.historyPage, historyDays.count)])
        let plays = await fetchDays(next, service)
        history += plays
        historyShown += next.count
    }

    private func fetchDays(_ days: [String], _ service: any StatsService) async -> [StatsPlay] {
        let today = StatsDecode.dayFormat.string(from: Date())
        let missing = days.filter { $0 == today || dayCache[$0] == nil }
        if !missing.isEmpty {
            let got = await service.plays(userId: userId, days: missing)
            let byDay = Dictionary(grouping: got, by: \.day)
            for d in missing { dayCache[d] = byDay[d] ?? [] }
        }
        return days.flatMap { dayCache[$0] ?? [] }
    }

    /// Users tab: every server user, their plays in the range (only days PlayActivity marks active, ≤ 4 requests
    /// at a time, past days cached), aggregated into cards, most watch time first.
    func loadUsers() async {
        guard let service, availability == .available else { return }
        let range = self.range
        usersLoading = true
        defer { usersLoading = false }
        guard let list = try? await service.serverUsers() else { return }
        let usage = (try? await service.activityAll(days: range.days)) ?? [:]
        let today = StatsDecode.dayFormat.string(from: Date())
        var out: [StatsUserSummary] = []
        var all: [StatsPlay] = []
        for u in list {
            if Task.isCancelled { return }
            let days = StatsAggregate.activeDays(usage[StatsDecode.norm(u.id)] ?? [:])
            let missing = days.filter { $0 == today || userDayCache[u.id + "|" + $0] == nil }
            if !missing.isEmpty {
                let got = await service.plays(userId: u.id, days: missing)
                let byDay = Dictionary(grouping: got, by: \.day)
                for d in missing { userDayCache[u.id + "|" + d] = byDay[d] ?? [] }
            }
            let plays = StatsAggregate.inRange(days.flatMap { userDayCache[u.id + "|" + $0] ?? [] }, range)
            out.append(StatsUsersAggregate.summary(u, plays: plays))
            all += plays
        }
        guard !Task.isCancelled, range == self.range else { return }
        users = StatsUsersAggregate.sorted(out)
        usersRange = range
        allPlays = all
        allPlaysRange = range
    }

    /// Every user's plays in the current range: reused from the Users tab when it loaded the same range.
    private func ensureAllPlays() async -> Bool {
        if allPlaysRange != range { await loadUsers() }
        return allPlaysRange == range && !Task.isCancelled
    }

    /// Graphs tab: every user's plays in the range, aggregated off the main thread.
    func loadGraphs() async {
        guard availability == .available, graphsRange != range || graphs == nil else { return }
        let range = self.range
        graphsLoading = true
        defer { graphsLoading = false }
        guard await ensureAllPlays() else { return }
        let plays = allPlays
        let data = await Task.detached(priority: .userInitiated) { StatsGraphsAggregate.data(plays, range) }.value
        guard !Task.isCancelled, range == self.range else { return }
        graphs = data
        graphsRange = range
    }

    /// Libraries tab: the movie / TV / music libraries with their size, plays and watch time in the range.
    /// Played items are mapped to a library once (cached per item): per library, which of these ids it holds
    /// (`ParentId` + `Ids`); an id claimed by several libraries (a server ignoring ParentId there) is settled by
    /// its ancestors.
    func loadLibraries(_ emby: Emby) async {
        guard let service, availability == .available, librariesRange != range || libraries.isEmpty else { return }
        let range = self.range
        librariesLoading = true
        defer { librariesLoading = false }
        await emby.ensureLibs()
        let libs = emby.libs.filter { StatsLibrariesAggregate.eligible($0.kind) }
            .map { StatsLibraryInfo(id: $0.id, name: $0.title.isEmpty ? $0.name : $0.title, kind: $0.kind) }
        guard await ensureAllPlays() else { return }
        let uid = emby.userId, fetch = service.fetch
        for l in libs where libraryCounts[l.id] == nil {
            libraryCounts[l.id] = await Self.counts(l, userId: uid, fetch: fetch)
        }
        let plays = allPlays
        let want = StatsLibrariesAggregate.unmapped(plays, known: libraryMap, limit: Self.libraryMapLimit)
        if !want.ids.isEmpty {
            var found: [String: [String]] = [:]   // item id → libraries that said they hold it
            for l in libs {
                if Task.isCancelled { return }
                for id in await Self.held(want.ids, library: l.id, userId: uid, fetch: fetch) { found[id, default: []].append(l.id) }
            }
            for (id, ls) in found {
                if ls.count == 1 { libraryMap[id] = ls[0] }
                else if let a = await Self.ancestorLibrary(id, libs: Set(ls), fetch: fetch) { libraryMap[id] = a }
            }
            StatsLibrariesAggregate.markMissing(want.ids, into: &libraryMap)
        }
        let map = libraryMap, counts = libraryCounts
        let out = await Task.detached(priority: .userInitiated) {
            StatsLibrariesAggregate.usage(libs, plays: plays, map: map, counts: counts)
        }.value
        guard !Task.isCancelled, range == self.range else { return }
        libraries = out
        librariesTruncated = want.truncated
        librariesRange = range
    }

    private nonisolated static func counts(_ l: StatsLibraryInfo, userId: String, fetch: StatsFetch) async -> [StatsLibCount] {
        var out: [StatsLibCount] = []
        for t in StatsLibrariesAggregate.countTypes(l.kind) {
            let q = ["ParentId": l.id, "Recursive": "true", "IncludeItemTypes": t.type, "Limit": "0", "EnableImages": "false"]
            if let r = await fetch("/Users/\(userId)/Items", q), (200..<300).contains(r.status),
               let n = StatsLibrariesAggregate.total(r.data) { out.append(StatsLibCount(label: t.label, count: n)) }
        }
        return out
    }

    /// Which of `ids` the library holds (60 ids per request, 4 requests at a time).
    private nonisolated static func held(_ ids: [String], library: String, userId: String, fetch: @escaping StatsFetch) async -> [String] {
        let chunks = stride(from: 0, to: ids.count, by: 60).map { Array(ids[$0..<min($0 + 60, ids.count)]) }
        var out: [String] = []
        var i = 0
        while i < chunks.count {
            await withTaskGroup(of: [String].self) { g in
                for c in chunks[i..<min(i + 4, chunks.count)] {
                    g.addTask {
                        let q = ["ParentId": library, "Recursive": "true", "Ids": c.joined(separator: ","),
                                 "EnableImages": "false", "EnableUserData": "false"]
                        guard let r = await fetch("/Users/\(userId)/Items", q), (200..<300).contains(r.status) else { return [] }
                        let asked = Set(c)
                        return StatsLibrariesAggregate.ids(r.data).filter { asked.contains($0) }
                    }
                }
                for await r in g { out += r }
            }
            i += 4
        }
        return out
    }

    /// The library among `libs` that is one of the item's ancestors.
    private nonisolated static func ancestorLibrary(_ id: String, libs: Set<String>, fetch: StatsFetch) async -> String? {
        guard let r = await fetch("/Items/\(id)/Ancestors", [:]), (200..<300).contains(r.status),
              let arr = (try? JSONSerialization.jsonObject(with: r.data)) as? [[String: Any]] else { return nil }
        return arr.map { StatsDecode.string($0["Id"]) }.first { libs.contains($0) }
    }
}
