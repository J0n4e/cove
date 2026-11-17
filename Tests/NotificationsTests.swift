import XCTest
@testable import Cove

// New-media notifications: dates, baseline/diff, batching texts, filters, storage, the socket message, and the
// service end to end with a stub server and a stub notification center (never the real one).

enum NotifFixtures {
    /// Emby: 7 fraction digits + Z, UserData with PlaybackPositionTicks
    static let emby = """
    {"Items":[
      {"Name":"Pilot 2","Id":"e3","Type":"Episode","SeriesName":"Las Fierbinți","SeriesId":"s1","ParentIndexNumber":18,"IndexNumber":13,"DateCreated":"2026-11-10T12:00:02.0000000Z","UserData":{"PlaybackPositionTicks":0,"Played":false}},
      {"Name":"Pilot","Id":"e2","Type":"Episode","SeriesName":"Las Fierbinți","SeriesId":"s1","ParentIndexNumber":18,"IndexNumber":12,"DateCreated":"2026-11-10T12:00:01.0000000Z","UserData":{"PlaybackPositionTicks":0,"Played":false}},
      {"Name":"Dune","Id":"m1","Type":"Movie","ProductionYear":2021,"DateCreated":"2026-11-09T08:00:00.0000000Z","UserData":{"PlaybackPositionTicks":0,"Played":true}}
    ]}
    """
    /// Jellyfin: shorter fraction, no UserData.Played on some, TotalRecordCount
    static let jellyfin = """
    {"Items":[
      {"Name":"Arrival","ServerId":"x","Id":"j1","Type":"Movie","ProductionYear":2016,"DateCreated":"2026-11-11T09:30:00.123Z","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"1"}},
      {"Name":"Heat","ServerId":"x","Id":"j2","Type":"Movie","ProductionYear":1995,"DateCreated":"2026-11-11T09:00:00Z"}
    ],"TotalRecordCount":2,"StartIndex":0}
    """
    static let libraryChanged = """
    {"MessageType":"LibraryChanged","MessageId":"a1","Data":{"FoldersAddedTo":[],"FoldersRemovedFrom":[],"ItemsAdded":["j9","j10"],"ItemsRemoved":[],"ItemsUpdated":["x"],"CollectionFolders":[],"IsEmpty":false}}
    """
}

final class StubNewMediaSource: NewMediaSource {
    var libs: [NewMediaLibrary]? = [NewMediaLibrary(id: "L1", name: "Movies", kind: "movies"),
                                    NewMediaLibrary(id: "L2", name: "Shows", kind: "tvshows")]
    var latestByLib: [String: [NewMediaItem]] = [:]
    var byId: [String: NewMediaItem] = [:]
    var libOf: [String: String] = [:]
    var followed: Set<String> = []
    var latestCalls = 0
    func libraries() async -> [NewMediaLibrary]? { libs }
    func latest(library: NewMediaLibrary, types: String) async -> [NewMediaItem]? { latestCalls += 1; return latestByLib[library.id] ?? [] }
    func items(ids: [String]) async -> [NewMediaItem] { ids.compactMap { byId[$0] } }
    func libraryOf(itemId: String, among: Set<String>) async -> String? { libOf[itemId].flatMap { among.contains($0) ? $0 : nil } }
    func followedSeries(_ ids: Set<String>) async -> Set<String> { followed.intersection(ids) }
    func posterFile(_ id: String) async -> URL? { nil }
}

final class StubNotifier: NewMediaNotifier {
    var status: NotificationPermission = .allowed
    var grant = true
    var asked = 0
    var posted: [NewMediaNotification] = []
    func permission() async -> NotificationPermission { status }
    func requestPermission() async -> Bool { asked += 1; status = grant ? .allowed : .denied; return grant }
    func post(_ n: NewMediaNotification, poster: URL?) async { posted.append(n) }
}

@MainActor
final class NotificationsTests: XCTestCase {
    private func item(_ id: String, _ type: String = "Movie", date: String, name: String? = nil, series: String? = nil,
                      seriesName: String? = nil, s: Int? = nil, e: Int? = nil, year: Int? = nil, played: Bool = false) -> NewMediaItem {
        NewMediaItem(Id: id, Name: name ?? id, type: type, SeriesId: series, SeriesName: seriesName, ParentIndexNumber: s,
                     IndexNumber: e, ProductionYear: year, DateCreated: date,
                     UserData: .init(Played: played, PlayedPercentage: nil, PlaybackPositionTicks: nil))
    }
    private let t0 = Date(timeIntervalSince1970: 1793836800)  // 2026-11-05
    private let lib = NewMediaLibrary(id: "L1", name: "Movies", kind: "movies")

