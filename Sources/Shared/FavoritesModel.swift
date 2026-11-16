import Foundation
import Combine

/// Data for the Favorites page, shared by the Glass and Classic themes (the views only lay it out).
/// The view calls `load` from `.task(id: emby.favRevision)`, so SwiftUI still cancels an older fetch
/// when something is added or removed elsewhere, or when the page goes away.
@MainActor
final class FavoritesModel: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var people: [Item] = []
    @Published private(set) var loading = true

    /// Titles and people together; a cancelled fetch changes nothing, so an older response can't land last.
    func load(_ source: ScreenSource) async {
        async let f = source.favorites()
        async let p = source.favoritePeople()
        let (newItems, newPeople) = await (f, p)
        guard !Task.isCancelled else { return }
        items = newItems; people = newPeople; loading = false
    }

    /// The page's sections, in page order. `favs` is already filtered to what is still a favorite.
    struct Sections: Equatable {
        var movies: [Item] = [], shows: [Item] = [], episodes: [Item] = [], collections: [Item] = []
    }

    static func sections(_ favs: [Item]) -> Sections {
        Sections(movies: favs.filter { !$0.isSeries && !$0.isBox && !$0.isEpisode },
                 shows: favs.filter { $0.isSeries },
                 episodes: favs.filter { $0.isEpisode },
                 collections: favs.filter { $0.isBox })
    }
}

/// One Favorites section opened as a page ("Favorite Movies ›"): the favorites with the given ids.
@MainActor
final class FavoriteGridModel: ObservableObject {
    @Published private(set) var items: [Item] = []

    func load(_ source: ScreenSource, ids: [String]) async {
        let all = await source.favorites()
        items = Self.pick(all, ids: ids)
    }

    static func pick(_ all: [Item], ids: [String]) -> [Item] {
        let set = Set(ids)
        return all.filter { set.contains($0.Id) }
    }
}

/// "Favorite People ›" opened as a page.
@MainActor
final class FavoritePeopleModel: ObservableObject {
    @Published private(set) var people: [Item] = []

    func load(_ source: ScreenSource) async {
        let p = await source.favoritePeople()
        guard !Task.isCancelled else { return }
        people = p
    }
}
