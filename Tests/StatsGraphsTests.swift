import XCTest
@testable import Cove

/// Activity → Graphs / Libraries: bucketing per day / week / month, the weekday × hour heatmap, play types over
/// time, the device list, Movies vs Episodes and mapping plays to libraries.
final class StatsGraphsTests: XCTestCase {
    private let cal = Calendar.current
    private var now: Date { StatsDecode.dayFormat.date(from: "2026-11-15")!.addingTimeInterval(12 * 3600) }

    private func play(_ id: String, day: String = "2026-11-10", time: String = "20:00", type: String = "Movie",
                      name: String = "Film", item: String? = nil, method: String = "DirectPlay", client: String = "Cove",
                      device: String = "Mac", seconds: Int = 3600) -> StatsPlay {
        StatsPlay(id: id, start: StatsDecode.time(time, day: day)!, day: day, itemId: item ?? "i" + id, name: name,
                  type: type, client: client, device: device, method: method, seconds: seconds)
    }
    private func date(_ d: String) -> Date { StatsDecode.dayFormat.date(from: d)! }

    // MARK: Bucketing

    func testDailyBucketsCoverTheRange() {
        let b = StatsGraphsAggregate.playsPerBucket([play("1"), play("2", seconds: 1800), play("3", day: "2026-11-01")],
                                                    .week, now: now, calendar: cal)
        XCTAssertEqual(b.count, 7)
        XCTAssertEqual(b.first?.start, date("2026-11-09"))
        XCTAssertEqual(b.last?.start, date("2026-11-15"))
        let d10 = b.first { $0.start == date("2026-11-10") }
        XCTAssertEqual(d10?.plays, 2); XCTAssertEqual(d10?.seconds, 5400)
        XCTAssertEqual(b.reduce(0) { $0 + $1.plays }, 2)   // Nov 1 is outside 7 days
    }

    func testWeeklyBucketsStartOnMonday() {
        XCTAssertEqual(StatsRange.year.playsUnit, .week)
        let b = StatsGraphsAggregate.playsPerBucket([play("1", day: "2026-11-10"), play("2", day: "2026-11-15"),
                                                     play("3", day: "2026-11-08")], .year, now: now, calendar: cal)
        let wk = b.first { $0.start == date("2026-11-09") }   // Mon Nov 9 … Sun Nov 15
        XCTAssertEqual(wk?.plays, 2)
        XCTAssertEqual(b.first { $0.start == date("2026-11-02") }?.plays, 1)
        XCTAssertTrue(b.allSatisfy { StatsGraphsAggregate.slot($0.start, calendar: cal).weekday == 0 })
        XCTAssertGreaterThanOrEqual(b.count, 52)
    }

    func testMonthlyBucketsForAllStartAtFirstPlay() {
        let b = StatsGraphsAggregate.playsPerBucket([play("1", day: "2026-09-03"), play("2", day: "2026-11-10")],
                                                    .all, now: now, calendar: cal)
        XCTAssertEqual(b.map(\.start), [date("2026-09-01"), date("2026-10-01"), date("2026-11-01")])
        XCTAssertEqual(b.map(\.plays), [1, 0, 1])
        XCTAssertTrue(StatsGraphsAggregate.playsPerBucket([], .all, now: now, calendar: cal).isEmpty)
    }

    func testHoverPicksTheBucket() {
        let b = StatsGraphsAggregate.playsPerBucket([play("1")], .week, now: now, calendar: cal)
        let at = date("2026-11-10").addingTimeInterval(15 * 3600)
        XCTAssertEqual(StatsGraphsAggregate.bucket(at: at, in: b, start: \.start)?.start, date("2026-11-10"))
    }

    // MARK: Heatmap

