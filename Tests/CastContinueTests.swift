import XCTest
@testable import Cove

/// Cast phase 2: continuing on the TV, Up next timing, track choice from memory, the reconnect decision and the
/// saved cast restored after a relaunch (CastContinue.swift).
final class CastContinueTests: XCTestCase {

    private func item(_ id: String, type: String = "Episode", s: Int? = 1, e: Int? = nil, series: String? = "S1") -> Item {
        var j = #"{"Id":"\#(id)","Name":"N\#(id)","Type":"\#(type)""#
        if let s { j += #","ParentIndexNumber":\#(s)"# }
        if let e { j += #","IndexNumber":\#(e)"# }
        if let series { j += #","SeriesId":"\#(series)""# }
        return try! JSONDecoder().decode(Item.self, from: Data((j + "}").utf8))
    }
    private func film(_ id: String) -> Item { item(id, type: "Movie", s: nil, series: nil) }
    private func stream(_ i: Int, _ type: String, lang: String?, codec: String = "subrip", external: Bool = false, def: Bool = false) -> MStream {
        var j = #"{"Index":\#(i),"Type":"\#(type)","Codec":"\#(codec)","IsExternal":\#(external),"IsDefault":\#(def)"#
        if let lang { j += #","Language":"\#(lang)""# }
        return try! JSONDecoder().decode(MStream.self, from: Data((j + "}").utf8))
    }

    // MARK: Next item

    func testNextEpisode() {
        let eps = [item("a", e: 1), item("b", e: 2), item("c", e: 3)]
        XCTAssertEqual(CastContinue.next(after: eps[0], episodes: eps, collection: nil, autoNext: true)?.Id, "b")
        XCTAssertNil(CastContinue.next(after: eps[2], episodes: eps, collection: nil, autoNext: true))   // last
        XCTAssertNil(CastContinue.next(after: eps[0], episodes: eps, collection: nil, autoNext: false))  // autoplay off
        XCTAssertNil(CastContinue.next(after: film("m"), episodes: eps, collection: nil, autoNext: true)) // a plain film
    }

    func testCollectionQueueInOrderToTheEnd() {
        let films = [film("1"), film("2"), film("3")]
        let q = CollectionQueue(id: "box", name: "Trilogy", items: films, index: 0)
        XCTAssertEqual(CastContinue.next(after: films[0], episodes: [], collection: q, autoNext: true)?.Id, "2")
        XCTAssertEqual(CastContinue.next(after: films[1], episodes: [], collection: q.at(films[1]), autoNext: true)?.Id, "3")
        XCTAssertNil(CastContinue.next(after: films[2], episodes: [], collection: q, autoNext: true))
        XCTAssertNil(CastContinue.next(after: films[0], episodes: [], collection: q, autoNext: false))
        XCTAssertEqual(CastContinue.position(films[1], collection: q), "Film 2 of 3")
        XCTAssertEqual(CastContinue.position(item("x", s: 2, e: 5), collection: nil), "S2:E5")
        XCTAssertNil(CastContinue.position(film("m"), collection: nil))
        XCTAssertEqual(CastContinue.heading(films[1], collection: q), "Up next · film 2 of 3")
        XCTAssertEqual(CastContinue.memoryKey(films[0], collection: q), "box:box")
        XCTAssertEqual(CastContinue.memoryKey(item("e"), collection: nil), "S1")
    }

    // MARK: Up next timing

    func testUpNextFromMarkers() {
        // collection: the marker, else 5 min before the end, never before half
        XCTAssertEqual(CastContinue.upNextStart(collection: true, marker: 6000, duration: 7000), 6000)
        XCTAssertEqual(CastContinue.upNextStart(collection: true, marker: nil, duration: 7000), 6700)
        XCTAssertEqual(CastContinue.upNextStart(collection: true, marker: nil, duration: 400), 200)
        // episode: its credits marker (in the second half), else the last 30 s like the local player
        XCTAssertEqual(CastContinue.upNextStart(collection: false, marker: 2500, duration: 2700), 2500)
        XCTAssertEqual(CastContinue.upNextStart(collection: false, marker: nil, duration: 2700), 2670)
        XCTAssertEqual(CastContinue.upNextStart(collection: false, marker: 100, duration: 2700), 2670)
        XCTAssertTrue(CastContinue.showUpNext(hasNext: true, cancelled: false, collection: false, time: 2680, duration: 2700, marker: nil))
        XCTAssertFalse(CastContinue.showUpNext(hasNext: true, cancelled: true, collection: false, time: 2680, duration: 2700, marker: nil))
        XCTAssertFalse(CastContinue.showUpNext(hasNext: false, cancelled: false, collection: false, time: 2680, duration: 2700, marker: nil))
        XCTAssertFalse(CastContinue.showUpNext(hasNext: true, cancelled: false, collection: false, time: 100, duration: 2700, marker: nil))
    }

    // MARK: Tracks

    func testTrackChoiceFromMemory() {
        let streams = [stream(1, "Audio", lang: "eng", codec: "aac", def: true), stream(2, "Audio", lang: "fre", codec: "aac"),
                       stream(3, "Subtitle", lang: "rum", codec: "subrip"), stream(4, "Subtitle", lang: "rum", codec: "subrip", external: true),
                       stream(5, "Subtitle", lang: "eng", codec: "pgssub")]
        // nothing remembered: default audio, no subtitle
        XCTAssertEqual(CastTracks.pick(streams, memory: nil, subAlways: false, subLang: nil).audio, 1)
        XCTAssertNil(CastTracks.pick(streams, memory: nil, subAlways: false, subLang: nil).sub)
        // remembered audio + subtitle language: external SRT first
        let m = ["audio": "fre", "sub": "Romanian"]
        XCTAssertEqual(CastTracks.pick(streams, memory: m, subAlways: false, subLang: nil).audio, 2)
        XCTAssertEqual(CastTracks.pick(streams, memory: m, subAlways: false, subLang: nil).sub, 4)
        // remembered "off" (collection memory too)
        XCTAssertNil(CastTracks.pick(streams, memory: ["sub": "off"], subAlways: false, subLang: nil).sub)
        // "Always load preferred subtitle language" wins over the memory
        XCTAssertEqual(CastTracks.pick(streams, memory: ["sub": "off"], subAlways: true, subLang: "english").sub, 5)
        // the detail page's episode Subtitles menu comes first
        XCTAssertNil(CastTracks.pick(streams, memory: m, wantedSub: "off", subAlways: true, subLang: "english").sub)
        XCTAssertEqual(CastTracks.pick(streams, memory: nil, wantedSub: "romanian", subAlways: false, subLang: nil).sub, 4)
        // what the remote writes back
        XCTAssertEqual(CastTracks.subMemory(nil, streams: streams), "off")
        XCTAssertEqual(CastTracks.subMemory(3, streams: streams), "Romanian")
        XCTAssertEqual(CastTracks.audioMemory(2, streams: streams), "fre")
    }

    // MARK: Reconnect

    func testReconnectDecision() {
        let ours: [String: Any] = ["type": "RECEIVER_STATUS", "status": ["applications": [
            ["appId": "CC1AD845", "transportId": "web-7", "sessionId": "s1", "displayName": "Default Media Receiver"]]]]
        let st = CastReceiverStatus.parse(ours)!
        XCTAssertEqual(CastReconnect.receiver(st, session: "s1"), .attach(transportId: "web-7", sessionId: "s1"))
        XCTAssertEqual(CastReconnect.receiver(st, session: "other"), .takenOver(nil))   // another sender's session
        let yt = CastReceiverStatus.parse(["type": "RECEIVER_STATUS", "status": ["applications": [
            ["appId": "233637DE", "displayName": "YouTube"]]]])!
        XCTAssertEqual(CastReconnect.receiver(yt, session: "s1"), .takenOver("YouTube"))
        let idle = CastReceiverStatus.parse(["type": "RECEIVER_STATUS", "status": ["applications": []]])!
        XCTAssertEqual(CastReconnect.receiver(idle, session: "s1"), .idle)

        let playing = CastMediaStatus(mediaSessionId: 3, playerState: "PLAYING", currentTime: 50, idleReason: nil,
                                      duration: 100, volume: nil, contentId: "http://s/Videos/1/master.m3u8?PlaySessionId=abc")
        XCTAssertTrue(CastReconnect.mediaAlive(playing, playSessionId: "abc"))
        XCTAssertFalse(CastReconnect.mediaAlive(playing, playSessionId: "zzz"))   // someone else's video
        var ended = playing; ended.playerState = "IDLE"
        XCTAssertFalse(CastReconnect.mediaAlive(ended, playSessionId: "abc"))
        XCTAssertFalse(CastReconnect.mediaAlive(nil, playSessionId: "abc"))
        // parse keeps the stream URL
        let j: [String: Any] = ["type": "MEDIA_STATUS", "status": [["mediaSessionId": 3, "playerState": "PLAYING",
                                "media": ["contentId": "u?PlaySessionId=abc"]]]]
        XCTAssertEqual(CastMediaStatus.parse(j)?.contentId, "u?PlaySessionId=abc")
    }

    func testBackoff() {
        let waits = (0..<7).map { CastReconnect.delay(attempt: $0, elapsed: 0) }
        XCTAssertEqual(waits, [1, 2, 4, 8, 15, 15, 15])
        XCTAssertNil(CastReconnect.delay(attempt: 3, elapsed: 121))
    }

    // MARK: Saved cast

    func testSavedCastRestore() {
        let d = UserDefaults(suiteName: "CastContinueTests")!
        d.removePersistentDomain(forName: "CastContinueTests")
        let s = SavedCast(server: "http://10.0.0.2:8096", deviceId: "dev1", deviceName: "Living room TV", itemId: "i1",
                          sourceId: "src", receiverSession: "s1", playSessionId: "abc", audio: 1, sub: nil, position: 812,
                          collectionId: "box", collectionName: "Trilogy", collectionIds: ["i1", "i2"])
        s.save(d)
        XCTAssertEqual(SavedCast.load(d), s)
        let tv = CastDevice.from(txt: ["id": "dev1", "fn": "Living room TV"], service: "Chromecast-1")
        let other = CastDevice.from(txt: ["id": "dev2"], service: "Chromecast-2")
        XCTAssertEqual(s.restorable(server: "http://10.0.0.2:8096", devices: [other, tv]), tv)
        XCTAssertNil(s.restorable(server: "http://10.0.0.2:8096", devices: [other]))       // TV not found
        XCTAssertNil(s.restorable(server: "http://other:8096", devices: [tv]))              // signed in elsewhere
        SavedCast.clear(d)
        XCTAssertNil(SavedCast.load(d))
    }
}
