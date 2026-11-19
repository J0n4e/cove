import XCTest
@testable import Cove

// 1.18.10 notifications polish: batching texts, the per-library filter, pictures and the click's userInfo.
@MainActor
final class NotificationsPolishTests: XCTestCase {
    private let lib = NewMediaLibrary(id: "L2", name: "Shows", kind: "tvshows")
    private let movieLib = NewMediaLibrary(id: "L1", name: "Movies", kind: "movies")

    private func ep(_ id: String, _ series: String, _ name: String, s: Int?, e: Int?) -> NewMediaItem {
        NewMediaItem(Id: id, Name: id, type: "Episode", SeriesId: series, SeriesName: name, ParentIndexNumber: s,
                     IndexNumber: e, DateCreated: "2026-11-10T12:00:00Z")
    }
    private func movie(_ id: String) -> NewMediaItem {
        NewMediaItem(Id: id, Name: id, type: "Movie", DateCreated: "2026-11-10T12:00:00Z")
    }
    private func batches(_ items: [NewMediaItem], _ l: NewMediaLibrary? = nil) -> [NewMediaNotification] {
        NewMediaDetector.batches(items, library: l ?? lib, server: "https://a", userId: "u")
    }

    // MARK: batching

    func testOneSeriesThreeEpisodesIsOneBanner() {
        let n = batches([ep("e6", "s", "Severance", s: 2, e: 6), ep("e4", "s", "Severance", s: 2, e: 4), ep("e5", "s", "Severance", s: 2, e: 5)])
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].title, "Severance")
        XCTAssertEqual(n[0].body, "3 new episodes · S2:E4–E6")
        XCTAssertEqual(n[0].thread, "s")
        XCTAssertEqual(n[0].target, .series("s"))
        XCTAssertEqual(n[0].images.first, NewMediaImage(id: "s", kind: "Backdrop"))
        XCTAssertTrue(n[0].images.allSatisfy { $0.id == "s" })
    }

    func testMixedSeries() {
        let n = batches([ep("a1", "A", "Alpha", s: 1, e: 1), ep("b1", "B", "Beta", s: 3, e: 2), ep("a2", "A", "Alpha", s: 1, e: 2)])
        XCTAssertEqual(n.count, 2)
        XCTAssertEqual(n[0].title, "Alpha"); XCTAssertEqual(n[0].body, "2 new episodes · S1:E1–E2"); XCTAssertEqual(n[0].thread, "A")
        XCTAssertEqual(n[1].title, "New episode"); XCTAssertEqual(n[1].target, .episode("b1", series: "B", season: 3))
        XCTAssertEqual(n[1].thread, "B")
        // A single episode: the show's backdrop first (no art-plugin TV frame), then its own still
        XCTAssertEqual(n[1].images.first, NewMediaImage(id: "B", kind: "Backdrop"))
        XCTAssertEqual(n[1].images.dropFirst().first, NewMediaImage(id: "b1", kind: "Primary"))
    }

    func testNonConsecutiveEpisodes() {
        XCTAssertEqual(NewMediaDetector.episodeSpan([ep("1", "s", "X", s: 2, e: 4), ep("2", "s", "X", s: 2, e: 6)]), "S2:E4, E6")
        XCTAssertEqual(NewMediaDetector.episodeSpan([ep("1", "s", "X", s: 2, e: 4), ep("2", "s", "X", s: 2, e: 6), ep("3", "s", "X", s: 3, e: 1)]),
                       "S2:E4, E6 · S3:E1")
        let many = (1...6).map { ep("e\($0)", "s", "X", s: 1, e: $0 * 2) }
        XCTAssertEqual(NewMediaDetector.episodeSpan(many), "S1:E2, E4, E6, E8…")
        XCTAssertEqual(NewMediaDetector.episodeSpan([ep("1", "s", "X", s: nil, e: 1), ep("2", "s", "X", s: nil, e: 2)]), "E1–E2")
        let n = batches([ep("1", "s", "X", s: 2, e: 4), ep("2", "s", "X", s: 2, e: 6)])
        XCTAssertEqual(n[0].body, "2 new episodes · S2:E4, E6")
    }

    func testMoviesBatchFromFour() {
        let three = batches((1...3).map { movie("m\($0)") }, movieLib)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three.map(\.target), [.item("m1"), .item("m2"), .item("m3")])
        XCTAssertEqual(three[0].images.first, NewMediaImage(id: "m1", kind: "Backdrop"))
        let four = batches((1...4).map { movie("m\($0)") }, movieLib)
        XCTAssertEqual(four.count, 1)
        XCTAssertEqual(four[0].title, "4 new movies"); XCTAssertEqual(four[0].body, "m1, m2, m3…")
        XCTAssertEqual(four[0].target, .library("L1"))
    }

    // MARK: filter

    func testFilterLibraryOff() {
        let items = [movie("m"), ep("e", "s", "X", s: 1, e: 1)]
        var p = NewMediaPrefs()
        XCTAssertEqual(NewMediaDetector.filter(items, library: "L1", server: "https://A", prefs: p, followed: []).count, 2)
        p.libsOff = [NewMediaPrefs.libKey(server: "https://a", library: "L1")]
        XCTAssertTrue(NewMediaDetector.filter(items, library: "L1", server: "https://A", prefs: p, followed: []).isEmpty)
        // Another server's library with the same id is still on
        XCTAssertEqual(NewMediaDetector.filter(items, library: "L1", server: "https://b", prefs: p, followed: []).count, 2)
        // An id switched off before 1.18.10 (no server) stays off everywhere
        p.libsOff = ["L1"]
        XCTAssertTrue(NewMediaDetector.filter(items, library: "L1", server: "https://b", prefs: p, followed: []).isEmpty)
    }

    func testFilterWatchingOnly() {
        let items = [ep("e1", "s1", "A", s: 1, e: 1), ep("e2", "s2", "B", s: 1, e: 1), movie("m")]
        var p = NewMediaPrefs()
        XCTAssertEqual(p.tvMode(server: "https://a", library: "L2"), .all)
        p.tvModes[NewMediaPrefs.libKey(server: "https://a", library: "L2")] = .followed
        XCTAssertEqual(NewMediaDetector.filter(items, library: "L2", server: "https://a", prefs: p, followed: ["s2"]).map(\.Id), ["e2", "m"])
        // Only that library
        XCTAssertEqual(NewMediaDetector.filter(items, library: "L3", server: "https://a", prefs: p, followed: ["s2"]).count, 3)
        // Filter before batching: one banner for the show being watched
        let n = batches(NewMediaDetector.filter(items.filter(\.isEpisode), library: "L2", server: "https://a", prefs: p, followed: ["s2"]))
        XCTAssertEqual(n.map(\.thread), ["s2"])
        // The old global switch is the default for libraries without their own choice
        var old = NewMediaPrefs(); old.onlyFollowed = true
        XCTAssertEqual(old.tvMode(server: "https://a", library: "L9"), .followed)
    }

    func testModesStorageRoundTrip() {
        let d: [String: NewMediaTVMode] = ["https://a:8096|L2": .followed, "https://b|L7": .all]
        XCTAssertEqual(NewMediaPrefs.decodeModes(NewMediaPrefs.encodeModes(d)), d)
        XCTAssertTrue(NewMediaPrefs.decodeModes("junk\nx=nope").isEmpty)
    }

    // MARK: click

    func testUserInfoRoundTripToTarget() {
        let targets: [NewMediaTarget] = [.item("m"), .episode("e", series: "s", season: 2), .episode("e", series: nil, season: nil),
                                         .series("s"), .library("L1"), .test]
        for t in targets {
            let n = NewMediaNotification(id: "x", title: "", body: "", thread: "", target: t, images: [],
                                         server: "https://a", userId: "u", libraryId: "L1")
            let info = NewMediaService.userInfo(n)
            XCTAssertEqual(NewMediaService.target(info), t)
            XCTAssertEqual(info["server"], "https://a")
        }
        let e = NewMediaService.userInfo(batches([ep("e", "s", "X", s: 2, e: 5)])[0])
        XCTAssertEqual(e["type"], "Episode"); XCTAssertEqual(e["seriesId"], "s"); XCTAssertEqual(e["season"], "2")
        XCTAssertNil(NewMediaService.target(["kind": "item"]))
        XCTAssertNil(NewMediaService.target([:]))
    }

    // MARK: pictures

    func testImageFilesAndCleanup() throws {
        XCTAssertTrue(NotificationImages.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(NotificationImages.looksLikeImage(Data("<html>".utf8)))
        XCTAssertEqual(NotificationImages.ext(Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        let f = try XCTUnwrap(NotificationImages.write(Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 200))))
        XCTAssertEqual(f.pathExtension, "jpg")
        XCTAssertTrue(f.path.contains("NotificationImages"))
        NotificationImages.prune(olderThan: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "a fresh file stays")
        NotificationImages.prune(olderThan: -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testServiceAsksForThePictures() async {
        let src = StubNewMediaSource(), n = StubNotifier()
        let d = UserDefaults(suiteName: "polish-\(UUID().uuidString)")!
        var now = Date(timeIntervalSince1970: 1_794_000_000)
        let svc = NewMediaService(enabled: false, notifier: n, makeSource: { _ in src }, defaults: d, prefs: { NewMediaPrefs() },
                                  now: { now }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }, log: { _ in })
        svc.update(NewMediaSession(server: "https://a", userId: "u", token: "t", authHeader: "MediaBrowser"))
        await svc.check()
        now = now.addingTimeInterval(600)
        src.latestByLib["L2"] = (4...6).map { ep("e\($0)", "s", "Severance", s: 2, e: $0) }
        await svc.check()
        XCTAssertEqual(n.posted.map(\.body), ["3 new episodes · S2:E4–E6"])
        XCTAssertEqual(src.imageAsked.first?.first, NewMediaImage(id: "s", kind: "Backdrop"))
    }
}
