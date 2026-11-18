import XCTest
@testable import Cove

/// Stats phase 1: plugin JSON decoding (both servers), the 60 s filter, aggregation, history grouping, detection.
final class StatsTests: XCTestCase {
    // Emby faush01/playback_reporting GetUsageForUser: Time "HH:mm", every value a string
    let embyDay = """
    [{"Time":"21:05","Id":"12345","Name":"The Matrix","Type":"Movie","Client":"Cove","Method":"DirectPlay",
      "Device":"MacBook","Duration":"7200","RowId":"17","RemoteAddress":"10.0.0.2"},
     {"Time":"22:10","Id":"999","Name":"Trailer","Type":"Movie","Client":"Emby Web","Method":"Transcode",
      "Device":"Chrome","Duration":"30","RowId":"18"}]
    """.data(using: .utf8)!
    // Jellyfin GetUserReportData: Time "h:mm tt", Duration a string, some fields missing
    let jellyDay = """
    [{"Time":"9:05 PM","Id":"a1b2c3","Name":"Severance - s1e2 - Half Loop","Type":"Episode","Client":"Jellyfin Web",
      "Method":"Transcode (v:h264 a:aac)","Device":"Firefox","Duration":"3000","RowId":"5"},
     {"Time":"12:15 AM","Id":"d4e5","Name":"Severance - s01e03 - In Perpetuity","Type":"Episode","Duration":120}]
    """.data(using: .utf8)!

