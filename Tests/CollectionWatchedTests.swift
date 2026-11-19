import XCTest
@testable import Cove

/// A collection's ✓ follows its films (CollectionWatched.swift): derived state, marking every film, rollback,
/// and recompute when a film changes. Server calls go to *.test hosts through ServerStub.
@MainActor
final class CollectionWatchedTests: XCTestCase {
    static let host = "https://box.test:8920"

    override class func setUp() {
        super.setUp()
        ServerStub.install()
    }
    override func setUp() async throws { ServerStub.reset() }
    override func tearDown() async throws { ServerStub.reset() }

    private func emby() -> Emby {
        let e = Emby()
        e.server = Self.host; e.token = "tok"; e.userId = "u1"; e.isJellyfin = true
        return e
    }

    private func item(_ json: String) -> Item { try! JSONDecoder().decode(Item.self, from: Data(json.utf8)) }
    private func film(_ id: String, played: Bool) -> Item {
        item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","UserData":{"Played":\#(played)}}"#)
    }
    private func filmsJSON(_ f: [(String, Bool)]) -> String {
        let items = f.map { #"{"Id":"\#($0.0)","Name":"\#($0.0)","Type":"Movie","UserData":{"Played":\#($0.1)}}"# }
        return #"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(f.count)}"#
    }
    private func calls(_ method: String) -> [String] {
        ServerStub.requests.filter { $0.method == method }.map { $0.url.lastPathComponent }.sorted()
    }

    // MARK: Derive

    func testDeriveAllSomeNoneEmpty() {
        XCTAssertTrue(CollectionWatched.derive([true, true, true]))
        XCTAssertFalse(CollectionWatched.derive([true, false, true]))
        XCTAssertFalse(CollectionWatched.derive([false, false]))
        XCTAssertFalse(CollectionWatched.derive([]), "an empty collection is not watched")
    }

    func testFromUserData() {
        let done = item(#"{"Id":"b","Name":"B","Type":"BoxSet","ChildCount":3,"UserData":{"Played":false,"UnplayedItemCount":0}}"#)
        let some = item(#"{"Id":"b","Name":"B","Type":"BoxSet","ChildCount":3,"UserData":{"UnplayedItemCount":1}}"#)
        let empty = item(#"{"Id":"b","Name":"B","Type":"BoxSet","ChildCount":0,"UserData":{"UnplayedItemCount":0}}"#)
        let noCount = item(#"{"Id":"b","Name":"B","Type":"BoxSet","UserData":{"Played":true}}"#)
        XCTAssertEqual(CollectionWatched.fromUserData(done), true)
        XCTAssertEqual(CollectionWatched.fromUserData(some), false)
        XCTAssertNil(CollectionWatched.fromUserData(empty))
        XCTAssertNil(CollectionWatched.fromUserData(noCount))
        let e = emby()
        XCTAssertTrue(e.isPlayed(done), "derived although the BoxSet's own Played is false")
        XCTAssertFalse(e.isPlayed(some))
    }

    func testOnlyFilmsCount() {
        let kids = [film("m1", played: true),
                    item(#"{"Id":"s1","Name":"S","Type":"Series","UserData":{"Played":false}}"#)]
        XCTAssertEqual(CollectionWatched.films(kids).map(\.id), ["m1"])
        let e = emby()
        e.noteCollection("b", kids)
        XCTAssertEqual(e.played["b"], true, "the show doesn't count")
    }

    func testNoteCollectionDerives() {
        let e = emby()
        e.noteCollection("b", [film("m1", played: true), film("m2", played: false)])
        XCTAssertEqual(e.played["b"], false)
        XCTAssertEqual(e.boxFilms["b"], ["m1", "m2"])
        XCTAssertEqual(CollectionWatched.collections(of: "m2", boxFilms: e.boxFilms), ["b"])
    }

    func testTip() {
        XCTAssertEqual(CollectionWatched.tip(played: false, count: 3), "Mark all 3 films watched")
        XCTAssertEqual(CollectionWatched.tip(played: true, count: 3), "Mark all 3 films unwatched")
        XCTAssertEqual(CollectionWatched.tip(played: false, count: 1), "Mark all 1 film watched")
        XCTAssertEqual(CollectionWatched.tip(played: false, count: nil), "Mark as watched")
    }

    // MARK: Recompute on a film change

    func testRecomputeOnChildChange() {
        let e = emby()
        e.noteCollection("b", [film("m1", played: true), film("m2", played: false)])
        XCTAssertEqual(e.played["b"], false)
        e.played["m2"] = true          // e.g. playback finished, a SyncPlay / Trakt mark
        XCTAssertEqual(e.played["b"], true)
        e.played["m1"] = false
        XCTAssertEqual(e.played["b"], false)
    }

    func testFilmMarkedThroughBadgeUpdatesCollection() async {
        ServerStub.on("/Users/u1/PlayedItems/m2", .status(204))
        let e = emby()
        e.noteCollection("b", [film("m1", played: true), film("m2", played: false)])
        let ok = await e.setPlayedChecked("m2", true)
        XCTAssertTrue(ok)
        XCTAssertEqual(e.played["b"], true)
    }

    func testFetchesFilmsWhenNoCounts() async {
        ServerStub.on("/Users/u1/Items", .json(200, filmsJSON([("m1", true), ("m2", true)])))
        let e = emby()
        let films = await e.loadCollectionFilms("b")
        XCTAssertEqual(films, ["m1", "m2"])
        XCTAssertEqual(e.played["b"], true)
        let q = ServerStub.requests.last?.url.query ?? ""
        XCTAssertTrue(q.contains("ParentId=b") && q.contains("IncludeItemTypes=Movie"), q)
    }

    // MARK: Cascade

    func testCascadeLimitsConcurrency() async {
        actor Counter { var now = 0, peak = 0
            func enter() { now += 1; peak = max(peak, now) }
            func leave() { now -= 1 } }
        let c = Counter()
        let ids = (1...10).map { "f\($0)" }
        let r = await CollectionWatched.cascade(ids, limit: 4) { _ in
            await c.enter(); try? await Task.sleep(nanoseconds: 5_000_000); await c.leave(); return true
        }
        XCTAssertEqual(Set(r.keys), Set(ids))
        let peak = await c.peak
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testMarkWatchedPostsEveryFilm() async {
        let e = emby()
        e.noteCollection("b", [film("m1", played: false), film("m2", played: true), film("m3", played: false)])
        for id in ["m1", "m2", "m3", "b"] { ServerStub.on("/Users/u1/PlayedItems/\(id)", .status(204)) }
        let ok = await e.setCollectionPlayed("b", true, name: "Trilogy")
        XCTAssertTrue(ok)
        XCTAssertEqual(calls("POST"), ["b", "m1", "m2", "m3"])
        XCTAssertEqual(e.played["b"], true)
        XCTAssertEqual(["m1", "m2", "m3"].map { e.played[$0] }, [true, true, true])
    }

    func testMarkUnwatchedDeletesEveryFilm() async {
        let e = emby()
        e.noteCollection("b", [film("m1", played: true), film("m2", played: true)])
        for id in ["m1", "m2", "b"] { ServerStub.on("/Users/u1/PlayedItems/\(id)", .status(200)) }
        let ok = await e.setCollectionPlayed("b", false)
        XCTAssertTrue(ok)
        XCTAssertEqual(calls("DELETE"), ["b", "m1", "m2"])
        XCTAssertEqual(e.played["b"], false)
        XCTAssertEqual(e.played["m1"], false)
    }

    func testFailureRollsBackRefusedFilms() async {
        let e = emby()
        e.noteCollection("b", [film("m1", played: false), film("m2", played: false)])
        ServerStub.on("/Users/u1/PlayedItems/m1", .status(204))
        ServerStub.on("/Users/u1/PlayedItems/m2", .status(500))
        ServerStub.on("/Users/u1/PlayedItems/b", .status(204))
        let ok = await e.setCollectionPlayed("b", true, name: "Duo")
        XCTAssertFalse(ok)
        XCTAssertEqual(e.played["m1"], true, "the server took it")
        XCTAssertEqual(e.played["m2"], false, "back as it was")
        XCTAssertEqual(e.played["b"], false, "not every film is watched")
        XCTAssertEqual(e.toast?.text, BadgeRollback.failureText)
    }

    func testAllFailRollsEverythingBack() async {
        let e = emby()
        e.noteCollection("b", [film("m1", played: true), film("m2", played: true)])
        let ok = await e.setCollectionPlayed("b", false)   // no routes: 404
        XCTAssertFalse(ok)
        XCTAssertEqual(e.played["m1"], true)
        XCTAssertEqual(e.played["m2"], true)
        XCTAssertEqual(e.played["b"], true)
    }

    func testCollectionBadgeLoadsFilmsFirst() async {
        ServerStub.on("/Users/u1/Items", .json(200, filmsJSON([("m1", false), ("m2", false)])))
        for id in ["m1", "m2", "b"] { ServerStub.on("/Users/u1/PlayedItems/\(id)", .status(204)) }
        let e = emby()
        let box = item(#"{"Id":"b","Name":"B","Type":"BoxSet"}"#)
        let ok = await e.setItemPlayed(box, true)
        XCTAssertTrue(ok)
        XCTAssertEqual(calls("POST"), ["b", "m1", "m2"])
        XCTAssertTrue(e.isPlayed(box))
    }
}
