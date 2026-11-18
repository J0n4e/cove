import XCTest
@testable import Cove

/// Now Playing → Users: per-user aggregation, play types, IP classification, sort, summary row, decoding.
final class StatsUsersTests: XCTestCase {
    private func play(_ id: String, type: String = "Movie", name: String = "Film", method: String = "DirectPlay",
                      device: String = "Mac", seconds: Int = 3600, day: String = "2026-11-10", hour: Int = 20,
                      addr: String = "") -> StatsPlay {
        let d = StatsDecode.time("\(hour):00", day: day) ?? Date()
        return StatsPlay(id: id, start: d, day: day, itemId: "i" + id, name: name, type: type, client: "Cove",
                         device: device, method: method, seconds: seconds, remoteAddress: addr)
    }
    private let user = StatsServerUser(id: "u1", name: "John Doe", lastActivity: nil, imageTag: nil)

    func testSummaryCountsAndSplit() {
        let ps = [play("1"), play("2", type: "Episode", name: "Show - s1e1 - A", device: "TV"),
                  play("3", type: "Episode", name: "Show - s1e2 - B", device: "Mac", seconds: 1800),
                  play("4", type: "Episode", name: "Other - s2e1 - C", device: "Mac")]
        let s = StatsUsersAggregate.summary(user, plays: ps)
        XCTAssertEqual(s.plays, 4)
        XCTAssertEqual(s.seconds, 3600 * 3 + 1800)
        XCTAssertEqual(s.movies, 1); XCTAssertEqual(s.episodes, 3)
        XCTAssertEqual(s.titles, 3)            // the film + two shows
        XCTAssertEqual(s.topDevice, "Mac")
        XCTAssertNil(s.address)
    }

    func testMethodSharesIncludingJellyfinStrings() {
        let ps = [play("1"), play("2", method: "DirectStream"), play("3", method: "Transcode (v:h264 a:aac)"),
                  play("4", method: "Transcode"), play("5", method: "")]
        let m = StatsUsersAggregate.methodShares(ps)
        XCTAssertEqual(m.directPlay, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.directStream, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.transcode, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.text, "25% DP / 25% DS / 50% TC")
        XCTAssertEqual(StatsUsersAggregate.methodKind("DirectStream (a:aac)"), .directStream)
        XCTAssertTrue(StatsUsersAggregate.methodShares([]).isEmpty)
    }

    func testPercentsAddUpTo100() {
        XCTAssertEqual(StatsUsersAggregate.percents([1, 1, 1]).reduce(0, +), 100)
        XCTAssertEqual(StatsUsersAggregate.percents([0.07, 0.21, 0.72]), [7, 21, 72])
        XCTAssertEqual(StatsUsersAggregate.percents([0, 0, 0]), [0, 0, 0])
    }

    func testLatestAddressAndLastSeen() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let u = StatsServerUser(id: "u", name: "x", lastActivity: old, imageTag: nil)
        let ps = [play("1", hour: 10, addr: "192.168.1.5"), play("2", hour: 22, addr: "217.84.235.168")]
        let s = StatsUsersAggregate.summary(u, plays: ps)
        XCTAssertEqual(s.address, "217.84.235.168")
        XCTAssertEqual(s.isLocal, false)
        XCTAssertEqual(s.lastSeen, ps[1].start)
    }

    func testIPClassification() {
        for a in ["10.1.2.3", "192.168.0.10", "172.16.0.1", "172.31.255.1", "127.0.0.1", "169.254.1.1", "100.64.0.5",
                  "::1", "fd00::1", "fe80::1", "::ffff:192.168.1.2", "192.168.1.2:8096", "[fd12::1]:8096"] {
            XCTAssertEqual(StatsNet.isLocal(a), true, a)
        }
        for a in ["217.84.235.168", "172.32.0.1", "8.8.8.8", "2001:db8::1", "::ffff:8.8.8.8"] {
            XCTAssertEqual(StatsNet.isLocal(a), false, a)
        }
        XCTAssertNil(StatsNet.isLocal(""))
        XCTAssertNil(StatsNet.isLocal("not an ip"))
    }

    func testSortByWatchTime() {
        func s(_ n: String, _ sec: Int, _ p: Int) -> StatsUserSummary {
            StatsUserSummary(id: n, name: n, imageTag: nil, plays: p, seconds: sec, movies: 0, episodes: 0, titles: 0,
                             topDevice: nil, methods: StatsMethodShares(), lastSeen: nil, address: nil)
        }
        let sorted = StatsUsersAggregate.sorted([s("b", 100, 1), s("a", 500, 2), s("c", 100, 5), s("d", 0, 0)])
        XCTAssertEqual(sorted.map(\.name), ["a", "c", "b", "d"])
        let t = StatsUsersAggregate.totals(sorted)
        XCTAssertEqual(t.totalUsers, 4); XCTAssertEqual(t.activeUsers, 3)
        XCTAssertEqual(t.mostActive, "a")
        XCTAssertEqual(t.avgPlaysText, "2.7")                 // (2+5+1)/3, the idle user not counted
        XCTAssertEqual(t.avgSeconds, 700.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(StatsUsersAggregate.totals([]).avgPlaysText, "0.0")
        XCTAssertNil(StatsUsersAggregate.totals([]).mostActive)
    }

    func testDecodeActivityAllAndUsers() {
        let act = """
        [{"user_id":"labels_user","user_usage":{"2026-11-10":0}},
         {"user_id":"AB-CD","user_name":"a","user_usage":{"2026-11-10":"3600","2026-11-11":0}},
         {"user_id":"ef","user_usage":{"2026-11-10":60}}]
        """.data(using: .utf8)!
        let a = StatsDecode.activityAll(act)
        XCTAssertEqual(a["abcd"]?["2026-11-10"], 3600)
        XCTAssertEqual(a["ef"]?["2026-11-10"], 60)
        XCTAssertNil(a["labelsuser"])
        let users = """
        [{"Id":"u1","Name":"John","LastActivityDate":"2026-11-14T00:01:23.1234567Z","PrimaryImageTag":"t"},
         {"Id":"u2","Name":"Mary","LastActivityDate":"0001-01-01T00:00:00.0000000Z"}]
        """.data(using: .utf8)!
        let u = StatsDecode.serverUsers(users)
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[0].imageTag, "t"); XCTAssertNil(u[1].imageTag)
        XCTAssertNotNil(u[0].lastActivity); XCTAssertNil(u[1].lastActivity)
        XCTAssertEqual(Int(u[0].lastActivity!.timeIntervalSince1970) % 60, 23)
    }

    func testEmbyRemoteAddressDecoded() {
        let d = """
        {"activity":[{"Time":"21:05","Id":"1","Name":"M","Type":"Movie","Duration":"100","RemoteAddress":"10.0.0.2"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(StatsDecode.dayPlays(d, day: "2026-11-10").first?.remoteAddress, "10.0.0.2")
    }

    func testInitialsAndColor() {
        XCTAssertEqual(StatsUsersAggregate.initials("John Doe"), "JD")
        XCTAssertEqual(StatsUsersAggregate.initials("mario"), "MA")
        XCTAssertEqual(StatsUsersAggregate.initials(""), "?")
        let i = StatsUsersAggregate.colorIndex("mario", count: 6)
        XCTAssertTrue((0..<6).contains(i))
        XCTAssertEqual(i, StatsUsersAggregate.colorIndex("mario", count: 6))
    }
}
