import XCTest
import SwiftUI
import AppKit
@testable import Cove

final class InsightsTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    /// A play on `day` at `hour`:00 UTC.
    private func play(_ id: String, day: String, hour: Int = 20, item: String? = nil, name: String = "Movie",
                      type: String = "Movie", seconds: Int = 3600, user: String = "u1", userName: String = "Ann",
                      device: String = "Mac") -> StatsPlay {
        let p = day.split(separator: "-").compactMap { Int($0) }
        let start = utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!
        var s = StatsPlay(id: id, start: start, day: day, itemId: item ?? id, name: name, type: type,
                          client: "Cove", device: device, method: "DirectPlay", seconds: seconds)
        s.userId = user; s.userName = userName
        return s
    }
    private func ep(_ id: String, day: String, series: String = "Show", n: Int = 1, user: String = "u1", userName: String = "Ann",
                    hour: Int = 20, seconds: Int = 1800) -> StatsPlay {
        play(id, day: day, hour: hour, name: "\(series) - s1e\(n) - Ep \(n)", type: "Episode", seconds: seconds, user: user, userName: userName)
    }

    // MARK: Busiest day / hour

    func testBusiestWeekdayAndHour() {
        // 2026-11-01 is a Sunday, 2026-11-02 a Monday
        let ps = [play("a", day: "2026-11-01", hour: 21, seconds: 7200), play("b", day: "2026-11-02", hour: 9, seconds: 600),
                  play("c", day: "2026-11-01", hour: 21, seconds: 600)]
        let w = Insights.weekdaySeconds(ps, calendar: utc)
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(w[6], 7800)
        XCTAssertEqual(w[0], 600)
        XCTAssertEqual(Insights.busiest(w), InsightsSlot(index: 6, seconds: 7800))
        let h = Insights.hourSeconds(ps, calendar: utc)
        XCTAssertEqual(Insights.busiest(h)?.index, 21)
        XCTAssertNil(Insights.busiest(Array(repeating: 0, count: 24)))
        XCTAssertEqual(Insights.busiest([5, 5, 1])?.index, 0, "ties: the earlier slot")
    }

    // MARK: Binge

    func testBingeDetection() {
        let ps = [ep("1", day: "2026-11-03", n: 1), ep("2", day: "2026-11-03", n: 2), ep("3", day: "2026-11-03", n: 3),
                  ep("3b", day: "2026-11-03", n: 3).withItem("3"),   // the same episode again doesn't count twice
                  ep("4", day: "2026-11-04", series: "Other", n: 1), ep("5", day: "2026-11-04", series: "Other", n: 2),
                  ep("6", day: "2026-11-03", n: 4, user: "u2", userName: "Bob")]
        let b = Insights.binge(ps)
        XCTAssertEqual(b?.series, "Show")
        XCTAssertEqual(b?.episodes, 3)
        XCTAssertEqual(b?.user, "Ann")
        XCTAssertEqual(b?.day, "2026-11-03")
        XCTAssertNil(Insights.binge([ep("x", day: "2026-11-03")]), "one episode isn't a binge")
        XCTAssertNil(Insights.binge([play("m", day: "2026-11-03")]))
    }

    // MARK: Longest session

    func testLongestSession() {
        let ps = [play("a", day: "2026-11-01", seconds: 100), play("b", day: "2026-11-02", seconds: 9000), play("c", day: "2026-11-03", seconds: 50)]
        XCTAssertEqual(Insights.longestSession(ps)?.id, "b")
        XCTAssertNil(Insights.longestSession([]))
    }

    // MARK: Genres

    func testTopGenres() {
        let ps = [play("a", day: "2026-11-01", seconds: 3600), play("b", day: "2026-11-01", seconds: 7200), play("c", day: "2026-11-01", seconds: 60)]
        let g = ["a": ["Drama", "Comedy"], "b": ["Action", "Drama", "Drama"], "c": ["Horror"]]
        let top = Insights.topGenres(ps, genres: g)
        XCTAssertEqual(top.map(\.label), ["Drama", "Action", "Comedy", "Horror"])
        XCTAssertEqual(top[0].seconds, 10800)
        XCTAssertEqual(top[0].plays, 2)
        XCTAssertEqual(Insights.topGenres(ps, genres: g, limit: 2).count, 2)
        XCTAssertTrue(Insights.topGenres(ps, genres: [:]).isEmpty)
    }

    // MARK: Trend

    func testTrendAndChange() {
        XCTAssertEqual(Insights.change(12, 10), 20)
        XCTAssertEqual(Insights.change(5, 10), -50)
        XCTAssertNil(Insights.change(3, 0))
        XCTAssertEqual(Insights.changeText(20, current: 12), "+20%")
        XCTAssertEqual(Insights.changeText(-50, current: 5), "−50%")
        XCTAssertEqual(Insights.changeText(0, current: 5), "±0%")
        XCTAssertEqual(Insights.changeText(nil, current: 3), "new")
        let t = Insights.trend([play("a", day: "2026-11-01"), ep("e", day: "2026-11-01")],
                               previous: [play("p", day: "2026-10-01"), play("q", day: "2026-10-02")], hasPrevious: true)
        XCTAssertEqual(t.movies, 1); XCTAssertEqual(t.episodes, 1)
        XCTAssertEqual(t.moviesChange, -50)
        XCTAssertNil(t.episodesChange)
        XCTAssertNil(Insights.trend([], previous: [], hasPrevious: false).moviesChange)
    }

    // MARK: New vs rewatched

    func testNewVsRewatch() {
        let earlier = [play("old", day: "2026-09-01", item: "m1")]
        let now = [play("a", day: "2026-11-01", item: "m1"),                // played before (earlier period)
                   play("b", day: "2026-11-01", hour: 10, item: "m2"),      // first time
                   play("c", day: "2026-11-02", item: "m2"),                // again in this period
                   play("d", day: "2026-11-02", item: "m1", user: "u2")]    // another user: new for them
        let s = Insights.newVsRewatch(now, earlier: earlier)
        XCTAssertEqual(s.new, 2)
        XCTAssertEqual(s.rewatch, 2)
        XCTAssertEqual(s.newPercent, 50)
        XCTAssertEqual(Insights.newVsRewatch([], earlier: []).newPercent, 0)
    }

    // MARK: Most popular / quiet users / time to finish

    func testMostPopularAndQuietUsers() {
        let ps = [play("a", day: "2026-11-01", item: "m1", name: "Dune"), play("b", day: "2026-11-01", item: "m1", name: "Dune", user: "u2", userName: "Bob"),
                  play("c", day: "2026-11-01", item: "m2", name: "Heat"), play("d", day: "2026-11-02", item: "m2", name: "Heat"),
                  play("e", day: "2026-11-02", item: "m2", name: "Heat")]
        let p = Insights.mostPopular(ps)
        XCTAssertEqual(p?.title, "Dune", "most users beats most plays")
        XCTAssertEqual(p?.users, ["Ann", "Bob"])
        XCTAssertEqual(p?.plays, 2)
        let showPop = Insights.mostPopular([ep("1", day: "2026-11-01", n: 1), ep("2", day: "2026-11-01", n: 2, user: "u2", userName: "Bob")])
        XCTAssertEqual(showPop?.title, "Show"); XCTAssertEqual(showPop?.show, true)

        let prev = [play("x", day: "2026-10-01", user: "u3", userName: "Cleo"), play("y", day: "2026-10-01", user: "u1")]
        XCTAssertEqual(Insights.quietUsers(current: ps, previous: prev), ["Cleo"])
        XCTAssertTrue(Insights.quietUsers(current: ps, previous: []).isEmpty)
    }

    func testTimeToFinish() {
        // m1: started Nov 1 20:00, last play Nov 2 20:00 for 1 h → 25 h; m2 watched once (ignored)
        let ps = [play("a", day: "2026-11-01", item: "m1", seconds: 1800), play("b", day: "2026-11-02", item: "m1", seconds: 3600),
                  play("c", day: "2026-11-02", item: "m2")]
        let f = Insights.timeToFinish(ps)
        XCTAssertEqual(f?.movies, 1)
        XCTAssertEqual(f?.seconds, 25 * 3600)
        XCTAssertNil(Insights.timeToFinish([play("c", day: "2026-11-02")]))
        XCTAssertEqual(Insights.spanText(25 * 3600), "25 h")
        XCTAssertEqual(Insights.spanText(3 * 86400), "3 days")
        XCTAssertEqual(Insights.spanText(600), "10 min")
    }

    func testPeriodsAndData() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!
        let cur = StatsAggregate.days(.month, now: now), prev = Insights.previousDays(.month, now: now)
        XCTAssertEqual(prev.count, 30)
        XCTAssertTrue(Set(cur).isDisjoint(with: prev))
        XCTAssertLessThan(prev.last!, cur.first!)
        XCTAssertTrue(Insights.previousDays(.all, now: now).isEmpty)
        XCTAssertEqual(Insights.lookback(.month), 60)
        XCTAssertEqual(Insights.lookback(.all), StatsRange.all.days)
        let d = Insights.data(current: [play("a", day: "2026-11-01")], previous: [play("b", day: "2026-10-01", user: "u9", userName: "Zed")],
                              hasPrevious: true, genres: ["a": ["Drama"]], calendar: utc)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.genres.first?.label, "Drama")
        XCTAssertEqual(d.quiet, ["Zed"])
        XCTAssertTrue(Insights.data(current: [], previous: [play("b", day: "2026-10-01")], hasPrevious: false, genres: [:]).quiet.isEmpty)
    }

    // MARK: Year in review

    func testYearAggregation() {
        let ps = [play("old", day: "2025-12-31", item: "m0", name: "Old"),
                  play("a", day: "2026-01-05", hour: 18, item: "m1", name: "First", seconds: 7200, device: "TV"),
                  play("b", day: "2026-03-10", item: "m1", name: "First", seconds: 3600, device: "TV"),
                  play("c", day: "2026-03-11", item: "m2", name: "Second", seconds: 1800, device: "Mac"),
                  ep("e1", day: "2026-03-12", n: 1), ep("e2", day: "2026-03-12", n: 2), ep("e3", day: "2026-11-20", n: 3, hour: 23)]
        let r = YearAggregate.review(ps, year: 2026, genres: ["m1": ["Sci-Fi"], "m2": ["Drama"]], calendar: utc)
        XCTAssertEqual(r.year, 2026)
        XCTAssertEqual(r.movies, 2, "distinct movies")
        XCTAssertEqual(r.episodes, 3)
        XCTAssertEqual(r.activeDays, 5)
        XCTAssertEqual(r.seconds, 7200 + 3600 + 1800 + 3 * 1800)
        XCTAssertEqual(r.topMovies.first?.title, "First")
        XCTAssertEqual(r.topShows.first?.top.title, "Show")
        XCTAssertEqual(r.topShows.first?.episodes, 3)
        XCTAssertEqual(r.topGenre, "Sci-Fi")
        XCTAssertEqual(r.busiestMonth, 2, "March")
        XCTAssertEqual(r.binge?.episodes, 2)
        XCTAssertEqual(r.first?.id, "a")
        XCTAssertEqual(r.last?.id, "e3")
        XCTAssertEqual(r.device, "Mac", "most plays (4 on the Mac vs 2 on the TV)")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(YearAggregate.review(ps, year: 2024, genres: [:]).isEmpty)
        XCTAssertEqual(YearAggregate.plays(ps, year: 2025).map(\.id), ["old"])
    }

    func testMonthBarsAndYears() {
        let m = YearAggregate.monthSeconds([play("a", day: "2026-01-02", seconds: 10), play("b", day: "2026-12-31", seconds: 20),
                                            play("c", day: "2026-12-01", seconds: 5)])
        XCTAssertEqual(m.count, 12)
        XCTAssertEqual(m[0], 10); XCTAssertEqual(m[11], 25); XCTAssertEqual(m[5], 0)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!
        XCTAssertEqual(YearAggregate.years(days: ["2024-05-01", "2025-01-01", "2025-02-01"], now: now), [2026, 2025, 2024])
        XCTAssertEqual(YearAggregate.years(days: [], now: now), [2026])
        let d = YearAggregate.days(2026, now: now)
        XCTAssertEqual(d.first, "2026-01-01"); XCTAssertEqual(d.last, "2026-11-22"); XCTAssertEqual(d.count, 326)
        XCTAssertEqual(YearAggregate.days(2024, now: now).count, 366, "a full leap year")
    }

    // MARK: Retention

    func testRetention() {
        XCTAssertEqual(InsightsRetention.maxDataAge(Data(#"{"MaxDataAge":3,"Other":1}"#.utf8)), 3)
        XCTAssertEqual(InsightsRetention.maxDataAge(Data(#"{"MaxDataAge":"-1"}"#.utf8)), -1)
        XCTAssertNil(InsightsRetention.maxDataAge(Data(#"{"Other":1}"#.utf8)))
        XCTAssertEqual(InsightsRetention.pluginId(Data(#"[{"Name":"Trakt","Id":"1"},{"Name":"Playback Reporting","Id":"abc"}]"#.utf8)), "abc")
        XCTAssertNil(InsightsRetention.pluginId(Data(#"[{"Name":"Trakt","Id":"1"}]"#.utf8)))
        XCTAssertEqual(InsightsRetention.hint(maxAge: 3, need: 12),
                       "Your server keeps 3 months of history: Settings → Playback Reporting → Max data age")
        XCTAssertNil(InsightsRetention.hint(maxAge: 12, need: 12))
        XCTAssertNil(InsightsRetention.hint(maxAge: -1, need: 12))
        XCTAssertNil(InsightsRetention.hint(maxAge: nil, need: 12))
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 22))!
        XCTAssertNotNil(InsightsRetention.yearHint(maxAge: 3, year: 2026, now: now))
        XCTAssertNil(InsightsRetention.yearHint(maxAge: 24, year: 2026, now: now))
        XCTAssertNil(InsightsRetention.yearHint(maxAge: -1, year: 2025, now: now))
    }

    // MARK: Decoding

    func testDecodingReuseEmbyAndJellyfin() {
        // Both shapes go through the existing StatsDecode.dayPlays (Jellyfin: a list; Emby: an object with activity)
        let row = #"{"RowId":"7","Time":"21:05","Id":"m1","Name":"Dune","Type":"Movie","Duration":"4000","Client":"Cove","Device":"Mac","Method":"DirectPlay"}"#
        let jf = StatsDecode.dayPlays(Data("[\(row)]".utf8), day: "2026-11-01")
        let em = StatsDecode.dayPlays(Data(#"{"user_name":"Ann","user_id":"u1","activity":[\#(row)]}"#.utf8), day: "2026-11-01")
        XCTAssertEqual(jf.count, 1); XCTAssertEqual(em.count, 1)
        XCTAssertEqual(jf[0].itemId, em[0].itemId)
        XCTAssertEqual(jf[0].userId, "", "the loader tags the user")
    }

    func testGenresDecode() {
        let d = InsightsDecode.genres(Data(#"{"Items":[{"Id":"m1","Genres":["Drama"]},{"Id":"e1","Genres":[],"SeriesId":"s1"},{"Name":"no id"}]}"#.utf8))
        XCTAssertEqual(d["m1"]?.genres, ["Drama"])
        XCTAssertEqual(d["e1"]?.series, "s1")
        XCTAssertEqual(d.count, 2)
    }

    func testPlayedItemsFallback() {
        let json = #"""
        {"Items":[
          {"Id":"m1","Name":"Dune","Type":"Movie","RunTimeTicks":93000000000,"Genres":["Sci-Fi"],"UserData":{"LastPlayedDate":"2026-03-05T20:00:00.0000000Z"}},
          {"Id":"e1","Name":"Pilot","Type":"Episode","SeriesName":"Show","ParentIndexNumber":1,"IndexNumber":2,"RunTimeTicks":18000000000,"UserData":{"LastPlayedDate":"2025-12-31T10:00:00Z"}},
          {"Id":"x","Name":"Never","Type":"Movie","UserData":{}}
        ]}
        """#
        let r = InsightsDecode.playedItems(Data(json.utf8), calendar: utc)
        XCTAssertEqual(r.plays.count, 2)
        XCTAssertEqual(r.plays[0].day, "2026-03-05")
        XCTAssertEqual(r.plays[0].seconds, 9300)
        XCTAssertEqual(r.plays[1].displayTitle, "Show")
        XCTAssertEqual(r.plays[1].episode?.number, 2)
        XCTAssertEqual(r.genres["m1"], ["Sci-Fi"])
        let review = YearAggregate.review(r.plays, year: 2026, genres: r.genres, calendar: utc)
        XCTAssertEqual(review.movies, 1); XCTAssertEqual(review.episodes, 0); XCTAssertEqual(review.topGenre, "Sci-Fi")
    }

    // MARK: Tabs + share image

    @MainActor
    func testTabs() {
        XCTAssertTrue(ActivityPage.statsPages(stats: true).contains(.insights))
        XCTAssertFalse(ActivityPage.statsPages(stats: false).contains(.insights))
        XCTAssertEqual(ActivityPage.statsPages(stats: true).last, .yearInReview)
        XCTAssertEqual(ActivityPage.statsPages(stats: false).last, .yearInReview)
        XCTAssertEqual(ActivityPage.yearInReview.title, "Year in review")
        XCTAssertEqual(InsightsModel.ranges, [.month, .year, .all])
    }

    @MainActor
    func testShareImageSize() {
        let r = YearAggregate.review([play("a", day: "2026-01-05", name: "Dune"), ep("e1", day: "2026-02-01"), ep("e2", day: "2026-02-01", n: 2)],
                                     year: 2026, genres: ["a": ["Sci-Fi"]], calendar: utc)
        let img = YearShare.render(review: r, userName: "Ann", posters: [:], accent: .red)
        XCTAssertEqual(img?.width, 1080)
        XCTAssertEqual(img?.height, 1920)
        let png = YearShare.png(review: r, userName: "Ann", posters: [:], accent: .red)
        XCTAssertNotNil(png)
        XCTAssertEqual(png.flatMap { NSBitmapImageRep(data: $0) }?.pixelsHigh, 1920)
    }
}

private extension StatsPlay {
    func withItem(_ item: String) -> StatsPlay {
        var p = StatsPlay(id: id, start: start, day: day, itemId: item, name: name, type: type, client: client, device: device,
                          method: method, seconds: seconds, remoteAddress: remoteAddress)
        p.userId = userId; p.userName = userName
        return p
    }
}