    private func defaults() -> UserDefaults {
        let name = "cove-notif-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: dates and decoding

    func testParseDates() throws {
        let a = try XCTUnwrap(NewMediaDetector.parseDate("2026-11-10T12:00:01.0000000Z"))
        let b = try XCTUnwrap(NewMediaDetector.parseDate("2026-11-10T12:00:01.5Z"))
        XCTAssertEqual(b.timeIntervalSince(a), 0.5, accuracy: 0.001)
        XCTAssertNotNil(NewMediaDetector.parseDate("2026-11-10T12:00:01Z"))
        XCTAssertNotNil(NewMediaDetector.parseDate("2026-11-10T12:00:01.1234567+00:00"))
        XCTAssertEqual(NewMediaDetector.parseDate("2026-11-10T12:00:01"), NewMediaDetector.parseDate("2026-11-10T12:00:01Z"))
        XCTAssertNil(NewMediaDetector.parseDate("yesterday"))
    }

    func testDecodesEmbyAndJellyfin() throws {
        let e = try JSONDecoder().decode(NewMediaItemList.self, from: Data(NotifFixtures.emby.utf8)).Items
        XCTAssertEqual(e.map(\.Id), ["e3", "e2", "m1"])
        XCTAssertTrue(e[0].isEpisode); XCTAssertEqual(e[0].SeriesName, "Las Fierbinți"); XCTAssertEqual(e[0].IndexNumber, 13)
        XCTAssertTrue(e[2].played); XCTAssertFalse(e[0].played)
        XCTAssertNotNil(e[0].created)
        let j = try JSONDecoder().decode(NewMediaItemList.self, from: Data(NotifFixtures.jellyfin.utf8)).Items
        XCTAssertEqual(j.map(\.Id), ["j1", "j2"])
        XCTAssertNil(j[1].UserData); XCTAssertFalse(j[1].played)
        XCTAssertNotNil(j[0].created); XCTAssertNotNil(j[1].created)
    }

    func testLibraryChangedMessage() throws {
        let m = try XCTUnwrap(SocketEnvelope.decode(NotifFixtures.libraryChanged)).message
        XCTAssertEqual(m, .libraryChanged(["j9", "j10"]))
    }

    // MARK: baseline and diff

    func testFirstRunNotifiesNothing() {
        let items = [item("a", date: "2026-11-10T12:00:00Z"), item("b", date: "2026-11-09T12:00:00Z")]
        let (new, st) = NewMediaDetector.diff(nil, items, now: t0)
        XCTAssertTrue(new.isEmpty)
        XCTAssertEqual(Set(st.seen), ["a", "b"])
        XCTAssertEqual(st.newest, NewMediaDetector.parseDate("2026-11-10T12:00:00Z")!.timeIntervalSince1970)
    }

    func testNewItemsAfterBaseline() {
        let base = NewMediaDetector.baseline([item("a", date: "2026-11-10T12:00:00Z")], now: t0)
        let items = [item("c", date: "2026-11-11T12:00:00Z"),
                     item("p", date: "2026-11-11T11:00:00Z", played: true),       // already watched
                     item("x", "Series", date: "2026-11-11T10:00:00Z"),            // not a movie / episode
                     item("a", date: "2026-11-10T12:00:00Z"),                      // known
                     item("old", date: "2026-01-01T00:00:00Z")]                    // older than the baseline
        let (new, st) = NewMediaDetector.diff(base, items, now: t0.addingTimeInterval(600))
        XCTAssertEqual(new.map(\.Id), ["c"])
        // A second look at the same answer: nothing again (no duplicates)
        XCTAssertTrue(NewMediaDetector.diff(st, items, now: t0.addingTimeInterval(1200)).new.isEmpty)
        XCTAssertEqual(st.newest, NewMediaDetector.parseDate("2026-11-11T12:00:00Z")!.timeIntervalSince1970)
    }

    func testSameSecondAsBaselineButUnseenIsNew() {
        let base = NewMediaDetector.baseline([item("a", date: "2026-11-10T12:00:00Z")], now: t0)
        let (new, _) = NewMediaDetector.diff(base, [item("b", date: "2026-11-10T12:00:00Z"), item("a", date: "2026-11-10T12:00:00Z")], now: t0)
        XCTAssertEqual(new.map(\.Id), ["b"])
    }

    func testStaleStateRebaselines() {
        let base = NewMediaDetector.baseline([item("a", date: "2026-11-10T12:00:00Z")], now: t0)
        let later = t0.addingTimeInterval(NewMediaDetector.staleAfter + 1)
        let (new, st) = NewMediaDetector.diff(base, [item("b", date: "2026-11-20T12:00:00Z")], now: later)
        XCTAssertTrue(new.isEmpty)
        XCTAssertEqual(st.seen, ["b"])
    }

    func testSeenIsBounded() {
        var st = NewMediaDetector.baseline([], now: t0)
        for i in 0..<5 {
            let batch = (0..<100).map { item("i\(i)-\($0)", date: "2026-11-10T12:00:00Z") }
            st = NewMediaDetector.remember(batch, in: st, now: t0)
        }
        XCTAssertEqual(st.seen.count, NewMediaDetector.maxSeen)
        XCTAssertTrue(st.seen.contains("i4-0")); XCTAssertFalse(st.seen.contains("i0-0"))
    }

    func testFilterFollowedAndKinds() {
        let m = item("m", date: "2026-11-10T12:00:00Z")
        let e1 = item("e1", "Episode", date: "2026-11-10T12:00:00Z", series: "s1")
        let e2 = item("e2", "Episode", date: "2026-11-10T12:00:00Z", series: "s2")
        var p = NewMediaPrefs()
        XCTAssertEqual(NewMediaDetector.filter([m, e1, e2], prefs: p, followed: []).map(\.Id), ["m", "e1", "e2"])
        p.onlyFollowed = true
        XCTAssertEqual(NewMediaDetector.filter([m, e1, e2], prefs: p, followed: ["s2"]).map(\.Id), ["m", "e2"])
        p.movies = false
        XCTAssertEqual(NewMediaDetector.filter([m, e1, e2], prefs: p, followed: ["s2"]).map(\.Id), ["e2"])
        p.episodes = false
        XCTAssertTrue(NewMediaDetector.filter([m, e1, e2], prefs: p, followed: ["s2"]).isEmpty)
        XCTAssertTrue(NewMediaFollow.follows(favorite: true, played: nil, playedPercentage: nil, playedEpisodes: nil))
        XCTAssertTrue(NewMediaFollow.follows(favorite: nil, played: nil, playedPercentage: 3, playedEpisodes: nil))
        XCTAssertTrue(NewMediaFollow.follows(favorite: false, played: false, playedPercentage: 0, playedEpisodes: 1))
        XCTAssertFalse(NewMediaFollow.follows(favorite: false, played: false, playedPercentage: 0, playedEpisodes: 0))
    }

    func testLibraryTypes() {
        var p = NewMediaPrefs()
        XCTAssertEqual(NewMediaLibrary(id: "a", name: "", kind: "movies").includeTypes(p), "Movie")
        XCTAssertEqual(NewMediaLibrary(id: "a", name: "", kind: "tvshows").includeTypes(p), "Episode")
        XCTAssertEqual(NewMediaLibrary(id: "a", name: "", kind: nil).includeTypes(p), "Movie,Episode")
        p.movies = false
        XCTAssertNil(NewMediaLibrary(id: "a", name: "", kind: "movies").includeTypes(p))
        XCTAssertTrue(NewMediaLibrary.eligible(kind: "tvshows"))
        XCTAssertFalse(NewMediaLibrary.eligible(kind: "music"))
    }

    // MARK: texts and batching

    func testSingleTexts() {
        let m = item("m", date: "2026-11-10T12:00:00Z", name: "Dune", year: 2021)
        let e = item("e", "Episode", date: "2026-11-10T12:00:00Z", name: "Nunta", series: "s1", seriesName: "Las Fierbinți", s: 18, e: 12)
        XCTAssertEqual(NewMediaDetector.line(m), "Dune (2021)")
        XCTAssertEqual(NewMediaDetector.line(e), "Las Fierbinți — S18:E12 · Nunta")
        let nm = NewMediaDetector.batches([m], library: lib, server: "https://a", userId: "u")
        XCTAssertEqual(nm.count, 1)
        XCTAssertEqual(nm[0].title, "New movie"); XCTAssertEqual(nm[0].body, "Dune (2021)")
        XCTAssertEqual(nm[0].target, .item("m")); XCTAssertEqual(nm[0].thread, "cove-movies"); XCTAssertEqual(nm[0].posterId, "m")
        let ne = NewMediaDetector.batches([e], library: lib, server: "https://a", userId: "u")
        XCTAssertEqual(ne[0].title, "New episode"); XCTAssertEqual(ne[0].target, .item("e"))
        XCTAssertEqual(ne[0].thread, "cove-series-s1"); XCTAssertEqual(ne[0].posterId, "s1")
    }

    func testBatchedTexts() {
        let eps = (12...14).map { (n: Int) in item("e\(n)", "Episode", date: "2026-11-10T12:00:00Z", series: "s1", seriesName: "Las Fierbinți", s: 18, e: n) }
        let movies = ["A", "B", "C", "D", "E"].map { item($0, date: "2026-11-10T12:00:00Z") }
        let n = NewMediaDetector.batches(movies + eps, library: lib, server: "https://a", userId: "u")
        XCTAssertEqual(n.count, 2)
        XCTAssertEqual(n[0].title, "New movies"); XCTAssertEqual(n[0].body, "5 new movies: A, B, C…"); XCTAssertEqual(n[0].target, .library("L1"))
        XCTAssertEqual(n[1].title, "New episodes"); XCTAssertEqual(n[1].body, "3 new episodes of Las Fierbinți")
        XCTAssertEqual(n[1].target, .series("s1")); XCTAssertEqual(n[1].thread, "cove-series-s1")
    }

    func testManyShowsBecomeOneLibraryNotification() {
        let eps = (1...5).map { (n: Int) in item("e\(n)", "Episode", date: "2026-11-10T12:00:00Z", series: "s\(n)", seriesName: "Show \(n)") }
        let n = NewMediaDetector.batches(eps, library: lib, server: "https://a", userId: "u")
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].body, "5 new episodes: Show 1, Show 2, Show 3…")
        XCTAssertEqual(n[0].target, .library("L1"))
    }

    func testUserInfo() {
        let n = NewMediaDetector.batches([item("m", date: "2026-11-10T12:00:00Z")], library: lib, server: "https://a", userId: "u")[0]
        XCTAssertEqual(NewMediaService.userInfo(n), ["server": "https://a", "userId": "u", "libraryId": "L1", "kind": "item", "id": "m"])
    }

    // MARK: storage

    func testStorePerServerAndRemove() {
        let d = defaults()
        let s = NewMediaStore(defaults: d)
        let st = NewMediaDetector.baseline([item("a", date: "2026-11-10T12:00:00Z")], now: t0)
        s.set(st, for: NewMediaDetector.stateKey(server: "https://A", userId: "u", library: "L1"))
        s.set(st, for: NewMediaDetector.stateKey(server: "https://b", userId: "u", library: "L1"))
        XCTAssertEqual(s.get("https://a|u|L1"), st)
        s.removeServer("https://a")
        XCTAssertNil(s.get("https://a|u|L1"))
        XCTAssertNotNil(s.get("https://b|u|L1"))
        XCTAssertTrue(InternalPrefs.contains(NewMediaStore.key))
    }

    // MARK: the service, end to end with stubs

    private func makeService(_ src: StubNewMediaSource, _ n: StubNotifier, _ d: UserDefaults,
                             prefs: @escaping () -> NewMediaPrefs = { NewMediaPrefs() }, clock: @escaping () -> Date) -> NewMediaService {
        NewMediaService(enabled: false, notifier: n, makeSource: { _ in src }, defaults: d, prefs: prefs, now: clock,
                        sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }, log: { _ in })
    }
    private func session(_ s: String) -> NewMediaSession { NewMediaSession(server: s, userId: "u", token: "t", authHeader: "MediaBrowser") }

    func testServiceBaselineThenBatchedThenNoDuplicates() async {
        let src = StubNewMediaSource(), n = StubNotifier(), d = defaults()
        var now = t0
        let svc = makeService(src, n, d, clock: { now })
        src.latestByLib["L1"] = [item("old", date: "2026-11-01T00:00:00Z")]
        src.latestByLib["L2"] = [item("e0", "Episode", date: "2026-11-01T00:00:00Z", series: "s1", seriesName: "Las Fierbinți")]
        svc.update(session("https://a"))   // enabled: false, so no timer: check() is driven here
        await svc.check()
        XCTAssertTrue(n.posted.isEmpty, "first run notifies nothing")

        now = now.addingTimeInterval(600)
        src.latestByLib["L2"] = (1...3).map { (i: Int) in item("e\(i)", "Episode", date: "2026-11-12T00:00:0\(i)Z", series: "s1", seriesName: "Las Fierbinți", s: 1, e: i) }
            + src.latestByLib["L2"]!
        src.latestByLib["L1"] = [item("new", date: "2026-11-12T00:00:00Z", name: "Dune", year: 2021),
                                 item("seen", date: "2026-11-12T00:00:00Z", played: true)] + src.latestByLib["L1"]!
        await svc.check()
        XCTAssertEqual(n.posted.map(\.body).sorted(), ["3 new episodes of Las Fierbinți", "Dune (2021)"])
        XCTAssertTrue(n.posted.allSatisfy { $0.server == "https://a" })

        now = now.addingTimeInterval(600)
        await svc.check()
        XCTAssertEqual(n.posted.count, 2, "no duplicates")
    }

    func testServiceLibrariesOffAndOnlyFollowed() async {
        let src = StubNewMediaSource(), n = StubNotifier(), d = defaults()
        var now = t0
        var prefs = NewMediaPrefs()
        prefs.libsOff = ["L1"]; prefs.onlyFollowed = true
        let svc = makeService(src, n, d, prefs: { prefs }, clock: { now })
        svc.update(session("https://a"))
        await svc.check()
        now = now.addingTimeInterval(600)
        src.latestByLib["L1"] = [item("m", date: "2026-11-12T00:00:00Z")]
        src.latestByLib["L2"] = [item("e1", "Episode", date: "2026-11-12T00:00:00Z", series: "s1", seriesName: "A"),
                                 item("e2", "Episode", date: "2026-11-12T00:00:00Z", series: "s2", seriesName: "B")]
        src.followed = ["s2"]
        await svc.check()
        XCTAssertEqual(n.posted.map(\.target), [.item("e2")])
    }

    func testServerSwitchDoesNotBurst() async {
        let src = StubNewMediaSource(), n = StubNotifier(), d = defaults()
        var now = t0
        let svc = makeService(src, n, d, clock: { now })
        src.latestByLib["L1"] = [item("a", date: "2026-11-12T00:00:00Z")]
        svc.update(session("https://a"))
        await svc.check()
        // Another server with lots of items: its first look is a baseline too
        src.latestByLib["L1"] = (0..<20).map { item("b\($0)", date: "2026-11-12T00:00:00Z") }
        now = now.addingTimeInterval(60)
        svc.update(session("https://b"))
        await svc.check()
        XCTAssertTrue(n.posted.isEmpty)
        XCTAssertNotNil(NewMediaStore(defaults: d).get("https://a|u|L1"))
        XCTAssertNotNil(NewMediaStore(defaults: d).get("https://b|u|L1"))
    }

    func testSocketItemsOutsideTheNewestAreLookedUp() async {
        let src = StubNewMediaSource(), n = StubNotifier(), d = defaults()
        var now = t0
        let svc = makeService(src, n, d, clock: { now })
        src.latestByLib["L1"] = [item("a", date: "2026-11-12T00:00:00Z")]
        svc.update(session("https://a"))
        await svc.check()
        now = now.addingTimeInterval(60)
        // An old file copied in: Jellyfin dates it by the file, so it isn't among the newest
        src.byId["j9"] = item("j9", date: "2019-01-01T00:00:00Z", name: "Heat", year: 1995)
        src.libOf["j9"] = "L1"
        svc.itemsAdded(["j9"])
        await svc.flushSocket()
        XCTAssertEqual(n.posted.map(\.body), ["Heat (1995)"])
        // The same id again (e.g. the next message): not announced twice
        svc.itemsAdded(["j9"])
        await svc.flushSocket()
        XCTAssertEqual(n.posted.count, 1)
    }

    func testPermissionAskedOnceAndDenied() async {
        let src = StubNewMediaSource(), n = StubNotifier(), d = defaults()
        n.status = .notDetermined; n.grant = false
        let svc = makeService(src, n, d, clock: { Date() })
        let p = await svc.ensurePermission()
        XCTAssertEqual(p, .denied); XCTAssertEqual(svc.permission, .denied); XCTAssertEqual(n.asked, 1)
        _ = await svc.ensurePermission()
        XCTAssertEqual(n.asked, 1, "asked only once")
        await svc.sendTest()
        XCTAssertTrue(n.posted.isEmpty)
        n.status = .allowed
        await svc.sendTest()
        XCTAssertEqual(n.posted.first?.target, .test)
    }

    func testServerRequestKeepsTokenOutOfTheLink() throws {
        let s = ServerNewMediaSource(session: NewMediaSession(server: "https://srv", userId: "u", token: "SECRET", authHeader: "MediaBrowser Client=\"Cove\""))
        let r = try XCTUnwrap(s.request("/Users/u/Items", ["ParentId": "L1", "SortBy": "DateCreated"]))
        XCTAssertFalse(r.url!.absoluteString.contains("SECRET"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Emby-Token"), "SECRET")
        XCTAssertTrue(r.url!.absoluteString.contains("ParentId=L1"))
    }
}