    func testDecodeEmbyDay() {
        let p = StatsDecode.dayPlays(embyDay, day: "2026-11-10")
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].itemId, "12345"); XCTAssertEqual(p[0].seconds, 7200); XCTAssertTrue(p[0].isMovie)
        XCTAssertEqual(p[0].client, "Cove"); XCTAssertEqual(p[0].device, "MacBook")
        let c = Calendar.current.dateComponents([.hour, .minute], from: p[0].start)
        XCTAssertEqual(c.hour, 21); XCTAssertEqual(c.minute, 5)
        XCTAssertEqual(StatsAggregate.methodText(p[0].method), "Direct play")
    }

    func testDecodeJellyfinDay() {
        let p = StatsDecode.dayPlays(jellyDay, day: "2026-11-10")
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(Calendar.current.component(.hour, from: p[0].start), 21)
        XCTAssertEqual(Calendar.current.component(.hour, from: p[1].start), 0)
        XCTAssertEqual(p[0].episode, StatsEpisodeName(series: "Severance", season: 1, number: 2, title: "Half Loop"))
        XCTAssertEqual(p[0].displaySubtitle, "S1:E2 · Half Loop")
        XCTAssertEqual(p[1].episode?.number, 3)
        XCTAssertEqual(p[1].seconds, 120); XCTAssertEqual(p[1].client, "")
        XCTAssertEqual(StatsDecode.dayPlays(Data("{}".utf8), day: "2026-11-10").count, 0)
    }

    func testActivityDecode() {
        let d = """
        [{"user_id":"labels_user","user_name":"labels_user","user_usage":{}},
         {"user_id":"abcd1234ef","user_name":"me","user_usage":{"2026-11-09":0,"2026-11-10":"3600","2026-11-11":60}},
         {"user_id":"other","user_name":"x","user_usage":{"2026-11-10":99}}]
        """.data(using: .utf8)!
        let u = StatsDecode.activity(d, userId: "ABCD-1234-EF")
        XCTAssertEqual(u["2026-11-10"], 3600)
        XCTAssertEqual(StatsAggregate.activeDays(u), ["2026-11-11", "2026-11-10"])
    }

    func testUnder60sDropped() {
        let p = StatsAggregate.filtered(StatsDecode.dayPlays(embyDay, day: "2026-11-10"))
        XCTAssertEqual(p.map(\.itemId), ["12345"])
        XCTAssertEqual(StatsAggregate.minSeconds, 60)
    }

    func play(_ id: String, _ name: String, _ type: String, _ day: String, _ s: Int) -> StatsPlay {
        StatsPlay(id: id + day + name, start: StatsDecode.time("20:00", day: day)!, day: day, itemId: id, name: name, type: type,
                  client: "", device: "", method: "", seconds: s)
    }

    func testAggregation() {
        let cal = Calendar.current
        let now = StatsDecode.time("12:00", day: "2026-11-18")!
        let plays = [
            play("m1", "A", "Movie", "2026-11-18", 3600), play("m1", "A", "Movie", "2026-11-12", 1800),
            play("m2", "B", "Movie", "2026-11-17", 4000), play("e1", "Show - s1e1 - P", "Episode", "2026-11-16", 1200),
            play("e2", "Show - s1e2 - Q", "Episode", "2026-11-17", 1200), play("m3", "Old", "Movie", "2026-09-01", 7200),
        ]
        let week = StatsAggregate.inRange(plays, .week, now: now, calendar: cal)
        XCTAssertEqual(week.count, 5)
        XCTAssertEqual(StatsAggregate.totalSeconds(week), 11800)
        XCTAssertEqual(StatsAggregate.inRange(plays, .year, now: now, calendar: cal).count, 6)
        let movies = StatsAggregate.topMovies(week)
        XCTAssertEqual(movies.map(\.itemId), ["m1", "m2"]); XCTAssertEqual(movies[0].plays, 2)
        let shows = StatsAggregate.topShows(week)
        XCTAssertEqual(shows.count, 1); XCTAssertEqual(shows[0].title, "Show"); XCTAssertEqual(shows[0].seconds, 2400)
        let bars = StatsAggregate.bars(week, .week, now: now, calendar: cal)
        XCTAssertEqual(bars.count, 7); XCTAssertEqual(bars.last?.seconds, 3600)
        let months = StatsAggregate.bars(plays, .year, now: now, calendar: cal)
        XCTAssertEqual(months.last?.id, "2026-11"); XCTAssertEqual(months.last?.seconds, 11800)
        XCTAssertEqual(StatsAggregate.hoursText(5400), "1.5 h"); XCTAssertEqual(StatsAggregate.hoursText(600), "10 min")
        XCTAssertTrue(StatsAggregate.isFewData(Array(plays.prefix(2)))); XCTAssertFalse(StatsAggregate.isFewData(plays))
    }

    func testHistoryGroupedByDay() {
        var late = play("m1", "A", "Movie", "2026-11-17", 3600)
        late = StatsPlay(id: "late", start: StatsDecode.time("23:00", day: "2026-11-17")!, day: late.day, itemId: "m9", name: "Late",
                         type: "Movie", client: "", device: "", method: "", seconds: 100)
        let g = StatsAggregate.groupByDay([play("m1", "A", "Movie", "2026-11-16", 3600), play("m2", "B", "Movie", "2026-11-17", 3600), late])
        XCTAssertEqual(g.map(\.id), ["2026-11-17", "2026-11-16"])
        XCTAssertEqual(g[0].plays.map(\.itemId), ["m9", "m2"])
    }

    func testDetection() {
        XCTAssertEqual(StatsDetection.decide(isAdmin: false, pluginListed: true, probe: 200), .notAdmin)
        XCTAssertEqual(StatsDetection.decide(isAdmin: true, pluginListed: true, probe: 200), .available)
        XCTAssertEqual(StatsDetection.decide(isAdmin: true, pluginListed: false, probe: 404), .pluginMissing)
        XCTAssertEqual(StatsDetection.decide(isAdmin: true, pluginListed: false, probe: nil), .pluginMissing)
        XCTAssertEqual(StatsDetection.decide(isAdmin: true, pluginListed: true, probe: nil), .failed)
        XCTAssertEqual(StatsDetection.decide(isAdmin: nil, pluginListed: nil, probe: 403), .notAdmin)
        XCTAssertTrue(StatsDecode.pluginListed(names: ["Trakt", "Playback Reporting"]))
        XCTAssertFalse(StatsDecode.pluginListed(names: ["Reports"]))
        XCTAssertEqual(StatsDecode.isAdministrator(Data(#"{"Name":"me","Policy":{"IsAdministrator":true}}"#.utf8)), true)
        XCTAssertEqual(StatsDecode.isAdministrator(Data(#"{"Policy":{"IsAdministrator":false}}"#.utf8)), false)
        XCTAssertNil(StatsDecode.isAdministrator(Data(#"{"Name":"me"}"#.utf8)))
    }

    func testQueryParametersPerServer() {
        let f: StatsFetch = { _, _ in nil }
        XCTAssertEqual(EmbyStatsService(fetch: f).activityQuery(days: 30, end: "2026-11-18", dataType: "time"),
                       ["days": "30", "end_date": "2026-11-18", "data_type": "time"])
        let j = JellyfinStatsService(fetch: f, timezoneOffset: 1)
        XCTAssertEqual(j.activityQuery(days: 7, end: "2026-11-18", dataType: "count"),
                       ["days": "7", "endDate": "2026-11-18", "dataType": "count", "timezoneOffset": "1"])
        XCTAssertEqual(j.dayQuery(), ["timezoneOffset": "1"])
    }
}