    func testHeatmapSpreadsOverHoursInLocalTime() {
        // Tuesday Nov 10 2026, 21:30, 2 h
        let h = StatsGraphsAggregate.heatmap([play("1", time: "21:30", seconds: 7200)], calendar: cal)
        XCTAssertEqual(h.count, 168)
        func at(_ w: Int, _ hr: Int) -> Int { h.first { $0.weekday == w && $0.hour == hr }!.seconds }
        XCTAssertEqual(at(1, 21), 1800)
        XCTAssertEqual(at(1, 22), 3600)
        XCTAssertEqual(at(1, 23), 1800)
        XCTAssertEqual(h.reduce(0) { $0 + $1.seconds }, 7200)
    }

    func testHeatmapCrossesMidnightIntoNextWeekday() {
        // Sunday Nov 15, 23:30 for 1 h → 30 min Sunday 23, 30 min Monday 0
        let h = StatsGraphsAggregate.heatmap([play("1", day: "2026-11-15", time: "23:30", seconds: 3600)], calendar: cal)
        XCTAssertEqual(h.first { $0.weekday == 6 && $0.hour == 23 }?.seconds, 1800)
        XCTAssertEqual(h.first { $0.weekday == 0 && $0.hour == 0 }?.seconds, 1800)
    }

    // MARK: Play types, devices, kinds

    func testPlayTypesPerWeek() {
        let ps = [play("1", day: "2026-11-10"), play("2", day: "2026-11-11", method: "Transcode (v:h264 a:aac)"),
                  play("3", day: "2026-11-12", method: "DirectStream"), play("4", day: "2026-11-03", method: "Transcode")]
        let t = StatsGraphsAggregate.playTypes(ps, .month, now: now, calendar: cal)
        let wk = t.first { $0.start == date("2026-11-09") }
        XCTAssertEqual(wk?.directPlay, 1); XCTAssertEqual(wk?.directStream, 1); XCTAssertEqual(wk?.transcode, 1)
        XCTAssertEqual(t.first { $0.start == date("2026-11-02") }?.transcode, 1)
        XCTAssertEqual(t.reduce(0) { $0 + $1.total }, 4)
    }

    func testDevicesTopByWatchTime() {
        var ps = [play("1", device: "TV", seconds: 7200), play("2", device: "Mac", seconds: 3600),
                  play("3", device: "Mac", seconds: 1800), play("4", client: "Emby Web", device: "", seconds: 600)]
        for i in 0..<6 { ps.append(play("x\(i)", device: "D\(i)", seconds: 120)) }
        let d = StatsGraphsAggregate.devices(ps)
        XCTAssertEqual(d.count, 6)
        XCTAssertEqual(d[0].name, "TV"); XCTAssertEqual(d[1].name, "Mac"); XCTAssertEqual(d[1].plays, 2)
        XCTAssertEqual(d[1].seconds, 5400); XCTAssertEqual(d[1].client, "Cove")
        XCTAssertEqual(d[2].name, "Emby Web")   // no device: counted under the client
    }

    func testKindsSplit() {
        let k = StatsGraphsAggregate.kinds([play("1"), play("2", type: "Episode", name: "S - s1e1 - A", seconds: 1800),
                                            play("3", type: "Audio", seconds: 300)])
        XCTAssertEqual(k.movies, 1); XCTAssertEqual(k.episodes, 1); XCTAssertEqual(k.others, 1)
        XCTAssertEqual(k.totalSeconds, 5700)
    }

    // MARK: Libraries

    func testLibraryEligibilityAndCounts() {
        XCTAssertTrue(StatsLibrariesAggregate.eligible("movies"))
        XCTAssertTrue(StatsLibrariesAggregate.eligible("TvShows"))
        XCTAssertTrue(StatsLibrariesAggregate.eligible("music"))
        XCTAssertFalse(StatsLibrariesAggregate.eligible("boxsets"))
        XCTAssertFalse(StatsLibrariesAggregate.eligible(nil))
        XCTAssertEqual(StatsLibrariesAggregate.countTypes("tvshows").map(\.type), ["Series", "Episode"])
        XCTAssertEqual(StatsLibrariesAggregate.countsText([StatsLibCount(label: "Series", count: 5),
                                                           StatsLibCount(label: "Episodes", count: 12)]), "5 Series · 12 Episodes")
    }

