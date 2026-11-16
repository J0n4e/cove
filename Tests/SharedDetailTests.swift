import XCTest
@testable import Cove

/// The item page's shared model (DetailModel) against a small fake server: what loads, in which order, which
/// season and episode it picks, the version/audio defaults, what Play sends, and that a cancelled load writes nothing.
@MainActor
final class SharedDetailTests: XCTestCase {
    final class Fake: DetailSource {
        var fulls: [String: Full] = [:]
        var eps: [Item] = [], seasonList: [Item] = [], kids: [Item] = [], boxes: [Item] = [], like: [Item] = []
        var next: Item?
        var playedIds: Set<String> = []
        var resume: [String: Double] = [:]
        var openSeason: Int?
        var playing: PlayRequest?
        var played: [String] = []
        var calls: [String] = []
        /// full() waits this long first (a cancelled task's sleep ends at once)
        var fullDelay: UInt64 = 0

        func full(_ id: String) async -> Full? {
            calls.append("full:" + id)
            if fullDelay > 0 { try? await Task.sleep(nanoseconds: fullDelay) }
            return fulls[id]
        }
        func episodes(_ seriesId: String) async -> [Item] { calls.append("episodes"); return eps }
        func seasons(_ seriesId: String) async -> [Item] { calls.append("seasons"); return seasonList }
        func nextUp(_ seriesId: String) async -> Item? { calls.append("nextUp"); return next }
        func children(_ parentId: String) async -> [Item] { calls.append("children"); return kids }
        func collections(containing id: String) async -> [Item] { calls.append("collections"); return boxes }
        func similar(_ id: String) async -> [Item] { calls.append("similar"); return like }
        func isPlayed(_ it: Item) -> Bool { playedIds.contains(it.id) }
        func resumeAt(_ it: Item) -> Double { resume[it.id] ?? 0 }
        func play(_ it: Item) async { played.append(it.id) }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "SharedDetailTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func item(_ id: String, _ type: String, season: Int? = nil, ep: Int? = nil) -> Item {
        var json = "{\"Id\":\"\(id)\",\"Name\":\"n\(id)\",\"Type\":\"\(type)\""
        if let season { json += ",\"ParentIndexNumber\":\(season)" }
        if let ep { json += ",\"IndexNumber\":\(ep)" }
        return try! JSONDecoder().decode(Item.self, from: Data((json + "}").utf8))
    }

    private func seasonItem(_ id: String, _ n: Int, _ name: String) -> Item {
        try! JSONDecoder().decode(Item.self, from: Data("{\"Id\":\"\(id)\",\"Name\":\"\(name)\",\"Type\":\"Season\",\"IndexNumber\":\(n)}".utf8))
    }

    /// Two versions: the first with audio 1 (default) and 2, the second with audio 3 and 4 (none marked default).
    private func movieFull() -> Full {
        let json = """
        {"MediaSources":[
          {"Id":"v1","Name":"1080p","MediaStreams":[{"Index":0,"Type":"Video"},{"Index":1,"Type":"Audio"},
                                                    {"Index":2,"Type":"Audio","IsDefault":true},
                                                    {"Index":5,"Type":"Subtitle","Language":"eng","DisplayTitle":"English (SRT)"}]},
          {"Id":"v2","Name":"4K","MediaStreams":[{"Index":0,"Type":"Video"},{"Index":3,"Type":"Audio"},{"Index":4,"Type":"Audio"}]}
        ]}
        """
        return try! JSONDecoder().decode(Full.self, from: Data(json.utf8))
    }

    private func subsFull() -> Full {
        let json = """
        {"MediaSources":[{"Id":"s","MediaStreams":[
          {"Index":2,"Type":"Subtitle","Language":"eng","DisplayTitle":"English (PGS)","Codec":"pgssub"},
          {"Index":3,"Type":"Subtitle","Language":"eng","DisplayTitle":"English (SRT)","Codec":"srt"},
          {"Index":4,"Type":"Subtitle","Language":"fre","DisplayTitle":"French (SRT)","Codec":"srt"}]}]}
        """
        return try! JSONDecoder().decode(Full.self, from: Data(json.utf8))
    }

    /// S1E1, S1E2, S2E1, S2E2, Specials E1 (listed first by the server).
    private func seriesFake() -> Fake {
        let f = Fake()
        f.eps = [item("sp1", "Episode", season: 0, ep: 1),
                 item("e11", "Episode", season: 1, ep: 1), item("e12", "Episode", season: 1, ep: 2),
                 item("e21", "Episode", season: 2, ep: 1), item("e22", "Episode", season: 2, ep: 2)]
        f.seasonList = [seasonItem("s1", 1, "Season One"), seasonItem("s2", 2, "Season Two")]
        f.fulls = ["show": movieFull(), "sp1": subsFull()]
        return f
    }

    // MARK: Loading

