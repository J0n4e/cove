import XCTest
@testable import Cove

// SyncPlay phase 4: series together. The queue a group starts with (the episode + the series' following ones),
// NextItem sent once per entry at the end of an episode, the PlayQueue NextItem update loading the new item for
// everyone, the player's picks (Up next, next / previous, Episodes panel) going through the group, and the local
// autoplay left alone outside a group.

@MainActor
final class SyncPlaySeriesTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func msg(_ s: String) -> SocketMessage {
        guard let m = SocketEnvelope.decode(s)?.message else { XCTFail("didn't decode: \(s)"); return .other("") }
        return m
    }

    private func ep(_ id: String, _ season: Int?, _ n: Int) -> Item {
        let s = season.map(String.init) ?? "null"
        let json = #"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","ParentIndexNumber":\#(s),"IndexNumber":\#(n),"SeriesId":"show"}"#
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private func make(_ rec: GroupRecorder, _ fake: FakeSyncPlayback?) -> SyncPlayGroup {
        let g = SyncPlayGroup()
        g.available = { true }
        g.runsDriver = false
        g.send = { path, body, post in
            let o = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            rec.requests.append((path, o, post))
            return rec.answers[path] ?? Data()
        }
        g.socketNeeded = { rec.socket.append($0) }
        g.playback = { fake }
        g.opener = { id, start in
            rec.opened.append((id, start))
            fake?.itemId = id; fake?.ticks = Int64(start * SyncPlayGroup.ticksPerSecond); fake?.ready = true
        }
        g.log = { _ in }
        return g
    }

    private static func queue(_ reason: String, index: Int, ids: [String] = ["e1", "e2", "e3"]) -> String {
        let list = ids.enumerated().map { #"{"ItemId":"\#($0.element)","PlaylistItemId":"pl-\#($0.offset + 1)"}"# }.joined(separator: ",")
        return GroupFixtures.update("PlayQueue", #"{"Reason":"\#(reason)","LastUpdate":"2026-11-16T10:00:00.0000000Z","Playlist":[\#(list)],"PlayingItemIndex":\#(index),"StartPositionTicks":0,"IsPlaying":false,"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}"#)
    }

    /// In a group, on e1 (pl-1) of e1, e2, e3
    private func inGroup(_ rec: GroupRecorder, _ fake: FakeSyncPlayback, index: Int = 0) async -> SyncPlayGroup {
        let g = make(rec, fake)
        g.handle(msg(GroupFixtures.groupJoined))
        g.handle(msg(Self.queue("NewPlaylist", index: index)))
        _ = await waitUntil { rec.paths.contains("/SyncPlay/Ready") }
        rec.requests = []
        return g
    }

    // MARK: Queue building

    func testSeriesQueueFromTheMiddleOfASeason() {
        let eps = [ep("s0e1", 0, 1), ep("s1e1", 1, 1), ep("s1e2", 1, 2), ep("s1e3", 1, 3), ep("s2e1", 2, 1), ep("s2e2", 2, 2)]
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "s1e2", episodes: eps), ["s1e2", "s1e3", "s2e1", "s2e2"])
    }

    func testSeriesQueueFromTheLastOfASeasonGoesOnToTheNextSeason() {
        let eps = [ep("s1e1", 1, 1), ep("s1e2", 1, 2), ep("s2e1", 2, 1)]
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "s1e2", episodes: eps), ["s1e2", "s2e1"])
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "s2e1", episodes: eps), ["s2e1"])   // the very last
    }

    func testSeriesQueueSkipsSpecialsUnlessStartingOnOne() {
        let eps = [ep("s1e1", 1, 1), ep("sp1", 0, 1), ep("s1e2", 1, 2), ep("sp2", nil, 2), ep("s1e3", 1, 3)]
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "s1e1", episodes: eps), ["s1e1", "s1e2", "s1e3"])
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "sp1", episodes: eps), ["sp1", "s1e2", "sp2", "s1e3"])
    }

    func testSeriesQueueIsCappedAndFallsBackToTheItem() {
        let eps = (1...80).map { ep("e\($0)", 1, $0) }
        let q = SyncPlayGroup.seriesQueue(from: "e10", episodes: eps)
        XCTAssertEqual(q.count, SyncPlayGroup.queueCap)
        XCTAssertEqual(q.first, "e10"); XCTAssertEqual(q.last, "e59")
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "film", episodes: eps), ["film"])
        XCTAssertEqual(SyncPlayGroup.seriesQueue(from: "film", episodes: []), ["film"])
    }

    func testNewGroupOnAnEpisodeQueuesTheSeries() async {
        let rec = GroupRecorder()
        rec.answers["/SyncPlay/New"] = Data(GroupFixtures.groupInfo.utf8)
        let g = make(rec, FakeSyncPlayback())
        g.queueFor = { id in [id, "e3", "e4"] }
        await g.create(name: "jonae's group", itemId: "e2", startTicks: 50)
        let b = rec.body("/SyncPlay/SetNewQueue")
        XCTAssertEqual(b?["PlayingQueue"] as? [String], ["e2", "e3", "e4"])
        XCTAssertEqual(b?["PlayingItemPosition"] as? Int, 0)
        XCTAssertEqual(b?["StartPositionTicks"] as? Int, 50)
    }

    // MARK: End of an episode

    func testEndOfEpisodeSendsNextItemOnce() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = await inGroup(rec, fake)
        XCTAssertEqual(g.playlist.count, 3)
        XCTAssertEqual(g.nextEntry?.ItemId, "e2")
        XCTAssertTrue(g.itemEnded())
        XCTAssertTrue(g.itemEnded())       // the end fires again / Up next's Play now was clicked first
        g.requestNext()
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/NextItem") }
        XCTAssertTrue(ok)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rec.paths.filter { $0 == "/SyncPlay/NextItem" }.count, 1)
        XCTAssertEqual(rec.body("/SyncPlay/NextItem")?["PlaylistItemId"] as? String, "pl-1")
        XCTAssertTrue(rec.opened.allSatisfy { $0.0 == "e1" })   // no local switch
    }

    func testPlayQueueNextItemLoadsTheNewItemForEveryone() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = await inGroup(rec, fake)
        XCTAssertTrue(g.itemEnded())
        g.handle(msg(Self.queue("NextItem", index: 1)))
        let ok = await waitUntil { rec.opened.last?.0 == "e2" && rec.paths.contains("/SyncPlay/Ready") }
        XCTAssertTrue(ok)
        XCTAssertEqual(g.playlistItemId, "pl-2")
        XCTAssertEqual(rec.body("/SyncPlay/Ready")?["PlaylistItemId"] as? String, "pl-2")
        XCTAssertEqual(g.toast, SyncPlayGroup.nextText)
        // The next end asks again, now for pl-2
        rec.requests = []
        XCTAssertTrue(g.itemEnded())
        _ = await waitUntil { rec.paths.contains("/SyncPlay/NextItem") }
        XCTAssertEqual(rec.body("/SyncPlay/NextItem")?["PlaylistItemId"] as? String, "pl-2")
    }

    func testLastEntryEndsLocally() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = await inGroup(rec, fake, index: 2)
        XCTAssertNil(g.nextEntry)
        XCTAssertFalse(g.itemEnded())     // the player closes as usual
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(rec.paths.contains("/SyncPlay/NextItem"))
    }

    func testOutsideAGroupLocalAutoplayIsUntouched() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = make(rec, fake)
        XCTAssertFalse(g.itemEnded())
        XCTAssertFalse(g.pick("e2"))
        // and after leaving a group
        let g2 = await inGroup(rec, fake)
        await g2.leave()
        XCTAssertTrue(g2.playlist.isEmpty)
        XCTAssertFalse(g2.itemEnded())
        XCTAssertFalse(g2.pick("e2"))
        XCTAssertFalse(rec.paths.contains("/SyncPlay/NextItem"))
    }

    // MARK: Picks in the player

    func testPicksGoThroughTheGroup() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = await inGroup(rec, fake, index: 1)   // on e2
        g.queueFor = { id in [id, "e2", "e3"] }
        XCTAssertTrue(g.pick("e3"))                  // next / Up next
        XCTAssertTrue(g.pick("e1"))                  // previous
        _ = await waitUntil { rec.paths.contains("/SyncPlay/NextItem") && rec.paths.contains("/SyncPlay/PreviousItem") }
        XCTAssertEqual(rec.body("/SyncPlay/NextItem")?["PlaylistItemId"] as? String, "pl-2")
        XCTAssertEqual(rec.body("/SyncPlay/PreviousItem")?["PlaylistItemId"] as? String, "pl-2")
        XCTAssertFalse(rec.opened.contains { $0.0 == "e3" })   // nothing switches before the group's update

        // Episodes panel: further in the queue → SetPlaylistItem; not in it → a new queue from it
        let rec2 = GroupRecorder()
        let g2 = make(rec2, fake)
        g2.handle(msg(GroupFixtures.groupJoined))
        g2.handle(msg(Self.queue("NewPlaylist", index: 0, ids: ["e1", "e2", "e3", "e4"])))
        g2.queueFor = { id in [id, "e1", "e2"] }
        XCTAssertTrue(g2.pick("e4"))
        XCTAssertTrue(g2.pick("e0"))
        _ = await waitUntil { rec2.paths.contains("/SyncPlay/SetPlaylistItem") && rec2.paths.contains("/SyncPlay/SetNewQueue") }
        XCTAssertEqual(rec2.body("/SyncPlay/SetPlaylistItem")?["PlaylistItemId"] as? String, "pl-4")
        XCTAssertEqual(rec2.body("/SyncPlay/SetNewQueue")?["PlayingQueue"] as? [String], ["e0", "e1", "e2"])
        XCTAssertEqual(rec2.body("/SyncPlay/SetNewQueue")?["PlayingItemPosition"] as? Int, 0)
    }

    func testQueueToasts() {
        XCTAssertEqual(SyncPlayGroup.queueToast("NextItem"), "Next episode for everyone")
        XCTAssertNotNil(SyncPlayGroup.queueToast("PreviousItem"))
        XCTAssertNotNil(SyncPlayGroup.queueToast("SetCurrentItem"))
        XCTAssertNil(SyncPlayGroup.queueToast("NewPlaylist"))
        XCTAssertNil(SyncPlayGroup.queueToast("Queue"))
    }
}
