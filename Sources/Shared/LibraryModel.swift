import SwiftUI
import Combine

/// The Library page's state and paging, shared by the Glass and Classic views (they keep only layout and styling).
/// Filters and sort are remembered per library under "lf-<library id>", as before.
@MainActor
final class LibraryModel: ObservableObject {
    /// One page request: start index, page size and sort ("random" for Shuffle). nil means the request failed.
    typealias Fetch = (_ start: Int, _ limit: Int, _ sort: String) async -> ItemList?

    static let pageSize = 100
    /// Libraries up to this size are loaded whole, page after page, with their posters prefetched.
    static let smallLibrary = 300

    let lib: LibPref
    @Published var tab = 0
    @Published var items: [Item] = []
    @Published var total = 0
    @Published var loading = false
    @Published var loadFailed = false
    @Published var sort: String
    @Published var desc: Bool
    @Published var watch: String
    @Published var genre: String
    @Published var genres: [String] = []
    @Published var letter = ""
    @Published var layout: String
    @Published var groupCol: Bool
    /// Bumped by every load; a load whose generation is no longer current drops its result.
    private(set) var gen = 0
    /// The one next-page load in flight (see loadMore).
    private(set) var pageTask: Task<Void, Never>?

    /// Emby's local watched state (`emby.played`), mirrored so a film finished or marked from its page leaves an
    /// Unwatched/Watched library at once, without a server request or a scroll jump.
    @Published var played: [String: Bool] = [:]
    private var playedSub: AnyCancellable?

    private weak var emby: Emby?
    /// Injected in tests; nil uses the server with the current filters.
    private let fetcher: Fetch?

    init(lib: LibPref, defaults: UserDefaults = .standard, fetch: Fetch? = nil) {
        self.lib = lib
        self.fetcher = fetch
        let d = defaults.dictionary(forKey: "lf-" + lib.id) ?? [:]
        sort = d["sort"] as? String ?? "name"
        desc = d["desc"] as? Bool ?? false
        watch = d["watch"] as? String ?? "all"
        genre = d["genre"] as? String ?? ""
        groupCol = d["groupCollections"] as? Bool ?? false
        layout = d["layout"] as? String ?? defaults.string(forKey: "defaultLibraryLayout") ?? "grid"
        // An admin edit (pictures, metadata): swap in the item as read again
        liveWatch = ItemChangeWatch { [weak self] fresh in
            guard let self, let n = LiveRefresh.replacing(self.items, with: fresh) else { return }
            self.items = n
        }
    }
    private var liveWatch: ItemChangeWatch?

    /// The view hands over its Emby (an environment object, so not there at init).
    func bind(_ emby: Emby) {
        self.emby = emby
        if playedSub == nil {
            playedSub = emby.$played.receive(on: DispatchQueue.main).sink { [weak self] in self?.played = $0 }
        }
    }

    // MARK: Local watched filter (pure, so it can be tested)

    /// The loaded items the watch filter still admits, by the local state (the item's own UserData when there's
    /// none, as Emby.isPlayed does). "all" shows everything.
    static func visible(_ items: [Item], watch: String, played: [String: Bool]) -> [Item] {
        guard watch == "unwatched" || watch == "watched" else { return items }
        let want = watch == "watched"
        return items.filter { (played[$0.id] ?? $0.UserData?.Played ?? false) == want }
    }

    /// Where the next page starts in the server's list: the loaded items, less those hidden locally (the server's
    /// filtered list no longer has them).
    static func nextStart(loaded: Int, hidden: Int) -> Int { max(0, loaded - max(0, hidden)) }

    /// A new page added to what's shown, without repeating an item already there.
    static func appendPage(_ shown: [Item], _ page: [Item]) -> [Item] {
        var seen = Set(shown.map(\.id))
        return shown + page.filter { seen.insert($0.id).inserted }
    }

    /// The header's count: the server's total less the loaded items hidden locally.
    static func visibleTotal(total: Int, loaded: Int, visible: Int) -> Int { max(0, total - (loaded - visible)) }

    /// What the views show. Paging still counts every loaded item (`items`) for the server offset.
    var visibleItems: [Item] { Self.visible(items, watch: watch, played: played) }
    var visibleCount: Int { Self.visibleTotal(total: total, loaded: items.count, visible: visibleItems.count) }

    var key: String { "\(tab)|\(sort)|\(desc)|\(watch)|\(genre)|\(letter)|\(grouping)" }
    /// What's saved; a change of it calls save().
    var savedKey: String { "\(sort)|\(desc)|\(watch)|\(genre)|\(layout)|\(groupCol)" }
    /// "Group by Collection" applies to the main tab of movie libraries.
    var canGroup: Bool { lib.kind == "movies" && tab == 0 }
    var grouping: Bool { canGroup && groupCol }
    var filtered: Bool { watch != "all" || !genre.isEmpty }
    var types: String { (tab == 1 || lib.kind == "boxsets") ? "BoxSet" : "Movie,Series,Video,MusicVideo" }
    var sortLabel: String {
        switch sort {
        case "latest": return "Recently Added"
        case "release": return "Release Date"
        case "top": return "Rating"
        default: return "Name"
        }
    }