    func testSeriesLoadPopulatesStateInOrder() async {
        let f = seriesFake()
        let m = DetailModel(item: item("show", "Series"), defaults: freshDefaults())
        m.bind(f)
        await m.load()
        XCTAssertNotNil(m.full)
        XCTAssertEqual(m.kids.map(\.Id), ["sp1", "e11", "e12", "e21", "e22"])
        XCTAssertEqual(m.seasonItems.map(\.Id), ["s1", "s2"])
        XCTAssertEqual(m.epLangs.map(\.code), ["english", "french"])
        XCTAssertTrue(m.includedIn.isEmpty)
        // full, then episodes and seasons together, then next up, the first episode's subtitles, Included In, similar
        XCTAssertEqual(f.calls.first, "full:show")
        XCTAssertEqual(Set(f.calls[1...2]), ["episodes", "seasons"])
        XCTAssertEqual(Array(f.calls[3...]), ["nextUp", "full:sp1", "collections", "similar"])
        XCTAssertEqual(m.seasonNumbers, [1, 2, 0])          // Specials last
        XCTAssertEqual(m.seasonTitle(2), "Season Two")
        XCTAssertEqual(m.seasonTitle(3), "Season 3")
        XCTAssertEqual(m.seasonTitle(0), "Specials")
    }

    func testMovieAndEpisodeAndCollectionRequests() async {
        let f = Fake(); f.fulls = ["m": movieFull()]
        let movie = DetailModel(item: item("m", "Movie"), defaults: freshDefaults()); movie.bind(f)
        await movie.load()
        XCTAssertEqual(f.calls, ["full:m", "collections", "similar"])

        f.calls = []
        let ep = DetailModel(item: item("e", "Episode"), defaults: freshDefaults()); ep.bind(f)
        await ep.load()
        XCTAssertEqual(f.calls, ["full:e"])

        f.calls = []; f.kids = [item("a", "Movie"), item("b", "Movie")]
        let box = DetailModel(item: item("b", "BoxSet"), defaults: freshDefaults()); box.bind(f)
        await box.load()
        XCTAssertEqual(f.calls, ["full:b", "children", "similar"])
        XCTAssertEqual(box.kids.map(\.Id), ["a", "b"])
    }

    func testCancelledLoadWritesNothing() async {
        let f = seriesFake(); f.fullDelay = 2_000_000_000
        let m = DetailModel(item: item("show", "Series"), defaults: freshDefaults())
        m.bind(f)
        let t = Task { await m.load() }
        t.cancel()
        await t.value
        XCTAssertNil(m.full)
        XCTAssertTrue(m.kids.isEmpty)
        XCTAssertNil(m.nextEp)
        XCTAssertEqual(f.calls, ["full:show"])   // nothing after the cancelled step
    }

    // MARK: Season and next episode

    func testDefaultSeasonIsFirstWithSomethingUnwatched() async {
        let f = seriesFake(); f.playedIds = ["sp1", "e11", "e12"]
        let m = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); m.bind(f)
        await m.load()
        XCTAssertNil(m.season)
        XCTAssertEqual(m.currentSeason, 2)
        XCTAssertEqual(m.shownEpisodes.map(\.Id), ["e21", "e22"])
        XCTAssertEqual(m.unwatched(1), 0)
        XCTAssertEqual(m.unwatched(2), 2)
        XCTAssertNil(m.unwatched(7))

