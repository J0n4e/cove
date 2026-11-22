import XCTest
@testable import Cove

final class CleanupTests: XCTestCase {
    let ann = WatchActivityUser(id: "a", name: "Ann", imageTag: nil, disabled: false)
    let bob = WatchActivityUser(id: "b", name: "Bob", imageTag: nil, disabled: false)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    func meta(_ id: String, _ type: String = "Movie", rating: Double? = nil, added: Date? = nil, size: Int64? = nil) -> [String: Any] {
        var o: [String: Any] = ["Id": id, "Name": id, "Type": type]
        if let rating { o["CommunityRating"] = rating }
        if let added { o["DateCreated"] = iso(added) }
        if let size { o["MediaSources"] = [["Size": size]] }
        return o
    }

    func ud(_ id: String, played: Bool = false, count: Int = 0, pos: Int64 = 0, unplayed: Int? = nil, total: Int? = nil,
            last: Date? = nil) -> [String: Any] {
        var u: [String: Any] = ["Played": played, "PlayCount": count, "PlaybackPositionTicks": pos]
        if let unplayed { u["UnplayedItemCount"] = unplayed }
        if let last { u["LastPlayedDate"] = iso(last) }
        var o: [String: Any] = ["Id": id, "UserData": u]
        if let total { o["RecursiveItemCount"] = total }
        return o
    }

    func build(_ metas: [[String: Any]], _ users: [(WatchActivityUser, [[String: Any]])]) -> [CleanupItem] {
        var map: [String: CleanupItem] = [:]
        for m in metas { let i = Cleanup.item(m, libraryId: "L")!; map[i.id] = i }
        for (u, rows) in users { Cleanup.merge(rows, user: u, into: &map) }
        return Array(map.values)
    }

    func testAggregationMoviesAndPartialSeries() {
        let items = build([meta("m", size: 100), meta("s", "Series")],
                          [(ann, [ud("m", played: true, count: 2, last: now), ud("s", unplayed: 4, total: 10)]),
                           (bob, [ud("m", pos: 5_000), ud("s", unplayed: 0, total: 10, last: now.addingTimeInterval(-10)), ud("x", played: true)])])
        let m = items.first { $0.id == "m" }!, s = items.first { $0.id == "s" }!
        XCTAssertEqual(items.count, 2)   // x unknown to the admin: skipped
        XCTAssertEqual(m.watchedBy, ["Ann"]); XCTAssertEqual(m.inProgressBy, ["Bob"]); XCTAssertEqual(m.playCount, 2)
        XCTAssertEqual(m.watchedText, "1/2"); XCTAssertEqual(m.sizeBytes, 100); XCTAssertEqual(m.lastPlayed, now)
        XCTAssertEqual(s.watchedBy, ["Bob"]); XCTAssertEqual(s.inProgressBy, ["Ann"]); XCTAssertNil(s.sizeBytes)
        XCTAssertFalse(s.neverWatched)
    }

    func testSorts() {
        let old = now.addingTimeInterval(-1000), new = now
        let items = build([meta("never", rating: 5, added: new, size: 10), meta("half", rating: 8, added: old, size: 30),
                           meta("all", added: old, size: 20), meta("neverOld", rating: 7, added: old)],
                          [(ann, [ud("never"), ud("half", played: true, last: old), ud("all", played: true, last: new), ud("neverOld")]),
                           (bob, [ud("never"), ud("half"), ud("all", played: true), ud("neverOld")])])
        func ids(_ s: CleanupSort) -> [String] { Cleanup.sorted(items, by: s).map(\.id) }
        XCTAssertEqual(ids(.leastWatched), ["neverOld", "never", "half", "all"])
        XCTAssertEqual(ids(.mostWatched), ["all", "half", "never", "neverOld"])
        XCTAssertEqual(ids(.lowestRating), ["never", "neverOld", "half", "all"])
        XCTAssertEqual(ids(.highestRating), ["half", "neverOld", "never", "all"])
        XCTAssertEqual(ids(.oldestAdded).last, "never")
        XCTAssertEqual(ids(.newestAdded).first, "never")
        // never played (no date) goes last in both directions
        XCTAssertEqual(Array(ids(.lastPlayedLongAgo).prefix(2)), ["half", "all"])
        XCTAssertEqual(ids(.largest), ["half", "all", "never", "neverOld"])
        XCTAssertFalse(Cleanup.sorts(hasSize: false).contains(.largest))
    }

