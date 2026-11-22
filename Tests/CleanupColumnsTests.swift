import XCTest
@testable import Cove

final class CleanupColumnsTests: XCTestCase {
    let ann = WatchActivityUser(id: "a", name: "Ann", imageTag: nil, disabled: false)
    let bob = WatchActivityUser(id: "b", name: "Bob", imageTag: nil, disabled: false)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    func make(_ id: String, name: String? = nil, rating: Double? = nil, mine: Int? = nil, added: Date? = nil,
              size: Int64? = nil, last: Date? = nil, watchedBy: [WatchActivityUser] = []) -> CleanupItem {
        var o: [String: Any] = ["Id": id, "Name": name ?? id, "Type": "Movie"]
        if let rating { o["CommunityRating"] = rating }
        if let added { o["DateCreated"] = iso(added) }
        if let size { o["MediaSources"] = [["Size": size]] }
        var map = [id: Cleanup.item(o, libraryId: "L")!]
        for u in [ann, bob] {
            var ud: [String: Any] = ["Played": watchedBy.contains(u), "PlayCount": watchedBy.contains(u) ? 1 : 0, "PlaybackPositionTicks": 0]
            if let last, u.id == "a" { ud["LastPlayedDate"] = iso(last) }
            Cleanup.merge([["Id": id, "UserData": ud]], user: u, into: &map)
        }
        var i = map[id]!
        i.myRating = mine
        return i
    }

    func ids(_ items: [CleanupItem], _ s: CleanupSort) -> [String] { Cleanup.sorted(items, by: s).map(\.id) }

    func testTitleSortIsNaturalAndReverses() {
        let items = [make("b", name: "Movie 10"), make("a", name: "movie 2"), make("c", name: "Alien")]
        XCTAssertEqual(ids(items, .titleAZ), ["c", "a", "b"])   // 2 before 10, case-insensitive
        XCTAssertEqual(ids(items, .titleZA), ["b", "a", "c"])
    }

    func testWatchedSort() {
        let items = [make("all", watchedBy: [ann, bob]), make("none"), make("half", watchedBy: [ann])]
        XCTAssertEqual(ids(items, .leastWatched), ["none", "half", "all"])
        XCTAssertEqual(ids(items, .mostWatched), ["all", "half", "none"])
    }

    func testCombinedRatingUsesYoursThenServerUnknownLast() {
        let items = [make("srv8", rating: 8), make("mine3", rating: 9, mine: 3), make("none"), make("mine10", mine: 10)]
        XCTAssertEqual(ids(items, .ratingHighest), ["mine10", "srv8", "mine3", "none"])
        XCTAssertEqual(ids(items, .ratingLowest), ["mine3", "srv8", "mine10", "none"])
        // the presets stay: own rating only / server rating only, unknown last
        XCTAssertEqual(ids(items, .myHighest), ["mine10", "mine3", "none", "srv8"])
        XCTAssertEqual(ids(items, .highestRating), ["mine3", "srv8", "mine10", "none"])
        XCTAssertEqual(ids(items, .lowestRating), ["srv8", "mine3", "mine10", "none"])
    }

    func testAddedLastPlayedSizeUnknownLastBothWays() {
        let old = t0.addingTimeInterval(-1000)
        let items = [make("new", added: t0, size: 5, last: t0), make("unknown"), make("old", added: old, size: 50, last: old)]
        XCTAssertEqual(ids(items, .newestAdded), ["new", "old", "unknown"])
        XCTAssertEqual(ids(items, .oldestAdded), ["old", "new", "unknown"])
        XCTAssertEqual(ids(items, .lastPlayedLongAgo), ["old", "new", "unknown"])
        XCTAssertEqual(ids(items, .lastPlayedRecent), ["new", "old", "unknown"])
        XCTAssertEqual(ids(items, .largest), ["old", "new", "unknown"])
        XCTAssertEqual(ids(items, .smallest), ["new", "old", "unknown"])
    }

    func testRequestedSortUnknownLast() throws {
        let json = #"""
        [{"id":1,"media_type":"movie","tmdb_id":11,"title":"A","status":"downloaded","requested_at":"2026-11-10T10:00:00","user_id":1,"username":"ann"},
         {"id":2,"media_type":"movie","tmdb_id":22,"title":"B","status":"approved","requested_at":"2026-11-12T10:00:00","user_id":2,"username":"bob"}]
        """#
        let reqs = try XCTUnwrap(Nexview.decodeRequests(Data(json.utf8)))
        var a = make("a"), b = make("b"), c = make("c")
        a.tmdbId = 11; b.tmdbId = 22
        let items = NexviewMatch.attach(reqs, to: [c, a, b])
        XCTAssertEqual(ids(items, .requestedNewest), ["b", "a", "c"])
        XCTAssertEqual(ids(items, .requestedOldest), ["a", "b", "c"])
    }

    func testHeaderClicks() {
        XCTAssertEqual(CleanupSort.leastWatched.clicked(.watched), .mostWatched)
        XCTAssertEqual(CleanupSort.mostWatched.clicked(.watched), .leastWatched)
        XCTAssertEqual(CleanupSort.leastWatched.clicked(.title), .titleAZ)
        XCTAssertEqual(CleanupSort.titleAZ.clicked(.title), .titleZA)
        XCTAssertEqual(CleanupSort.myLowest.clicked(.rating), .myHighest)   // a preset keeps its kind when reversed
        XCTAssertEqual(CleanupSort.myLowest.column, .rating)
        for s in CleanupSort.allCases {
            XCTAssertEqual(s.reversed.reversed, s)
            XCTAssertNotEqual(s.reversed.ascending, s.ascending)
            XCTAssertEqual(s.reversed.column, s.column)
        }
        for c in CleanupColumn.allCases { XCTAssertEqual(c.defaultSort.column, c) }
    }

    func testDropdownOptions() {
        XCTAssertFalse(Cleanup.sorts(hasSize: false).contains(.smallest))
        XCTAssertFalse(Cleanup.sorts(hasSize: true).contains(.requestedNewest))
        XCTAssertTrue(Cleanup.sorts(hasSize: true, hasRequests: true).contains(.requestedOldest))
        XCTAssertEqual(CleanupColumns(selecting: false, requests: true).trailing.last, .requested)
        XCTAssertFalse(CleanupColumns(selecting: false, requests: false).trailing.contains(.requested))
    }
}