        // all watched: the first season in order
        f.playedIds = Set(f.eps.map(\.Id))
        XCTAssertEqual(m.currentSeason, 1)
    }

    func testOpenSeasonWinsAndIsConsumed() async {
        let f = seriesFake(); f.openSeason = 1; f.playedIds = ["e11"]
        let m = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); m.bind(f)
        await m.load()
        XCTAssertEqual(m.season, 1)
        XCTAssertEqual(m.currentSeason, 1)
        XCTAssertNil(f.openSeason)
    }

    func testHideWatchedOnlyInAMixedSeason() async {
        let f = seriesFake(); f.playedIds = ["e11"]
        let m = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); m.bind(f)
        await m.load()
        m.season = 1
        XCTAssertTrue(m.canFilterWatched)
        XCTAssertEqual(m.shownEpisodes.map(\.Id), ["e12"])
        m.showAllEps = true
        XCTAssertEqual(m.shownEpisodes.map(\.Id), ["e11", "e12"])
        m.seasonChanged()
        XCTAssertFalse(m.showAllEps)
        m.season = 2
        XCTAssertFalse(m.canFilterWatched)
        XCTAssertEqual(m.shownEpisodes.map(\.Id), ["e21", "e22"])
    }

    func testNextEpisodeServerFirstThenFirstUnwatchedThenFirst() async {
        let f = seriesFake(); f.next = item("e21", "Episode", season: 2, ep: 1)
        let a = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); a.bind(f)
        await a.load()
        XCTAssertEqual(a.nextEp?.Id, "e21")
        XCTAssertEqual(a.playLabel, "Play S2:E1")

        f.next = nil; f.playedIds = ["sp1", "e11"]
        let b = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); b.bind(f)
        await b.load()
        XCTAssertEqual(b.nextEp?.Id, "e12")

        f.playedIds = Set(f.eps.map(\.Id))
        let c = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); c.bind(f)
        await c.load()
        XCTAssertEqual(c.nextEp?.Id, "sp1")
    }

    func testResumePointFollowsThePlayTarget() async {
        let f = seriesFake(); f.next = item("e12", "Episode", season: 1, ep: 2); f.resume = ["e12": 600, "show": 99]
        let s = DetailModel(item: item("show", "Series"), defaults: freshDefaults()); s.bind(f)
        XCTAssertEqual(s.resumePoint, 0)   // nothing to play before loading
        await s.load()
        XCTAssertEqual(s.playTarget?.Id, "e12")
        XCTAssertEqual(s.resumePoint, 600)

        f.resume = ["m": 120]
        let m = DetailModel(item: item("m", "Movie"), defaults: freshDefaults()); m.bind(f)
        XCTAssertEqual(m.playLabel, "Play")
        XCTAssertEqual(m.resumePoint, 120)
        let box = DetailModel(item: item("b", "BoxSet"), defaults: freshDefaults()); box.bind(f)
        XCTAssertNil(box.playTarget)
        XCTAssertEqual(box.resumePoint, 0)
    }

    // MARK: Versions and Play

    func testVersionDefaultsAndSwitching() async {
        let f = Fake(); f.fulls = ["m": movieFull()]
        let m = DetailModel(item: item("m", "Movie"), defaults: freshDefaults()); m.bind(f)
        await m.load()
        XCTAssertEqual(m.srcIdx, 0)
        XCTAssertEqual(m.src?.Id, "v1")
        XCTAssertEqual(m.audioIdx, 2)   // the stream marked default
        XCTAssertEqual(m.subIdx, -1)
        m.subIdx = 5
        m.srcIdx = 1; m.sourceChanged()
        XCTAssertEqual(m.src?.Id, "v2")
        XCTAssertEqual(m.audioIdx, 3)   // none marked: the first
        XCTAssertEqual(m.subIdx, -1)
    }

    func testPreferredSubtitleWhenAlwaysLoadIsOn() async {
        let d = freshDefaults(); d.set(true, forKey: "subAlways"); d.set("english", forKey: "subLang")
        let f = Fake(); f.fulls = ["m": movieFull()]
        let m = DetailModel(item: item("m", "Movie"), defaults: d); m.bind(f)
        await m.load()
        XCTAssertEqual(m.subIdx, 5)
    }

    func testPlayNowMovieSendsTheChoices() async {
        let d = freshDefaults(); d.set(4_000_000, forKey: "defaultQuality")
        let f = Fake(); f.fulls = ["m": movieFull()]; f.resume = ["m": 300]
        let m = DetailModel(item: item("m", "Movie"), defaults: d); m.bind(f)
        await m.load()
        XCTAssertEqual(m.quality, 4_000_000)
        m.playNow()
        XCTAssertEqual(f.playing?.sourceId, "v1")
        XCTAssertNil(f.playing?.audio)            // default audio isn't sent
        XCTAssertNil(f.playing?.sub)
        XCTAssertEqual(f.playing?.noSub, true)
        XCTAssertEqual(f.playing?.maxBitrate, 4_000_000)
        XCTAssertEqual(f.playing?.start, 300)
        m.audioIdx = 1; m.subIdx = 5
        m.playNow(from: 0)
        XCTAssertEqual(f.playing?.audio, 1)
        XCTAssertEqual(f.playing?.sub, 5)
        XCTAssertEqual(f.playing?.noSub, false)
        XCTAssertEqual(f.playing?.start, 0)
    }

    func testPlayNowCollectionHandsTheItemOver() async {
        let f = Fake()
        let m = DetailModel(item: item("b", "BoxSet"), defaults: freshDefaults()); m.bind(f)
        m.playNow()
        for _ in 0..<50 where f.played.isEmpty { await Task.yield() }
        XCTAssertEqual(f.played, ["b"])
        XCTAssertNil(f.playing)
    }

    func testPlayEpisodeSubtitleChoice() async {
        let d = freshDefaults()
        let f = seriesFake(); f.fulls["e11"] = subsFull(); f.resume = ["e11": 90]
        let m = DetailModel(item: item("show", "Series"), defaults: d); m.bind(f)
        let ep = item("e11", "Episode", season: 1, ep: 1)

        // nothing chosen, Always load off: no subtitle lookup
        m.playEpisode(ep)
        XCTAssertEqual(f.playing?.start, 90)
        XCTAssertNil(f.playing?.sub)
        XCTAssertEqual(f.playing?.noSub, false)

        d.set("off", forKey: "episodeSubLang")
        m.playEpisode(ep, from: 0)
        XCTAssertEqual(f.playing?.noSub, true)
        XCTAssertEqual(f.playing?.start, 0)

        // a language: its text track (SRT) beats the picture one
        d.set("english", forKey: "episodeSubLang")
        f.playing = nil
        m.playEpisode(ep)
        for _ in 0..<50 where f.playing == nil { await Task.yield() }
        XCTAssertEqual(f.playing?.sub, 3)
        XCTAssertEqual(f.playing?.sourceId, "s")
    }
}
