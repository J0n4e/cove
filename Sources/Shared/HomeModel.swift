import SwiftUI

/// Home's rows and banner items, shared by the Glass and Classic views (they keep only layout and styling).
@MainActor
final class HomeModel: ObservableObject {
    @Published var rows: [Row] = []
    @Published var loading = true
    /// Bumped by the error state's Try again; part of the view's reload key.
    @Published var retryCount = 0
    /// Glass starts downloading the first pictures of every row right after loading; Classic doesn't (it never did).
    let prefetchRows: Bool

    private weak var emby: Emby?
    private let loader: (() async -> [Row])?
    /// Settings → Home → Banner shows: the banner's own titles (nil = use the rows). Tests stub both closures.
    private let heroLoader: ((BannerSource) async -> [Item]?)?
    private let sourceProvider: () -> BannerSource
    @Published private(set) var heroSource: BannerSource
    @Published private(set) var heroFetched: [Item]?
    private let defaultsObserver = ObserverToken()

    // Settings → Home → Banner → Refresh banner: a fresh set every N minutes while Cove stays open.
    /// Which rotation of the Home rows the banner shows ("From Home rows"; 0 = today's first two per row).
    @Published private(set) var heroRound = 0
    /// Bumped whenever a refresh swaps the banner's set; the banner views use it as their id, so the new
    /// set crossfades in and starts at slide 1.
    @Published private(set) var heroGeneration = 0
    private let intervalProvider: () -> Int
    private let visibleProvider: @MainActor () -> Bool
    private let playingProvider: @MainActor () -> Bool
    private let clock: () -> Date
    private(set) var heroInterval = 0
    private(set) var lastHeroRefresh = Date()
    private let refreshHolder = TaskHolder()
    /// The banner's picture width (window width × 2, at most 2560), so a refresh prefetches the same URLs it shows.
    static var bannerImageWidth = 2560