    func save(_ defaults: UserDefaults = .standard) {
        let d: [String: Any] = ["sort": sort, "desc": desc, "watch": watch, "genre": genre, "layout": layout,
                                "groupCollections": groupCol]
        defaults.set(d, forKey: "lf-" + lib.id)
    }

    /// A new sort starts descending, except Name.
    func sortChanged() { desc = (sort != "name") }

    func loadGenres() async {
        if let emby { genres = await emby.genres(lib) }
    }

    func fetch(start: Int, limit: Int, sort s: String) async -> ItemList? {
        if let fetcher { return await fetcher(start, limit, s) }
        guard let emby else { return nil }
        return await emby.libraryItems(lib, limit: limit, start: start, sort: s, desc: s == sort ? desc : nil,
                                       watch: watch, genre: genre, letter: letter, favorites: tab == 3, types: types,
                                       groupCollections: grouping)
    }

    // MARK: Paging decisions (pure, so they can be tested)

    /// Grid: a cell about to show asks for the next page 30 before the end, and at the very end.
    static func gridTriggers(index i: Int, count: Int) -> Bool { i == count - 30 || i == count - 1 }

    /// List: the row 30 before the end (only once there are more than 30) and the last row ask for the next page.
    static func listTriggers(id: String, ids: [String]) -> Bool {
        let at = ids.count > 30 ? ids[ids.count - 30] : nil
        return id == at || id == ids.last
    }

    /// Whether a load may start: a reset always may; a next page only when none is loading, the last one didn't
    /// fail (that waits for Retry) and there's more to get.
    static func mayLoad(reset: Bool, loading: Bool, failed: Bool, count: Int, total: Int) -> Bool {
        reset || !(loading || failed || count >= total)
    }

    // MARK: Paging

    /// The list view's row `id` appeared.
    func listRowAppeared(_ id: String) {
        if Self.listTriggers(id: id, ids: visibleItems.map(\.id)) { loadMore() }
    }

    /// The grid's cell `i` is about to show.
    func cellWillShow(_ i: Int) {
        if Self.gridTriggers(index: i, count: visibleItems.count) { loadMore() }
    }

    /// Next page from a scroll trigger: one task at a time, cancelled on reset and when the page goes away,
    /// instead of a new Task for every cell that scrolls past the trigger.
    func loadMore() {
        guard pageTask == nil else { return }
        pageTask = Task { await load(reset: false); pageTask = nil }
    }

    /// The page went away: stop the next-page load.
    func cancel() { pageTask?.cancel(); pageTask = nil }

    /// "Load more failed" → Try again.
    func retry() { Task { await load(reset: false) } }

    /// Refresh, or the error state's Try again: from the start.
    func reload() { Task { await load(reset: true) } }

    func load(reset: Bool) async {
        if reset { pageTask?.cancel(); pageTask = nil }
        // Items hidden locally (watched since they loaded, in an Unwatched library) are already gone from the
        // server's filtered list, so the next page starts that many places earlier, or it would skip items
        let kept = visibleItems
        let next = Self.nextStart(loaded: items.count, hidden: items.count - kept.count)
        if !Self.mayLoad(reset: reset, loading: loading, failed: loadFailed, count: next, total: total) { return }
        gen += 1
        let my = gen
        loading = true; loadFailed = false
        let r = await fetch(start: reset ? 0 : next, limit: Self.pageSize, sort: sort)
        guard my == gen else { return }
        loading = false
        // A failed page keeps what's already shown and offers to try again (it used to end paging for good)
        guard let r else { loadFailed = true; return }
        // After a page, the list matches the server again: hidden items are dropped (the new total no longer
        // counts them), and nothing already shown is added twice
        if reset { items = r.Items } else { items = Self.appendPage(Self.visible(items, watch: watch, played: played), r.Items) }
        total = r.TotalRecordCount ?? items.count
        // Posters of the new page start downloading now, before they scroll into view. A small library (Collections,
        // up to 300) is loaded and fetched whole, so no poster has to load while you scroll through it.
        let small = total <= Self.smallLibrary
        if let emby {
            ImageCache.shared.prefetch(r.Items.prefix(small ? 100 : 40).map { emby.image($0.posterId, width: 360) })
        }
        if small && items.count < total { await load(reset: false) }
    }

    func shuffle() async {
        let r = await fetch(start: 0, limit: 1, sort: "random")
        if let f = r?.Items.first { await emby?.play(f) }
    }

    func playFirst() async {
        if let f = items.first { await emby?.play(f) }
    }
}
