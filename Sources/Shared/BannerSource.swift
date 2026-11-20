import Foundation

/// Settings → Home → Banner → Banner shows: where the Home banner (both themes) takes its titles from.
enum BannerSource: String, CaseIterable {
    case rows, newest, random, favorites
    static let key = "bannerSource"
    static let defaultValue = BannerSource.rows.rawValue
    static let options: [(String, String)] = [("rows", "From Home rows"), ("newest", "Newest"),
                                              ("random", "Random picks"), ("favorites", "Favorites")]
    static var current: BannerSource {
        BannerSource(rawValue: UserDefaults.standard.string(forKey: key) ?? defaultValue) ?? .rows
    }

    /// Fetched banner titles: films and shows (never episodes) with a backdrop, one per title, eight at most.
    static func pick(_ items: [Item], max: Int = 8) -> [Item] {
        var seen = Set<String>(), out: [Item] = []
        for it in items where (it.`Type` == "Movie" || it.`Type` == "Series") && it.backdropId != nil && !seen.contains(it.heroTitle) {
            seen.insert(it.heroTitle); out.append(it)
            if out.count == max { break }
        }
        return out
    }

    /// Random picks: unwatched titles when they still fill at least four banner slots, otherwise anything.
    static func preferUnwatched(_ items: [Item]) -> [Item] {
        let unwatched = items.filter { $0.UserData?.Played != true }
        return pick(unwatched).count >= 4 ? unwatched : items
    }

    /// Newest: films by date added and shows by their latest new content, merged newest first (ISO dates sort as text).
    static func newestFirst(_ items: [Item]) -> [Item] {
        func date(_ it: Item) -> String { (it.isSeries ? (it.DateLastContentAdded ?? it.DateCreated) : it.DateCreated) ?? "" }
        return items.enumerated().sorted { a, b in
            let da = date(a.element), db = date(b.element)
            return da == db ? a.offset < b.offset : da > db
        }.map(\.element)
    }

    /// What the banner shows: the fetched titles, or the Home rows' (today's banner) for "From Home rows",
    /// a failed fetch or nothing found (e.g. no favorites).
    static func resolve(_ source: BannerSource, rows: [[Item]], fetched: [Item]?) -> [Item] {
        if source != .rows, let fetched {
            let p = pick(fetched)
            if !p.isEmpty { return p }
        }
        return HomeModel.heroItems(rows)
    }
}

extension Emby {
    /// The banner's own titles for `source` (nil for "From Home rows"), from the libraries shown on Home only.
    func bannerItems(_ source: BannerSource) async -> [Item]? {
        guard source != .rows else { return nil }
        await ensureLibs()
        let parents: [String?] = libs.isEmpty ? [nil] : libs.filter { $0.visible && $0.onHome }.map { Optional($0.id) }
        guard !parents.isEmpty else { return [] }
        let u = userId
        func query(_ parent: String?, _ extra: [String: String]) -> [String: String] {
            var q = ["Recursive": "true", "IncludeItemTypes": "Movie,Series", "ImageTypes": "Backdrop",
                     "Fields": "Overview,Genres,EndDate,Status,DateCreated,DateLastContentAdded"]
            if let parent { q["ParentId"] = parent }
            q.merge(extra) { $1 }
            return q
        }
        var queries: [[String: String]] = []
        for p in parents {
            switch source {
            case .newest:
                queries.append(query(p, ["IncludeItemTypes": "Movie", "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": "15"]))
                queries.append(query(p, ["IncludeItemTypes": "Series", "SortBy": "DateLastContentAdded", "SortOrder": "Descending", "Limit": "15"]))
            case .random:
                queries.append(query(p, ["SortBy": "Random", "Limit": "20"]))
            case .favorites:
                queries.append(query(p, ["SortBy": "Random", "Limit": "20", "Filters": "IsFavorite"]))
            case .rows: break
            }
        }
        var all: [Item] = [], ok = false
        for q in queries {
            if let r: ItemList = try? await get("/Users/\(u)/Items", q) { all += r.Items; ok = true }
        }
        guard ok else { return nil }   // every request failed: the banner keeps the Home rows' titles
        switch source {
        case .newest: return BannerSource.newestFirst(all)
        case .random: return BannerSource.preferUnwatched(all.shuffled())
        default: return all.shuffled()
        }
    }
}
