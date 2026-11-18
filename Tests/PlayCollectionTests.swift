import XCTest
@testable import Cove

/// Play collection: the queue (order, resume, none skipped), collection mode only via the buttons, where the
/// Up next card starts (credits marker / 5-minute fallback / short films) and its text; notification pictures.
final class PlayCollectionTests: XCTestCase {
    private func item(_ id: String, _ name: String, year: Int? = nil, type: String = "Movie",
                      pos: Int64 = 0, played: Bool = false) -> Item {
        var o: [String: Any] = ["Id": id, "Name": name, "Type": type,
                                "UserData": ["PlaybackPositionTicks": pos, "Played": played]]
        if let year { o["ProductionYear"] = year }
        let d = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(Item.self, from: d)
    }

    private lazy var box = item("box", "The Lord of the Rings Collection", type: "BoxSet")
    private lazy var films = [item("f1", "The Fellowship of the Ring", year: 2001, played: true),
                              item("f2", "The Two Towers", year: 2002, pos: 43_500 * 10_000_000),
                              item("f3", "The Return of the King", year: 2003)]
    private func pos(_ it: Item) -> Double { Double(it.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000 }
    private func played(_ it: Item) -> Bool { it.UserData?.Played ?? false }

    // MARK: queue

    func testPlayCollectionKeepsServerOrderAndStartsAtFilmOne() throws {
        let q = try XCTUnwrap(CollectionPlay.queue(collection: box, films: films))
        XCTAssertEqual(q.ids, ["f1", "f2", "f3"])   // none skipped: the watched film 1 is included
        XCTAssertEqual(q.index, 0)
        XCTAssertEqual(q.current?.Id, "f1")
        XCTAssertEqual(q.id, "box")
        XCTAssertNil(CollectionPlay.queue(collection: box, films: []))
    }

    func testResumeIndexIsTheFilmInProgress() throws {
        let i = try XCTUnwrap(CollectionPlay.resumeIndex(films: films, position: pos, played: played))
        XCTAssertEqual(i, 1)
        let q = try XCTUnwrap(CollectionPlay.queue(collection: box, films: films, start: i))
        XCTAssertEqual(q.current?.Id, "f2")
        XCTAssertEqual(q.ids.count, 3)   // continues the whole collection from there
        XCTAssertEqual(CollectionPlay.resumeLabel(films[1], position: 4350), "Resume The Two Towers (1:12:30)")
    }

    func testNoResumeWhenNothingInProgressOrWatched() {
        let watchedWithPos = [item("a", "A", pos: 9_000_000_000, played: true), item("b", "B")]
        XCTAssertNil(CollectionPlay.resumeIndex(films: watchedWithPos, position: pos, played: played))
    }

    func testQueueMovesToAPickedFilm() throws {
        let q = try XCTUnwrap(CollectionPlay.queue(collection: box, films: films))
        XCTAssertEqual(q.at(films[2])?.index, 2)
        XCTAssertNil(q.at(item("x", "Other")))
    }

    // MARK: collection mode only via the buttons

    func testNormalPlayHasNoCollection() {
        XCTAssertNil(PlayRequest(item: films[0]).collection)
        XCTAssertNil(PlayRequest(item: films[0], start: 12).collection)
    }

    func testGroupKeepsCollectionOnlyForItsOwnQueue() throws {
        let q = try XCTUnwrap(CollectionPlay.queue(collection: box, films: films))
        XCTAssertEqual(CollectionPlay.groupCollection(q, playlist: ["f1", "f2", "f3"], itemId: "f2")?.index, 1)
        XCTAssertNil(CollectionPlay.groupCollection(q, playlist: ["f2"], itemId: "f2"))
        XCTAssertNil(CollectionPlay.groupCollection(nil, playlist: ["f1", "f2", "f3"], itemId: "f2"))
    }

    // MARK: credits start

    func testCreditsStartUsesTheMarker() {
        XCTAssertEqual(CollectionPlay.creditsStart(marker: 9_800, duration: 10_000), 9_800)
        XCTAssertEqual(CollectionPlay.creditsStart(marker: 6_000, duration: 10_000), 6_000)
    }

    func testCreditsStartFallsBackToFiveMinutes() {
        XCTAssertEqual(CollectionPlay.creditsStart(marker: nil, duration: 7_200), 6_900)
        XCTAssertEqual(CollectionPlay.creditsStart(marker: 8_000, duration: 7_200), 6_900)   // marker past the end
        XCTAssertEqual(CollectionPlay.creditsStart(marker: 0, duration: 7_200), 6_900)
    }

    func testShortFilmNeverBeforeHalf() {
        XCTAssertEqual(CollectionPlay.creditsStart(marker: nil, duration: 400), 200)   // half, not 100 s
        XCTAssertEqual(CollectionPlay.creditsStart(marker: nil, duration: 200), 100)
    }

    func testCardShowsFromTheCredits() {
        let show = { (t: Double, m: Double?) in
            CollectionPlay.showUpNext(hasNext: true, cancelled: false, time: t, duration: 7_200, marker: m) }
        XCTAssertFalse(show(6_800, nil))
        XCTAssertTrue(show(6_900, nil))
        XCTAssertTrue(show(6_500, 6_500))
        XCTAssertFalse(show(7_199.8, nil))
        XCTAssertFalse(CollectionPlay.showUpNext(hasNext: false, cancelled: false, time: 7_000, duration: 7_200, marker: nil))
        XCTAssertFalse(CollectionPlay.showUpNext(hasNext: true, cancelled: true, time: 7_000, duration: 7_200, marker: nil))
    }

    // MARK: card text

    func testCardText() {
        XCTAssertEqual(CollectionPlay.cardHeading(nextIndex: 1, count: 3), "Up next · film 2 of 3")
        XCTAssertEqual(CollectionPlay.filmTitle(films[1]), "The Two Towers (2002)")
        XCTAssertEqual(CollectionPlay.filmTitle(item("n", "No Year")), "No Year")
    }

    func testJellyfinOutroSegment() throws {
        let j = #"{"Items":[{"Type":"Intro","StartTicks":0},{"Type":"Outro","StartTicks":70000000000}]}"#
        let s = try JSONDecoder().decode(MediaSegmentList.self, from: Data(j.utf8))
        XCTAssertEqual(s.outroStart, 7_000)
        XCTAssertNil(try JSONDecoder().decode(MediaSegmentList.self, from: Data(#"{"Items":[]}"#.utf8)).outroStart)
    }

    // MARK: notification pictures (never Thumb, wide first)

    func testNotificationImagesNeverThumb() {
        XCTAssertEqual(NewMediaImage.movie("m").map(\.kind), ["Backdrop", "Primary"])
        XCTAssertEqual(NewMediaImage.show("s").map(\.kind), ["Backdrop", "Primary"])
        XCTAssertEqual(NewMediaImage.episode("e", series: "s"),
                       [NewMediaImage(id: "e", kind: "Primary"), NewMediaImage(id: "s", kind: "Backdrop"),
                        NewMediaImage(id: "s", kind: "Primary")])
        XCTAssertEqual(NewMediaImage.width, 1200)
    }
}