    init(prefetchRows: Bool, load: (() async -> [Row])? = nil,
         heroLoad: ((BannerSource) async -> [Item]?)? = nil, source: (() -> BannerSource)? = nil,
         refreshEvery: (() -> Int)? = nil, visible: (@MainActor () -> Bool)? = nil,
         playing: (@MainActor () -> Bool)? = nil, now: (() -> Date)? = nil) {
        self.prefetchRows = prefetchRows
        self.loader = load
        self.heroLoader = heroLoad
        let provider = source ?? { BannerSource.current }
        self.sourceProvider = provider
        self.heroSource = provider()
        self.intervalProvider = refreshEvery ?? { BannerRefresh.current }
        self.visibleProvider = visible ?? { AppVisibility.isVisible }
        self.playingProvider = playing ?? { PlaybackFlag.shared.active }
        self.clock = now ?? { Date() }
        // Changing the setting reloads the banner at once (Settings is another window)
        defaultsObserver.token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.intervalProvider() != self.heroInterval, !self.loading { self.restartRefreshTimer() }
                await self.sourceChanged()
            }
        }
        liveWatch = ItemChangeWatch { [weak self] fresh in self?.itemsChanged(fresh) }
        stopWatch = PlaybackStopWatch { [weak self] id, _ in self?.playbackStopped(id) }
    }

    // MARK: Live updates

    private var liveWatch: ItemChangeWatch?
    private var stopWatch: PlaybackStopWatch?
    private let stopReload = TaskHolder()
    /// How many quiet reloads after a stop have landed (tests)
    private(set) var stopReloads = 0

    /// An admin edit: the rows and the banner show the item as read again (new name, pictures).
    func itemsChanged(_ fresh: [String: Item]) {
        if let n = LiveRefresh.replacing(rows: rows, with: fresh) { rows = n }
        if let h = heroFetched, let n = LiveRefresh.replacing(h, with: fresh) { heroFetched = n }
    }

    /// A playback stopped: Continue Watching puts it first at once, then (once the server has saved the
    /// position) the rows are read again in the background, so a new title appears there and Next Up moves on.
    func playbackStopped(_ id: String) {
        guard !loading else { return }
        if let n = LiveRefresh.movingToFront(id, in: rows) { rows = n }
        stopReload.task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LiveRefresh.afterStopDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let new: [Row]
            if let loader = self.loader { new = await loader() } else if let emby = self.emby { new = await emby.loadHome() } else { return }
            guard !Task.isCancelled, !new.isEmpty, !self.loading else { return }
            self.rows = new
            self.stopReloads += 1
        }
    }

    /// (Re)starts the refresh loop with the current setting; the next refresh is a full interval from now.
    /// Called after every Home load (also a server switch) and when the setting changes.
    func restartRefreshTimer() {
        heroInterval = intervalProvider()
        lastHeroRefresh = clock()
        guard heroInterval > 0 else { refreshHolder.task = nil; return }
        refreshHolder.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: BannerRefresh.tick)
                guard !Task.isCancelled, let self else { return }
                await self.refreshBannerIfDue()
            }
        }
    }

    /// One check of the loop: refreshes when the interval has passed, the app is visible and no player is
    /// open. A refresh missed while hidden or playing happens once, on the first check after that.
    @discardableResult
    func refreshBannerIfDue() async -> Bool {
        guard !loading, BannerRefresh.isDue(minutes: heroInterval, last: lastHeroRefresh, now: clock(),
                                            visible: visibleProvider(), playing: playingProvider()) else { return false }
        await refreshBanner()
        return true
    }

    /// A fresh banner set from the banner's source only (the rows stay): the rows' next titles, a new
    /// newest query, or a new random/favorites pick that avoids the set on screen. The new backdrops are
    /// downloaded before the swap, so no slide shows up blank.
    func refreshBanner() async {
        lastHeroRefresh = clock()
        let previous = heroItems
        let s = heroSource
        if s == .rows {
            let round = heroRound + 1
            await prefetchBackdrops(BannerRefresh.rotatedRows(rows.map(\.items), round: round))
            guard !Task.isCancelled, heroSource == s else { return }
            heroRound = round
        } else {
            guard let fetched = await fetchHero(s), !Task.isCancelled, heroSource == s else { return }
            let ordered = s == .newest ? fetched : BannerRefresh.avoidingPrevious(fetched, previous: previous)
            let picked = BannerSource.pick(ordered)
            if picked.isEmpty {
                // Nothing found this time: the rows' next titles, like the banner's fallback
                heroRound += 1
            } else {
                await prefetchBackdrops(picked)
                guard !Task.isCancelled, heroSource == s else { return }
            }
            heroFetched = ordered
        }
        heroGeneration += 1
    }

    private func prefetchBackdrops(_ items: [Item]) async {
        guard let emby else { return }
        let w = Self.bannerImageWidth
        let urls = items.compactMap { emby.image($0.backdropId ?? $0.Id, "Backdrop", width: w) }
        await withTaskGroup(of: Void.self) { g in
            for u in urls { g.addTask { _ = await ImageCache.shared.image(u) } }
        }
    }

    /// Re-reads the setting; a new value fetches that source's titles (the rows stay as they are).
    func sourceChanged() async {
        let s = sourceProvider()
        guard s != heroSource else { return }
        heroSource = s; heroFetched = nil; heroRound = 0
        let fetched = await fetchHero(s)
        if heroSource == s { heroFetched = fetched }
    }

    private func fetchHero(_ s: BannerSource) async -> [Item]? {
        guard s != .rows else { return nil }
        if let heroLoader { return await heroLoader(s) }
        return await emby?.bannerItems(s)
    }

    func bind(_ emby: Emby) { self.emby = emby }

    /// The `.task(id:)` key: a new reload token, a retry or another server/user (`session`) loads again.
    /// A session change from the Home server pill keeps Home on screen, so the key is what reloads it
    /// (SwiftUI cancels the old load when the key changes).
    func taskKey(_ reloadToken: Int, session: String = "") -> String {
        session.isEmpty ? "\(reloadToken)-\(retryCount)" : "\(reloadToken)-\(retryCount)-\(session)"
    }

    /// The server|user the rows on screen belong to.
    private(set) var loadedSession: String?

    /// Identifies a server and user (`emby.server + "|" + emby.userId`).
    nonisolated static func sessionKey(server: String, userId: String) -> String { server + "|" + userId }

    func retry() { loading = true; retryCount += 1 }

    func load(session: String? = nil) async {
        // Another server or user: drop the old server's rows at once (spinner) instead of showing them meanwhile
        if let session, loadedSession != nil, session != loadedSession { rows = []; loading = true }
        if let session, loadedSession != nil, session != loadedSession { heroFetched = nil }
        let src = sourceProvider()
        // The banner's own titles load alongside the rows (a new random pick on every Home load)
        async let hero = fetchHero(src)
        let new: [Row]
        if let loader { new = await loader() } else if let emby { new = await emby.loadHome() } else { new = [] }
        let fetched = await hero
        // A load overtaken by a newer one (key changed: server switch, reload) must not overwrite its rows
        guard !Task.isCancelled else { return }
        rows = new
        heroSource = src; heroFetched = fetched; heroRound = 0
        if let session { loadedSession = session }
        loading = false
        restartRefreshTimer()
        guard prefetchRows, let emby else { return }
        // Look ahead: the first pictures of every row start downloading right away (low priority)
        var urls: [URL?] = []
        for row in rows {
            for it in row.items.prefix(10) {
                if row.feed == .resume || row.feed == .nextUp {
                    urls.append(it.isEpisode ? emby.image(it.Id, width: 520, plain: true)
                                             : emby.image(it.backdropId ?? it.Id, "Backdrop", width: 520))
                } else {
                    urls.append(emby.image(it.posterId, width: 360))
                }
            }
        }
        ImageCache.shared.prefetch(urls)
    }

    /// Same as `BannerSource.resolve`, with the Home rows rotated by the refreshes so far.
    var heroItems: [Item] {
        if heroSource != .rows, let heroFetched {
            let p = BannerSource.pick(heroFetched)
            if !p.isEmpty { return p }
        }
        return BannerRefresh.rotatedRows(rows.map(\.items), round: heroRound)
    }

    /// The banner: up to two items with a backdrop from each row, one per title, eight at most.
    nonisolated static func heroItems(_ rows: [[Item]]) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for items in rows {
            for it in items.filter({ $0.backdropId != nil }).prefix(2) where !seen.contains(it.heroTitle) {
                seen.insert(it.heroTitle); out.append(it)
            }
        }
        return Array(out.prefix(8))
    }
}

/// Removes a NotificationCenter observer when its owner goes away.
final class ObserverToken {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
