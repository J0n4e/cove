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

    func start(_ emby: Emby) async {
        let key = StatsAvailabilityCache.key(server: emby.server, userId: emby.userId)
        if key != sessionKey {   // another server or user: nothing of the previous one stays
            sessionKey = key
            overview = []; history = []; historyDays = []; historyShown = 0; fallback = []; fallbackLoaded = false
            dayCache = [:]; availability = nil
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
}