    func testFilters() {
        let longAgo = now.addingTimeInterval(-400 * 86_400)
        let items = build([meta("fresh", rating: 9, added: now), meta("stale", rating: 4, added: longAgo),
                           meta("old", rating: 7, added: longAgo), meta("s", "Series", added: now)],
                          [(ann, [ud("fresh"), ud("stale"), ud("old", played: true, last: longAgo), ud("s", unplayed: 2, total: 4, last: now)])])
        func ids(_ f: CleanupFilter) -> Set<String> { Set(Cleanup.filtered(items, library: nil, kind: .both, filter: f, now: now).map(\.id)) }
        XCTAssertEqual(ids(.all).count, 4)
        XCTAssertEqual(ids(.neverWatched), ["fresh", "stale"])
        XCTAssertEqual(ids(.notInAYear), ["fresh", "stale", "old"])
        XCTAssertEqual(ids(.lowRated), ["stale"])
        XCTAssertEqual(ids(.oldUnwatched), ["stale"])
        XCTAssertEqual(Cleanup.filtered(items, library: nil, kind: .series, filter: .all, now: now).map(\.id), ["s"])
        XCTAssertEqual(Cleanup.filtered(items, library: nil, kind: .movies, filter: .all, now: now).count, 3)
        XCTAssertTrue(Cleanup.filtered(items, library: "other", kind: .both, filter: .all, now: now).isEmpty)
    }

    func testSummaryAndProgress() {
        let items = build([meta("a", size: 1_000_000_000), meta("b", size: 500_000_000), meta("c", "Series")],
                          [(ann, [ud("a", played: true), ud("b"), ud("c")])])
        let s = Cleanup.summary(items)
        XCTAssertEqual(s.titles, 3); XCTAssertEqual(s.neverWatched, 2); XCTAssertEqual(s.sizeBytes, 1_500_000_000)
        XCTAssertTrue(s.text.hasPrefix("3 titles · 2 never watched · "))
        XCTAssertEqual(Cleanup.Summary(titles: 1, neverWatched: 0, sizeBytes: nil).text, "1 title · 0 never watched")
        XCTAssertEqual(Cleanup.progressText(done: 2, total: 5), "Reading 3 of 5 users\u{2026}")
        XCTAssertTrue(Cleanup.needsMore(fetched: 500, lastCount: 500, total: 700))
        XCTAssertFalse(Cleanup.needsMore(fetched: 700, lastCount: 200, total: 700))
        XCTAssertFalse(Cleanup.needsMore(fetched: 500, lastCount: 0, total: nil))
    }

    @MainActor func testDeleteQueueOrderAndAbort() async {
        var calls: [String] = []
        let ok = await CleanupDeleteQueue.run(["1", "2", "3"]) { calls.append($0); return nil }
        XCTAssertEqual(calls, ["1", "2", "3"]); XCTAssertEqual(ok.done, ["1", "2", "3"]); XCTAssertNil(ok.failed)
        calls = []
        let bad = await CleanupDeleteQueue.run(["1", "2", "3"]) { calls.append($0); return $0 == "2" ? "boom" : nil }
        XCTAssertEqual(calls, ["1", "2"]); XCTAssertEqual(bad.done, ["1"])
        XCTAssertEqual(bad.failed?.id, "2"); XCTAssertEqual(bad.failed?.message, "boom"); XCTAssertEqual(bad.skipped, ["3"])
    }

    func testCleanupTab() {
        XCTAssertEqual(ActivityPage.segments(admin: true).last, .cleanup)
        XCTAssertFalse(ActivityPage.segments(admin: false).contains(.cleanup))
        XCTAssertFalse(ActivityPage.statsPages(stats: true).contains(.cleanup))
        XCTAssertEqual(ActivityPage.cleanup.title, "Cleanup")
    }
}
