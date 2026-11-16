import XCTest
@testable import Cove

/// The shared screen models (Favorites, Search, Person) against a small fake server.
@MainActor
final class SharedFavoritesSearchTests: XCTestCase {
    final class Fake: ScreenSource {
        var favs: [Item] = [], favPeople: [Item] = [], titles: [Item] = [], persons: [Item] = []
        var withPerson: [Item] = [], record: Item?
        var calls: [String] = []
        func favorites() async -> [Item] { calls.append("favorites"); return favs }
        func favoritePeople() async -> [Item] { calls.append("favoritePeople"); return favPeople }
        func search(_ term: String) async -> [Item] { calls.append("search:" + term); return titles }
        func searchPeople(_ term: String) async -> [Item] { calls.append("searchPeople:" + term); return persons }
        func itemsWithPerson(_ personId: String) async -> [Item] { calls.append("itemsWithPerson:" + personId); return withPerson }
        func person(_ id: String) async -> Item? { calls.append("person:" + id); return record }
    }

    func item(_ id: String, _ type: String?) -> Item {
        var json = "{\"Id\":\"\(id)\",\"Name\":\"n\(id)\""
        if let type { json += ",\"Type\":\"\(type)\"" }
        return try! JSONDecoder().decode(Item.self, from: Data((json + "}").utf8))
    }

    func testFavoritesSections() {
        let all = [item("m", "Movie"), item("s", "Series"), item("e", "Episode"), item("b", "BoxSet"), item("x", nil)]
        let s = FavoritesModel.sections(all)
        XCTAssertEqual(s.movies.map(\.Id), ["m", "x"])
        XCTAssertEqual(s.shows.map(\.Id), ["s"])
        XCTAssertEqual(s.episodes.map(\.Id), ["e"])
        XCTAssertEqual(s.collections.map(\.Id), ["b"])
    }

    func testFavoritesLoad() async {
        let f = Fake(); f.favs = [item("1", "Movie")]; f.favPeople = [item("p", "Person")]
        let m = FavoritesModel()
        XCTAssertTrue(m.loading)
        await m.load(f)
        XCTAssertEqual(m.items.map(\.Id), ["1"]); XCTAssertEqual(m.people.map(\.Id), ["p"]); XCTAssertFalse(m.loading)
    }

    func testFavoritesCancelledLoadKeepsOldData() async {
        let f = Fake(); f.favs = [item("1", "Movie")]
        let m = FavoritesModel()
        let t = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await m.load(f)
        }
        await t.value
        XCTAssertTrue(m.items.isEmpty); XCTAssertTrue(m.loading)
    }

    func testFavoriteGridPickKeepsServerOrder() {
        let all = [item("a", "Movie"), item("b", "Movie"), item("c", "Movie")]
        XCTAssertEqual(FavoriteGridModel.pick(all, ids: ["c", "a"]).map(\.Id), ["a", "c"])
    }

    func testSearchRunsBothQueries() async {
        let f = Fake(); f.titles = [item("t", "Movie")]; f.persons = [item("p", "Person")]
        let m = SearchModel()
        await m.run("abc", source: f, debounce: 0)
        XCTAssertEqual(Set(f.calls), ["search:abc", "searchPeople:abc"])
        XCTAssertEqual(m.results.map(\.Id), ["t"]); XCTAssertEqual(m.people.map(\.Id), ["p"]); XCTAssertFalse(m.busy)
    }

    func testSearchCancelledDuringDebounceAsksNothing() async {
        XCTAssertEqual(SearchModel.debounce, 350_000_000)
        let f = Fake()
        let m = SearchModel()
        let t = Task { @MainActor in await m.run("abc", source: f) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        await t.value
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertTrue(m.busy)   // as before: the next run (the new query) clears it
    }

    func testPersonLoad() async {
        let f = Fake(); f.withPerson = [item("m", "Movie"), item("s", "Series")]; f.record = item("p", "Person")
        let m = PersonModel()
        await m.load("p", source: f)
        XCTAssertEqual(Set(f.calls), ["itemsWithPerson:p", "person:p"])
        XCTAssertEqual(m.movies.map(\.Id), ["m"]); XCTAssertEqual(m.shows.map(\.Id), ["s"])
        XCTAssertEqual(m.record?.Id, "p"); XCTAssertFalse(m.loading)
    }
}
