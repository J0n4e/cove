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

    init(prefetchRows: Bool, load: (() async -> [Row])? = nil,
         heroLoad: ((BannerSource) async -> [Item]?)? = nil, source: (() -> BannerSource)? = nil) {
        self.prefetchRows = prefetchRows
        self.loader = load
        self.heroLoader = heroLoad
        let provider = source ?? { BannerSource.current }
        self.sourceProvider = provider
        self.heroSource = provider()
        // Changing the setting reloads the banner at once (Settings is another window)
        defaultsObserver.token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sourceChanged() }
        }
    }

    /// Re-reads the setting; a new value fetches that source's titles (the rows stay as they are).
    func sourceChanged() async {
        let s = sourceProvider()
        guard s != heroSource else { return }
        heroSource = s; heroFetched = nil
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
        heroSource = src; heroFetched = fetched
        if let session { loadedSession = session }
        loading = false
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

    var heroItems: [Item] { BannerSource.resolve(heroSource, rows: rows.map(\.items), fetched: heroFetched) }

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
