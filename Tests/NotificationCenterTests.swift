import XCTest
@testable import Cove

/// In-app notifications (Activity → Notifications, the toast): the list model, its file, the toast-vs-banner choice
/// and the service storing what it announces.
@MainActor
final class NotificationCenterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1793836800)   // 2026-11-05 00:00 UTC
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func note(_ key: String, title: String = "New movie", body: String = "Dune (2021)") -> NewMediaNotification {
        NewMediaNotification(id: "https://a|u|L1|\(key)", title: title, body: body, thread: "cove-movies", target: .item(key),
                             images: NewMediaImage.movie(key), server: "https://a", userId: "u", libraryId: "L1",
                             cardTitle: "Dune", cardDetail: "New movie · 2021", playId: key)
    }
    private func stored(_ key: String, at d: Date, read: Bool = false) -> StoredNotification {
        StoredNotification(note(key), date: d, target: NewMediaService.userInfo(note(key)), read: read)
    }
    private func item(_ id: String, _ type: String = "Movie", date: String, name: String? = nil, series: String? = nil,
                      seriesName: String? = nil, s: Int? = nil, e: Int? = nil, year: Int? = nil) -> NewMediaItem {
        NewMediaItem(Id: id, Name: name ?? id, type: type, SeriesId: series, SeriesName: seriesName, ParentIndexNumber: s,
                     IndexNumber: e, ProductionYear: year, DateCreated: date, UserData: nil)
    }

    // MARK: Store

    func testAddNewestFirstAndKeepsFields() {
        var list: [StoredNotification] = []
        list = NotificationInbox.adding(stored("a", at: t0), to: list, now: t0)
        list = NotificationInbox.adding(stored("b", at: t0.addingTimeInterval(60)), to: list, now: t0.addingTimeInterval(60))
        XCTAssertEqual(list.map(\.playId), ["b", "a"])
        XCTAssertEqual(list[0].cardTitle, "Dune")
        XCTAssertEqual(list[0].cardDetail, "New movie · 2021")
        XCTAssertEqual(list[0].images.map(\.kind), ["Backdrop", "Primary"], "same order as the banner")
        XCTAssertEqual(list[0].target["kind"], "item")
        XCTAssertFalse(list[0].read)
    }

    func testLimitKeepsNewest100() {
        var list: [StoredNotification] = []
        for i in 0..<130 { list = NotificationInbox.adding(stored("m\(i)", at: t0.addingTimeInterval(Double(i))), to: list, now: t0.addingTimeInterval(200)) }
        XCTAssertEqual(list.count, 100)
        XCTAssertEqual(list.first?.playId, "m129")
        XCTAssertEqual(list.last?.playId, "m30")
    }

    func testPrunesOlderThan30Days() {
        let list = [stored("old", at: t0.addingTimeInterval(-31 * 86400)), stored("ok", at: t0.addingTimeInterval(-29 * 86400))]
        XCTAssertEqual(NotificationInbox.pruned(list, now: t0).map(\.playId), ["ok"])
    }

    func testMarkReadUnreadCountRemoveClear() {
        var list = [stored("a", at: t0), stored("b", at: t0), stored("c", at: t0, read: true)]
        XCTAssertEqual(NotificationInbox.unreadCount(list), 2)
        list = NotificationInbox.markRead(list[0].id, in: list)
        XCTAssertEqual(NotificationInbox.unreadCount(list), 1)
        list = NotificationInbox.markAllRead(list)
        XCTAssertEqual(NotificationInbox.unreadCount(list), 0)
        list = NotificationInbox.removing(list[1].id, from: list)
        XCTAssertEqual(list.map(\.playId), ["a", "c"])
    }

    func testGroupingTodayYesterdayEarlier() {
        let now = t0.addingTimeInterval(15 * 3600)   // 15:00
        let list = [stored("y", at: t0.addingTimeInterval(-3600)),          // yesterday 23:00
                    stored("t", at: t0.addingTimeInterval(3600)),           // today 01:00
                    stored("e", at: t0.addingTimeInterval(-3 * 86400)),     // earlier
                    stored("t2", at: t0.addingTimeInterval(14 * 3600))]     // today 14:00
        let g = NotificationInbox.grouped(list, now: now, calendar: utc)
        XCTAssertEqual(g.map(\.section), [.today, .yesterday, .earlier])
        XCTAssertEqual(g[0].items.map(\.playId), ["t2", "t"])
        XCTAssertEqual(g[1].items.map(\.playId), ["y"])
        XCTAssertEqual(g[2].items.map(\.playId), ["e"])
        XCTAssertEqual(NotificationInbox.grouped([], now: now).count, 0)
    }

    func testRelativeTime() {
        XCTAssertEqual(NotificationInbox.relativeTime(t0, now: t0.addingTimeInterval(20)), "Just now")
        XCTAssertEqual(NotificationInbox.relativeTime(t0, now: t0.addingTimeInterval(5 * 60)), "5 min ago")
        XCTAssertEqual(NotificationInbox.relativeTime(t0, now: t0.addingTimeInterval(2 * 3600 + 5)), "2 h ago")
        XCTAssertEqual(NotificationInbox.relativeTime(t0, now: t0.addingTimeInterval(3 * 86400)), "3 d ago")
    }

    func testImageURLWithoutEnhancers() {
        let u = NotificationInbox.imageURL(server: "https://a", StoredNotificationImage(id: "s1", kind: "Backdrop"))
        XCTAssertEqual(u?.absoluteString, "https://a/Items/s1/Images/Backdrop?maxWidth=480&quality=80&EnableImageEnhancers=false")
    }

    func testFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notifications.json")
        let a = NotificationCenterStore(file: file, now: { self.t0 })
        let s = a.add(note("x"), presentation: .banner)
        XCTAssertEqual(a.unread, 1)
        XCTAssertNil(a.toast)
        a.markRead(s.id)
        // the write runs on a background queue
        let exp = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 3)
        let b = NotificationCenterStore(file: file, now: { self.t0 })
        XCTAssertEqual(b.items.map(\.id), [s.id])
        XCTAssertTrue(b.items[0].read)
    }

    func testToastSetOnlyForToastPresentation() {
        let st = NotificationCenterStore(file: nil, now: { self.t0 })
        st.add(note("a"), presentation: .listOnly)
        XCTAssertNil(st.toast)
        let s = st.add(note("b"), presentation: .toast)
        XCTAssertEqual(st.toast?.id, s.id)
        st.remove(s.id)
        XCTAssertNil(st.toast)
        st.requestShowList()
        XCTAssertTrue(st.showListPending)
        XCTAssertEqual(st.showListTick, 1)
    }

    // MARK: Toast or banner

    func testPresentationDecision() {
        XCTAssertEqual(NotificationPresentation.decide(frontmost: true, playing: false, glass3D: true), .toast)
        XCTAssertEqual(NotificationPresentation.decide(frontmost: false, playing: false, glass3D: true), .banner)
        XCTAssertEqual(NotificationPresentation.decide(frontmost: false, playing: true, glass3D: true), .banner)
        XCTAssertEqual(NotificationPresentation.decide(frontmost: true, playing: true, glass3D: true), .listOnly)
        XCTAssertEqual(NotificationPresentation.decide(frontmost: true, playing: false, glass3D: false), .banner, "Glass theme keeps the banner")
    }

    // MARK: Activity tabs

    func testActivityTabs() {
        XCTAssertEqual(ActivityTabs.titles(unread: 0, stats: false), ["Now Playing", "Notifications", "Overview", "History"])
        XCTAssertEqual(ActivityTabs.titles(unread: 3, stats: true),
                       ["Now Playing", "Notifications 3", "Overview", "History", "Users", "Graphs", "Libraries"])
        XCTAssertEqual(ActivityTabs.notifications, 1)
    }

    // MARK: Card text from the batches

    func testCardTextAndPlayTarget() {
        let lib = NewMediaLibrary(id: "L2", name: "TV", kind: "tvshows")
        let one = NewMediaDetector.batches([item("e10", "Episode", date: "2026-11-12T00:00:00Z", name: "The Queen is Dead",
                                                 series: "s1", seriesName: "Show", s: 2, e: 10)],
                                           library: lib, server: "https://a", userId: "u")
        XCTAssertEqual(one[0].cardTitle, "Show")
        XCTAssertEqual(one[0].cardDetail, "S2:E10 · The Queen is Dead")
        XCTAssertEqual(one[0].playId, "e10")
        let eps = [6, 4, 5].map { (i: Int) in item("e\(i)", "Episode", date: "2026-11-12T00:00:00Z", series: "s1", seriesName: "Show", s: 2, e: i) }
        let batch = NewMediaDetector.batches(eps, library: lib, server: "https://a", userId: "u")
        XCTAssertEqual(batch[0].cardDetail, "3 new episodes · S2:E4–E6")
        XCTAssertEqual(batch[0].playId, "e4", "a batch plays its first new episode")
        let movie = NewMediaDetector.batches([item("m1", date: "2026-11-12T00:00:00Z", name: "Dune", year: 2021)],
                                             library: NewMediaLibrary(id: "L1", name: "Movies", kind: "movies"), server: "https://a", userId: "u")
        XCTAssertEqual(movie[0].cardTitle, "Dune")
        XCTAssertEqual(movie[0].cardDetail, "New movie · 2021")
        XCTAssertEqual(movie[0].playId, "m1")
    }

    // MARK: The service stores and picks toast / banner

    private func runService(_ how: NotificationPresentation) async -> (StubNotifier, NotificationCenterStore) {
        let src = StubNewMediaSource(), n = StubNotifier()
        let d = UserDefaults(suiteName: "nc-\(UUID().uuidString)")!
        let inbox = NotificationCenterStore(file: nil)
        var now = t0
        let svc = NewMediaService(enabled: false, notifier: n, makeSource: { _ in src }, defaults: d, prefs: { NewMediaPrefs() },
                                  now: { now }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }, log: { _ in },
                                  inbox: inbox, presentation: { how })
        src.latestByLib["L1"] = [item("old", date: "2026-11-01T00:00:00Z")]
        svc.update(NewMediaSession(server: "https://a", userId: "u", token: "t", authHeader: "MediaBrowser"))
        await svc.check()
        now = now.addingTimeInterval(600)
        src.latestByLib["L1"] = [item("new", date: "2026-11-12T00:00:00Z", name: "Dune", year: 2021)] + src.latestByLib["L1"]!
        await svc.check()
        return (n, inbox)
    }

    func testServiceBackgroundPostsBannerAndStores() async {
        let (n, inbox) = await runService(.banner)
        XCTAssertEqual(n.posted.count, 1)
        XCTAssertEqual(inbox.items.map(\.cardTitle), ["Dune"])
        XCTAssertNil(inbox.toast)
    }

    func testServiceFrontmostShowsToastNoBanner() async {
        let (n, inbox) = await runService(.toast)
        XCTAssertTrue(n.posted.isEmpty, "no macOS banner while Cove is in front")
        XCTAssertEqual(inbox.items.count, 1)
        XCTAssertEqual(inbox.toast?.cardTitle, "Dune")
    }

    func testServicePlayingListOnly() async {
        let (n, inbox) = await runService(.listOnly)
        XCTAssertTrue(n.posted.isEmpty)
        XCTAssertNil(inbox.toast)
        XCTAssertEqual(inbox.unread, 1)
    }
}
