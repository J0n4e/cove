import XCTest
@testable import Cove

/// Live updates: resume state right after a stop, admin edits reaching every list, banner clicks marking cards read.
@MainActor
final class LiveRefreshTests: XCTestCase {
    private func item(_ id: String, name: String? = nil, tag: String? = nil, runtime: Int64? = nil, pct: Double? = nil) -> Item {
        var o: [String: Any] = ["Id": id, "Name": name ?? "n\(id)", "Type": "Movie"]
        if let tag { o["ImageTags"] = ["Primary": tag] }
        if let runtime { o["RunTimeTicks"] = runtime }
        if let pct { o["UserData"] = ["PlayedPercentage": pct] }
        let d = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(Item.self, from: d)
    }

    override func setUp() async throws { LiveRefresh.afterStopDelay = 0 }
    override func tearDown() async throws { LiveRefresh.afterStopDelay = 1.5 }

    // MARK: Resume after stop

    func testProgressFractionPrefersSessionPosition() {
        // 60 min film, stopped at 30 min: half way, whatever the stale UserData says
        XCTAssertEqual(Emby.progressFraction(position: 1800, runtimeTicks: 36_000_000_000, playedPercentage: nil), 0.5, accuracy: 0.001)
        XCTAssertEqual(Emby.progressFraction(position: 1800, runtimeTicks: 36_000_000_000, playedPercentage: 10), 0.5, accuracy: 0.001)
        // Finished / marked watched in the app: no progress line
        XCTAssertEqual(Emby.progressFraction(position: 0, runtimeTicks: 36_000_000_000, playedPercentage: 40), 0)
        // Nothing this session: the server's value
        XCTAssertEqual(Emby.progressFraction(position: nil, runtimeTicks: nil, playedPercentage: 25), 0.25, accuracy: 0.001)
        // No percentage from the server but a saved position (2 min of 45): progress from the position (owner)
        XCTAssertEqual(Emby.progressFraction(position: nil, runtimeTicks: 27_000_000_000, playedPercentage: nil,
                                             serverPositionTicks: 1_200_000_000), 1_200_000_000.0 / 27_000_000_000.0, accuracy: 0.0001)
        XCTAssertEqual(Emby.progressFraction(position: nil, runtimeTicks: 27_000_000_000, playedPercentage: 0,
                                             serverPositionTicks: 0), 0)
    }

    func testPositionDrivesResumeAndProgress() {
        let e = Emby()
        let m = item("m1", runtime: 36_000_000_000)
        XCTAssertEqual(e.resumeAt(m), 0)
        e.positions["m1"] = 1200
        XCTAssertEqual(e.resumeAt(m), 1200)
        XCTAssertEqual(e.progressFraction(m), 1200.0 / 3600, accuracy: 0.001)
        XCTAssertEqual(e.positionTicks(m), 12_000_000_000)
    }

    func testStopReportUpdatesPositionPlayedAndNotifies() async {
        let e = Emby()
        e.server = "http://127.0.0.1:9"; e.token = "t"; e.userId = "u"
        let ps = Emby.PlaySession(itemId: "m1", sourceId: nil, method: "DirectPlay",
                                  url: URL(string: "http://127.0.0.1:9/v")!, server: e.server, token: "t")
        let got = expectation(forNotification: .covePlaybackStopped, object: nil) { n in
            (n.userInfo?["id"] as? String) == "m1" && (n.userInfo?["finished"] as? Bool) == false
        }
        await e.reportStopped(ps, 1500, duration: 3600, quick: true)
        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(e.positions["m1"], 1500)
        XCTAssertEqual(e.resumeAt(item("m1")), 1500)
        await e.reportStopped(ps, 3500, duration: 3600, quick: true)
        XCTAssertEqual(e.positions["m1"], 0, "past 90%: no resume point")
        XCTAssertTrue(e.isPlayed(item("m1")), "past 90%: watched, as the server does")
    }

    func testContinueWatchingMovesStoppedItemFirst() {
        let rows = [Row(title: "Continue Watching", items: [item("a"), item("b"), item("c")], feed: .resume)]
        XCTAssertEqual(LiveRefresh.movingToFront("c", in: rows)?[0].items.map(\.id), ["c", "a", "b"])
        XCTAssertNil(LiveRefresh.movingToFront("a", in: rows), "already first")
        XCTAssertNil(LiveRefresh.movingToFront("zz", in: rows))
    }

