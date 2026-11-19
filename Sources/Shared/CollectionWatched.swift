import Foundation

/// A collection (BoxSet) is watched when ALL its films are. The server often doesn't keep a BoxSet's own Played,
/// so Cove derives it: from UserData.UnplayedItemCount + ChildCount when the server sends them, else from the
/// films (fetched once and cached in `Emby.boxFilms`). Marking a collection marks every film.
enum CollectionWatched {
    /// Most requests at once when marking every film of a collection.
    static let concurrency = 4

    /// The films of a collection's children (other titles, e.g. shows, don't count).
    static func films(_ children: [Item]) -> [Item] { children.filter { $0.`Type` == "Movie" } }

    /// Watched iff there is at least one film and every film is watched.
    static func derive(_ films: [Bool]) -> Bool { !films.isEmpty && films.allSatisfy { $0 } }

    /// From the server's own counts, when it sent them: nothing unwatched in a non-empty collection.
    static func fromUserData(_ it: Item) -> Bool? {
        guard let u = it.UserData?.UnplayedItemCount, let c = it.ChildCount, c > 0 else { return nil }
        return u == 0
    }

    /// The collections whose ✓ differs from what their films say now (collection id → new value).
    static func changes(played: [String: Bool], boxFilms: [String: [String]]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (box, films) in boxFilms {
            let v = derive(films.map { played[$0] ?? false })
            if played[box] != v { out[box] = v }
        }
        return out
    }

    /// The collections a film belongs to (among the known ones).
    static func collections(of film: String, boxFilms: [String: [String]]) -> [String] {
        boxFilms.compactMap { $0.value.contains(film) ? $0.key : nil }.sorted()
    }

    /// "Mark all 3 films watched" / "Mark all 3 films unwatched" (generic text when the count isn't known).
    static func tip(played: Bool, count: Int?) -> String {
        guard let n = count, n > 0 else { return PosterBadges.watchedTip(played) }
        return "Mark all \(n) film\(n == 1 ? "" : "s") \(played ? "unwatched" : "watched")"
    }

    /// Runs `send` for every id, at most `limit` at a time; returns each id's answer.
    static func cascade(_ ids: [String], limit: Int = concurrency,
                        send: @escaping @Sendable (String) async -> Bool) async -> [String: Bool] {
        var out: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { g in
            var next = 0
            for _ in 0..<min(max(1, limit), ids.count) {
                let id = ids[next]; next += 1
                g.addTask { (id, await send(id)) }
            }
            while let r = await g.next() {
                out[r.0] = r.1
                if next < ids.count {
                    let n = ids[next]; next += 1
                    g.addTask { (n, await send(n)) }
                }
            }
        }
        return out
    }
}

extension Emby {
    /// Keeps every known collection's ✓ in line with its films (called whenever `played` changes).
    func syncCollections() {
        let c = CollectionWatched.changes(played: played, boxFilms: boxFilms)
        guard !c.isEmpty else { return }
        var p = played
        for (k, v) in c { p[k] = v }
        played = p   // inside didSet: doesn't run it again
    }

    /// Remembers a collection's films (collection page, or the fetch below) and its derived ✓. Films not yet in
    /// the played map take the server's state.
    func noteCollection(_ boxId: String, _ children: [Item]) {
        let films = CollectionWatched.films(children)
        boxFilms[boxId] = films.map(\.id)
        var p = played
        for f in films where p[f.id] == nil { p[f.id] = f.UserData?.Played ?? false }
        p[boxId] = CollectionWatched.derive(films.map { p[$0.id] ?? false })
        played = p
    }

    /// The films of a collection, with their watched state (cached in `boxFilms`).
    @discardableResult
    func loadCollectionFilms(_ boxId: String) async -> [String] {
        boxLoading.insert(boxId)
        defer { boxLoading.remove(boxId) }
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["ParentId": boxId, "Fields": "UserData",
                                                                    "IncludeItemTypes": "Movie"])
        guard let r else { return boxFilms[boxId] ?? [] }
        noteCollection(boxId, r.Items)
        return boxFilms[boxId] ?? []
    }

    /// A collection poster is on screen: when the server didn't send its counts, fetch its films once so its ✓
    /// can be derived (and follow them later).
    func ensureCollectionWatched(_ item: Item) {
        guard item.isBox, boxFilms[item.id] == nil, !boxLoading.contains(item.id),
              CollectionWatched.fromUserData(item) == nil else { return }
        boxLoading.insert(item.id)
        Task { await loadCollectionFilms(item.id) }
    }

    /// The ✓ buttons: a collection marks all its films, anything else as before.
    @discardableResult
    func setItemPlayed(_ item: Item, _ v: Bool, children: [Item] = [], name: String? = nil, rollback: Bool = true) async -> Bool {
        if item.isBox { return await setCollectionPlayed(item.id, v, name: name) }
        return await setPlayedChecked(item.id, v, children: children, name: name, rollback: rollback)
    }

    /// Marks every film of a collection (and the collection itself) watched / unwatched: the server may not do
    /// it for a BoxSet. The ticks change at once; films the server refused go back, with a message.
    @discardableResult
    func setCollectionPlayed(_ boxId: String, _ v: Bool, name: String? = nil) async -> Bool {
        var films = boxFilms[boxId] ?? []
        if boxFilms[boxId] == nil { films = await loadCollectionFilms(boxId) }
        if let name { toast = Toast(text: "Marked \u{201C}\(name)\u{201D} as \(v ? "watched" : "unwatched")", icon: v ? "checkmark.circle.fill" : "circle") }
        let ids = films + [boxId]
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, (played[$0], positions[$0])) })
        var p = played
        for id in ids { p[id] = v; positions[id] = 0 }
        played = p
        let user = userId, method = v ? "POST" : "DELETE"
        let res = await CollectionWatched.cascade(ids) { [weak self] id in
            await self?.sendChecked(method, "/Users/\(user)/PlayedItems/\(id)") ?? false
        }
        // The collection's own answer doesn't matter when it has films (its ✓ follows them)
        let failed = (films.isEmpty ? [boxId] : films).filter { res[$0] != true }
        if !failed.isEmpty {
            var q = played
            for id in failed { q[id] = before[id]?.0; positions[id] = before[id]?.1 }
            if films.isEmpty || failed.count == films.count { q[boxId] = before[boxId]?.0 }
            played = q
            toast = BadgeRollback.failureToast
        }
        if name != nil {
            for f in films where res[f] == true { await Trakt.shared.setWatched(itemId: f, v, emby: self) }
        }
        return failed.isEmpty
    }
}
