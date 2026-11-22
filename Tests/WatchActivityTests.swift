import XCTest
@testable import Cove

final class WatchActivityTests: XCTestCase {
    private func u(_ n: String, disabled: Bool = false) -> WatchActivityUser {
        WatchActivityUser(id: n, name: n, imageTag: nil, disabled: disabled)
    }

    private func film(_ n: String, played: Bool = false, pos: Int64 = 0, fav: Bool = false, last: Date? = nil,
                      disabled: Bool = false) -> WatchActivityEntry {
        var e = WatchActivityEntry(user: u(n, disabled: disabled))
        e.played = played; e.positionTicks = pos; e.favorite = fav; e.lastPlayed = last
        e.runtimeTicks = 2 * 3600 * 10_000_000
        return e
    }

    func testThreeOfTen() {
        var list: [WatchActivityEntry] = []
        for i in 0..<10 { list.append(film("u\(i)", played: i < 3)) }
        let s = WatchActivity.summary(list, folder: false)
        XCTAssertEqual(s.watched, 3)
        XCTAssertEqual(s.total, 10)
        XCTAssertEqual(s.text, "3/10 watched")
    }

    func testDisabledUsersAreNotCounted() {
        let list = [film("a", played: true), film("b"), film("c", played: true, disabled: true)]
        XCTAssertEqual(WatchActivity.summary(list, folder: false).text, "1/2 watched")
        XCTAssertEqual(WatchActivity.sorted(list, folder: false).last?.user.name, "c")   // dimmed at the end
    }

    func testProgressText() {
        // 2 h film, 47:56 watched → 1:12:04 left
        let pos = Int64((47 * 60 + 56)) * 10_000_000
        let st = WatchActivity.state(film("a", pos: pos), folder: false)
        guard case .progress(let f, let left) = st else { return XCTFail("\(st)") }
        XCTAssertEqual(f, 0.3994, accuracy: 0.001)
        XCTAssertEqual(left, "1:12:04 left")
        XCTAssertEqual(WatchActivity.stateText(st), "39% · 1:12:04 left")
        XCTAssertEqual(WatchActivity.stateText(.watched), "Watched")
        XCTAssertEqual(WatchActivity.state(film("b"), folder: false), .notStarted)
        XCTAssertEqual(WatchActivity.clock(724), "12:04")
    }

    func testFavouritesAndLastPlayed() {
        let d1 = Date(timeIntervalSince1970: 1_000), d2 = Date(timeIntervalSince1970: 5_000)
        let list = [film("a", fav: true, last: d1), film("b", fav: true, last: d2), film("c")]
        let s = WatchActivity.summary(list, folder: false)
        XCTAssertEqual(s.favourites, 2)
        XCTAssertEqual(s.favouritesText, "♥ 2 favourites")
        XCTAssertEqual(s.lastPlayed, d2)
        XCTAssertEqual(s.lastPlayedBy, "b")
        XCTAssertNil(WatchActivity.summary([film("x")], folder: false).favouritesText)
    }

    func testSeriesProgress() {
        var e = WatchActivityEntry(user: u("a"))
        e.recursive = 10; e.unplayed = 6
        guard case .progress(let f, let left) = WatchActivity.state(e, folder: true) else { return XCTFail() }
        XCTAssertEqual(f, 0.4, accuracy: 0.0001)
        XCTAssertEqual(left, "6 left")
        e.unplayed = 0
        XCTAssertEqual(WatchActivity.state(e, folder: true), .watched)
        e.unplayed = 10
        XCTAssertEqual(WatchActivity.state(e, folder: true), .notStarted)
        e.unplayed = 5; e.playedPercentage = 42
        guard case .progress(let g, _) = WatchActivity.state(e, folder: true) else { return XCTFail() }
        XCTAssertEqual(g, 0.42, accuracy: 0.0001)
        XCTAssertTrue(WatchActivity.isFolder("Series"))
        XCTAssertTrue(WatchActivity.isFolder("BoxSet"))
        XCTAssertFalse(WatchActivity.isFolder("Movie"))
    }

    func testAvatarsMaxFivePlusMore() {
        var list: [WatchActivityEntry] = []
        for i in 0..<8 { list.append(film("u\(i)", played: true)) }
        list.append(film("idle"))
        let a = WatchActivity.avatars(list, folder: false)
        XCTAssertEqual(a.shown.count, 5)
        XCTAssertEqual(a.more, 3)
    }

    func testDecode() throws {
        let users = Data(#"[{"Id":"1","Name":"Anna","PrimaryImageTag":"t","Policy":{"IsDisabled":false}},{"Id":"2","Name":"Bob","Policy":{"IsDisabled":true}}]"#.utf8)
        let us = WatchActivity.users(users)
        XCTAssertEqual(us.map(\.name), ["Anna", "Bob"])
        XCTAssertTrue(us[1].disabled)
        let item = Data(#"{"Items":[{"Id":"x","RunTimeTicks":72000000000,"DateCreated":"2026-11-02T10:00:00.0000000Z","UserData":{"Played":false,"PlayCount":3,"PlaybackPositionTicks":36000000000,"IsFavorite":true,"LastPlayedDate":"2026-11-20T08:30:00.1234567Z"}}]}"#.utf8)
        let (e, added) = try XCTUnwrap(WatchActivity.entry(item, user: us[0]))
        XCTAssertEqual(e.playCount, 3)
        XCTAssertTrue(e.favorite)
        XCTAssertNotNil(e.lastPlayed)
        XCTAssertNotNil(added)
        XCTAssertNil(WatchActivity.entry(Data(#"{"Items":[]}"#.utf8), user: us[0]))
        XCTAssertNil(WatchActivity.isoDate("0001-01-01T00:00:00.0000000Z"))
    }

    // MARK: Last active

    func testLastActiveFormatting() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(LastActive.text(nil, now: now), "Last active: Never")
        XCTAssertEqual(LastActive.text(now.addingTimeInterval(-7200), now: now), "Last active 2 h ago")
        XCTAssertEqual(LastActive.ago(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(LastActive.ago(now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(LastActive.ago(now.addingTimeInterval(-3 * 86400), now: now), "3 d ago")
        XCTAssertTrue(LastActive.tooltip(activity: nil, login: nil).contains("Last login: Never"))
    }

    func testSortByLastActive() {
        let now = Date()
        let l: [(String, Date?)] = [("a", nil), ("b", now.addingTimeInterval(-100)), ("c", now), ("d", nil)]
        XCTAssertEqual(LastActive.byLastActive(l, date: { $0.1 }, name: { $0.0 }).map(\.0), ["c", "b", "a", "d"])
    }
}
