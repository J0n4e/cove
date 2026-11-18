import XCTest
@testable import Cove

/// Activity polish: History day headers/summaries and row labels, Users hides idle users, the section rename,
/// Overview's Recently watched.
final class StatsHistoryPolishTests: XCTestCase {
    private func play(_ id: String, type: String = "Movie", name: String = "Film", method: String = "DirectPlay",
                      seconds: Int = 3600, day: String = "2026-11-10", hour: Int = 20, item: String? = nil) -> StatsPlay {
        let d = StatsDecode.time("\(hour):00", day: day) ?? Date()
        return StatsPlay(id: id, start: d, day: day, itemId: item ?? "i" + id, name: name, type: type, client: "Cove",
                         device: "Mac", method: method, seconds: seconds)
    }
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
    }

    func testDayTitle() {
        let now = date("2026-11-18 12:00")
        XCTAssertEqual(StatsHistoryText.dayTitle(date("2026-11-18 00:00"), now: now, calendar: cal), "Today")
        XCTAssertEqual(StatsHistoryText.dayTitle(date("2026-11-17 00:00"), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(StatsHistoryText.dayTitle(date("2026-11-16 00:00"), now: now, calendar: cal), "Mon 16 Nov")
        XCTAssertEqual(StatsHistoryText.dayTitle(date("2025-11-16 00:00"), now: now, calendar: cal), "Sun 16 Nov 2025")
    }

    func testDaySummary() {
        XCTAssertEqual(StatsHistoryText.daySummary([play("1", seconds: 3600), play("2", seconds: 3000), play("3", seconds: 600)]),
                       "3 plays · 2h 0m")
        XCTAssertEqual(StatsHistoryText.daySummary([play("1", seconds: 2 * 3600 + 40 * 60)]), "1 play · 2h 40m")
        XCTAssertEqual(StatsHistoryText.daySummary([play("1", seconds: 45 * 60)]), "1 play · 45m")
        XCTAssertEqual(StatsHistoryText.daySummary([play("1", seconds: 20)]), "1 play · 1m")
    }

    func testRowLabels() {
        let ep = play("1", type: "Episode", name: "Show - s2e4 - Pilot")
        XCTAssertEqual(ep.displayTitle, "Show")
        XCTAssertEqual(StatsHistoryText.secondLine(ep), "S2:E4 · Pilot")
        XCTAssertEqual(StatsHistoryText.secondLine(play("2")), "Movie")
        XCTAssertEqual(StatsHistoryText.methodShort("DirectPlay"), "DP")
        XCTAssertEqual(StatsHistoryText.methodShort("DirectStream (v:h264)"), "DS")
        XCTAssertEqual(StatsHistoryText.methodShort("Transcode (v:h264 a:aac)"), "TC")
        XCTAssertEqual(StatsHistoryText.methodShort(""), "—")
        XCTAssertEqual(StatsHistoryText.methodTint("Transcode (v:h264)"), .orange)
        XCTAssertEqual(StatsHistoryText.deviceIcon(play("3")), "laptopcomputer")
    }

    func testUsersWithoutPlaysHidden() {
        func s(_ n: String, _ sec: Int, _ p: Int) -> StatsUserSummary {
            StatsUserSummary(id: n, name: n, imageTag: nil, plays: p, seconds: sec, movies: 0, episodes: 0, titles: 0,
                             topDevice: nil, methods: StatsMethodShares(), lastSeen: nil, address: nil)
        }
        let all = StatsUsersAggregate.sorted([s("idle", 0, 0), s("b", 100, 1), s("a", 500, 2)])
        XCTAssertEqual(StatsUsersAggregate.withPlays(all).map(\.name), ["a", "b"])   // watch-time order kept
        XCTAssertEqual(StatsUsersAggregate.totals(all).totalUsers, 3)                // summary still counts everyone
        XCTAssertTrue(StatsUsersAggregate.withPlays([s("idle", 0, 0)]).isEmpty)       // → empty state
    }

    func testActivityRename() {
        XCTAssertEqual(ActivitySection.title, "Activity")
        XCTAssertEqual(ActivitySection.icon, "chart.bar.xaxis")
        XCTAssertEqual(NavOrder.nowPlaying, "__nowplaying")   // stored id unchanged: saved order/visibility survive
    }

    func testRecentlyWatched() {
        let ps = [play("1", hour: 10, item: "m1"),
                  play("2", type: "Episode", name: "Show - s1e1 - A", hour: 11),
                  play("3", type: "Episode", name: "Show - s2e4 - B", hour: 12),
                  play("4", hour: 13, item: "m1"),
                  play("5", type: "Audio", name: "Song", hour: 14)]
        let r = StatsAggregate.recentlyWatched(ps)
        XCTAssertEqual(r.map(\.top.title), ["Film", "Show"])
        XCTAssertEqual(r[1].caption, "S2:E4"); XCTAssertTrue(r[1].show); XCTAssertEqual(r[1].top.itemId, "i3")
        XCTAssertFalse(r[0].show); XCTAssertEqual(r[0].top.plays, 2)
        let many = (0..<15).map { play("\($0)", hour: $0, item: "m\($0)") }
        XCTAssertEqual(StatsAggregate.recentlyWatched(many).count, 10)
        XCTAssertEqual(StatsAggregate.recentlyWatched(many).first?.top.itemId, "m14")
    }
}
