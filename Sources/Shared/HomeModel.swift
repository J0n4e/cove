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

    init(prefetchRows: Bool, load: (() async -> [Row])? = nil) {
        self.prefetchRows = prefetchRows
        self.loader = load
    }

    func bind(_ emby: Emby) { self.emby = emby }

    /// The `.task(id:)` key: a new reload token or a retry loads again.
    func taskKey(_ reloadToken: Int) -> String { "\(reloadToken)-\(retryCount)" }

    func retry() { loading = true; retryCount += 1 }

    func load() async {
        if let loader { rows = await loader() } else if let emby { rows = await emby.loadHome() } else { rows = [] }
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

    var heroItems: [Item] { Self.heroItems(rows.map(\.items)) }

    /// The banner: up to two items with a backdrop from each row, one per title, eight at most.
    static func heroItems(_ rows: [[Item]]) -> [Item] {
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