    func testUnmappedIsDistinctNewestFirstAndLimited() {
        let ps = [play("1", day: "2026-11-01", item: "a"), play("2", day: "2026-11-10", item: "b"),
                  play("3", day: "2026-11-11", item: "a"), play("4", day: "2026-11-12", item: "c")]
        let u = StatsLibrariesAggregate.unmapped(ps, known: ["c": "L1"], limit: 1)
        XCTAssertEqual(u.ids, ["a"]); XCTAssertTrue(u.truncated)
        let all = StatsLibrariesAggregate.unmapped(ps, known: ["c": ""], limit: 10)
        XCTAssertEqual(all.ids, ["a", "b"]); XCTAssertFalse(all.truncated)
    }

    func testLibraryMappingAndAggregation() {
        var map: [String: String] = [:]
        StatsLibrariesAggregate.record(found: ["m1", "m2"], library: "L1", into: &map)
        StatsLibrariesAggregate.record(found: ["e1"], library: "L2", into: &map)
        StatsLibrariesAggregate.markMissing(["m1", "e1", "gone"], into: &map)
        XCTAssertEqual(map["m1"], "L1"); XCTAssertEqual(map["gone"], "")
        let ps = [play("1", item: "m1", seconds: 3600), play("2", item: "m1", seconds: 3600), play("3", item: "m2", seconds: 600),
                  play("4", type: "Episode", name: "Show - s1e1 - A", item: "e1", seconds: 9000),
                  play("5", item: "gone", seconds: 99999)]
        let libs = [StatsLibraryInfo(id: "L1", name: "Movies", kind: "movies"), StatsLibraryInfo(id: "L2", name: "TV", kind: "tvshows"),
                    StatsLibraryInfo(id: "L3", name: "Music", kind: "music")]
        let u = StatsLibrariesAggregate.usage(libs, plays: ps, map: map, counts: ["L1": [StatsLibCount(label: "Movies", count: 2)]])
        XCTAssertEqual(u.map(\.lib.id), ["L2", "L1", "L3"])   // most watch time first, the unplayed library last
        XCTAssertEqual(u[0].seconds, 9000); XCTAssertEqual(u[0].tops.first?.top.title, "Show"); XCTAssertEqual(u[0].tops.first?.show, true)
        XCTAssertEqual(u[1].plays, 3); XCTAssertEqual(u[1].counts.first?.count, 2)
        XCTAssertEqual(u[1].tops.map(\.top.itemId), ["m1", "m2"])
        XCTAssertEqual(u[2].plays, 0)
    }

    func testTopsCollapseEpisodesAndLimitToThree() {
        let ps = (1...4).map { play("m\($0)", item: "m\($0)", seconds: 1000 * $0) }
            + [play("e1", type: "Episode", name: "X - s1e1 - A", item: "e1", seconds: 3000),
               play("e2", type: "Episode", name: "X - s1e2 - B", item: "e2", seconds: 3000)]
        let t = StatsLibrariesAggregate.tops(ps)
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t[0].top.title, "X"); XCTAssertEqual(t[0].top.plays, 2)
        XCTAssertEqual(t[1].top.itemId, "m4"); XCTAssertEqual(t[2].top.itemId, "m3")
    }

    func testDecodeIdsAndTotal() {
        let d = #"{"Items":[{"Id":"a","Name":"A"},{"Id":"b"}],"TotalRecordCount":"42"}"#.data(using: .utf8)!
        XCTAssertEqual(StatsLibrariesAggregate.ids(d), ["a", "b"])
        XCTAssertEqual(StatsLibrariesAggregate.total(d), 42)
        XCTAssertNil(StatsLibrariesAggregate.total(Data("[]".utf8)))
    }
}