    func testHomeReloadsRowsAfterStop() async throws {
        final class Box { var calls = 0 }
        let box = Box()
        let m = HomeModel(prefetchRows: false, load: {
            box.calls += 1
            return [Row(title: "Continue Watching", items: box.calls > 1 ? [self.item("new"), self.item("a")] : [self.item("a")], feed: .resume)]
        }, heroLoad: { _ in nil }, source: { .rows })
        await m.load()
        XCTAssertEqual(box.calls, 1)
        NotificationCenter.default.post(name: .covePlaybackStopped, object: nil, userInfo: ["id": "new", "finished": false])
        for _ in 0..<100 where m.stopReloads == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(m.stopReloads, 1)
        XCTAssertEqual(m.rows.first?.items.first?.id, "new")
    }

    // MARK: Admin edits

    func testReplacingOnlyChangedIds() {
        let list = [item("a"), item("b")]
        XCTAssertNil(LiveRefresh.replacing(list, with: ["zz": item("zz")]))
        let n = LiveRefresh.replacing(list, with: ["b": item("b", name: "New name")])
        XCTAssertEqual(n?.map(\.Name), ["na", "New name"])
    }

    func testAdminChangeReplacesRowItemAndPictureLink() async {
        let e = Emby()
        e.server = "https://h"
        let old = item("p1", tag: "old1")
        Emby.remember([old])
        XCTAssertTrue(e.image("p1")?.absoluteString.hasSuffix("tag=old1") ?? false)
        let m = HomeModel(prefetchRows: false, load: { [Row(title: "Movies", items: [old], libId: "L")] },
                          heroLoad: { _ in nil }, source: { .rows })
        await m.load()
        let fresh = item("p1", name: "Renamed", tag: "new2")
        Emby.remember([fresh])                   // what Emby.get does with the re-read item
        ItemAdminChanges.shared.bump("p1", item: fresh)
        XCTAssertEqual(m.rows[0].items[0].Name, "Renamed")
        XCTAssertEqual(m.rows[0].items[0].ImageTags?["Primary"], "new2")
        XCTAssertTrue(e.image(m.rows[0].items[0].posterId)?.absoluteString.hasSuffix("tag=new2") ?? false,
                      "new tag, new link: the old cached picture is never shown again")
    }

    func testAdminChangeReachesLibraryFavoritesSearchPerson() {
        let lib = LibraryModel(lib: LibPref(id: "lr-test", name: "M", title: "M", kind: "movies"), defaults: UserDefaults(suiteName: "lr-\(UUID())")!)
        lib.items = [item("x"), item("y")]
        let fav = FavoritesModel()
        ItemAdminChanges.shared.bump("y", item: item("y", name: "Y2"))
        XCTAssertEqual(lib.items.map(\.Name), ["nx", "Y2"])
        XCTAssertTrue(fav.items.isEmpty, "nothing to replace")
        ItemAdminChanges.shared.bump("y")         // no fresh copy: nothing swapped, no crash
        XCTAssertEqual(lib.items[1].Name, "Y2")
    }

    // MARK: Banner click → read

    private func note(_ key: String, title: String = "New movie") -> NewMediaNotification {
        NewMediaNotification(id: "https://a|u|L1|\(key)", title: title, body: "b", thread: "cove-movies", target: .item(key),
                             images: [], server: "https://a", userId: "u", libraryId: "L1", playId: key)
    }

    func testBannerMatchesItsStoredCard() {
        let t0 = Date(timeIntervalSince1970: 1_793_836_800)
        let a = StoredNotification(note("a"), date: t0, target: NewMediaService.userInfo(note("a")))
        let b = StoredNotification(note("b"), date: t0.addingTimeInterval(60), target: NewMediaService.userInfo(note("b")))
        let list = [b, a]
        XCTAssertEqual(NotificationInbox.matching(NewMediaService.userInfo(note("a")), title: "New movie", in: list), a.id)
        XCTAssertEqual(NotificationInbox.matching(NewMediaService.userInfo(note("b")), title: nil, in: list), b.id)
        XCTAssertNil(NotificationInbox.matching(NewMediaService.userInfo(note("zz")), title: "New movie", in: list))
    }

    func testBannerClickMarksCardRead() async {
        let store = NotificationCenterStore(file: nil)
        let svc = NewMediaService(enabled: false, inbox: store)
        let s = store.add(note("a"), presentation: .banner)
        store.add(note("b"), presentation: .banner)
        XCTAssertEqual(store.unread, 2)
        await svc.bannerClicked(NewMediaService.userInfo(note("a")), title: "New movie")
        XCTAssertEqual(store.unread, 1)
        XCTAssertTrue(store.items.first { $0.id == s.id }?.read ?? false)
    }
}
