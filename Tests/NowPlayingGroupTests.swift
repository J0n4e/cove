import Combine
import XCTest
@testable import Cove

// v1.18.8 SyncPlay gaps: Now Playing groups the sessions of one SyncPlay group into one card; Dashboard Play
// now in a group starts the item for the whole group (SetNewQueue), outside a group it opens locally as before.

@MainActor
final class NowPlayingGroupTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func session(_ id: String, user: String, item: String?, method: String = "DirectPlay") -> ActiveSession {
        let np = item.map { #","NowPlayingItem":{"Id":"\#($0)","Name":"Film","RunTimeTicks":60000000000}"# } ?? ""
        let json = #"{"Id":"\#(id)","UserName":"\#(user)","Client":"Cove","DeviceName":"Mac","RemoteEndPoint":"10.0.0.\#(id.count)","PlayState":{"PositionTicks":100,"IsPaused":false,"PlayMethod":"\#(method)"}\#(np)}"#
        return try! JSONDecoder().decode(ActiveSession.self, from: Data(json.utf8))
    }

    private func group(_ id: String, _ participants: [String]) -> SyncPlayGroupInfo {
        let p = participants.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"GroupId":"\#(id)","GroupName":"Movie night","State":"Playing","Participants":[\#(p)],"LastUpdatedAt":"2026-11-16T10:00:00.0000000Z"}"#
        return try! JSONDecoder().decode(SyncPlayGroupInfo.self, from: Data(json.utf8))
    }

    private func ids(_ e: [NowPlayingEntry]) -> [String] {
        e.map { x in
            switch x {
            case .single(let s): return s.Id
            case .group(let id, _, let m): return id + ":" + m.map(\.Id).joined(separator: "+")
            }
        }
    }

    // MARK: Grouping

    func testTwoParticipantsOnTheSameItemAreOneCard() {
        let s = [session("a", user: "jonae", item: "film"), session("x", user: "other", item: "show"),
                 session("b", user: "ldoctoru", item: "film", method: "Transcode")]
        let e = NowPlayingGroups.entries(s, groups: [group("g1", ["jonae", "ldoctoru"])])
        XCTAssertEqual(ids(e), ["g1:a+b", "x"])
        XCTAssertEqual(e.flatMap(\.sessions).count, 3)
    }

    func testNoGroupsOrNoCommonItemKeepsSeparateCards() {
        let s = [session("a", user: "jonae", item: "film"), session("b", user: "ldoctoru", item: "other")]
        XCTAssertEqual(ids(NowPlayingGroups.entries(s, groups: [])), ["a", "b"])
        XCTAssertEqual(ids(NowPlayingGroups.entries(s, groups: [group("g1", ["jonae", "ldoctoru"])])), ["a", "b"])
    }

    func testNonParticipantOnTheSameItemStaysSeparate() {
        let s = [session("a", user: "jonae", item: "film"), session("b", user: "ldoctoru", item: "film"),
                 session("c", user: "stranger", item: "film")]
        XCTAssertEqual(ids(NowPlayingGroups.entries(s, groups: [group("g1", ["JONAE", "ldoctoru"])])), ["g1:a+b", "c"])
    }

    func testAmbiguousItemsAreNotGuessed() {
        // Two pairs of the participants on two different items: no reliable match
        let s = [session("a", user: "u1", item: "film"), session("b", user: "u2", item: "film"),
                 session("c", user: "u3", item: "show"), session("d", user: "u4", item: "show")]
        XCTAssertEqual(ids(NowPlayingGroups.entries(s, groups: [group("g1", ["u1", "u2", "u3", "u4"])])), ["a", "b", "c", "d"])
    }

    func testOwnGroupUsesItsPlayQueueItem() {
        let s = [session("a", user: "u1", item: "film"), session("b", user: "u2", item: "film"),
                 session("c", user: "u3", item: "show"), session("d", user: "u4", item: "show")]
        let e = NowPlayingGroups.entries(s, groups: [group("g1", ["u1", "u2", "u3", "u4"])], own: ("g1", "show"))
        XCTAssertEqual(ids(e), ["a", "b", "g1:c+d"])
    }

    func testASingleMemberAndIdleSessionsStaySingle() {
        let s = [session("a", user: "jonae", item: "film"), session("b", user: "ldoctoru", item: nil)]
        XCTAssertEqual(ids(NowPlayingGroups.entries(s, groups: [group("g1", ["jonae", "ldoctoru"])], own: ("g1", "film"))), ["a", "b"])
    }

    func testTwoGroupsEachGetTheirCardAndASessionIsInOnlyOne() {
        let s = [session("a", user: "u1", item: "film"), session("b", user: "u2", item: "film"),
                 session("c", user: "u3", item: "show"), session("d", user: "u4", item: "show")]
        let e = NowPlayingGroups.entries(s, groups: [group("g1", ["u1", "u2"]), group("g2", ["u3", "u4", "u1"])])
        XCTAssertEqual(ids(e), ["g1:a+b", "g2:c+d"])
    }

    // MARK: Dashboard Play now in a group

    private func makeGroup(_ rec: GroupRecorder, _ fake: FakeSyncPlayback) -> SyncPlayGroup {
        let g = SyncPlayGroup()
        g.available = { true }
        g.runsDriver = false
        g.send = { path, body, post in
            let o = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            rec.requests.append((path, o, post))
            return rec.answers[path] ?? Data()
        }
        g.playback = { fake }
        g.opener = { id, start in
            rec.opened.append((id, start))
            fake.itemId = id; fake.ticks = Int64(start * SyncPlayGroup.ticksPerSecond); fake.ready = true
        }
        g.log = { _ in }
        return g
    }

    private final class Opened { var all: [(String, Double)] = [] }

    private func router(_ g: SyncPlayGroup, opened: @escaping @MainActor (String, Double) -> Void) -> RemoteCommandRouter {
        let r = RemoteCommandRouter()
        r.isJellyfin = { true }
        r.log = { _ in }
        r.openItem = { id, s in opened(id, s) }
        r.groupPlayNow = { id, s in g.remotePlayNow(id, startTicks: Int64((s * SyncPlayGroup.ticksPerSecond).rounded())) }
        return r
    }

    private func msg(_ s: String) -> SocketMessage {
        guard let m = SocketEnvelope.decode(s)?.message else { XCTFail("didn't decode: \(s)"); return .other("") }
        return m
    }

    func testPlayNowInAGroupSendsTheSeriesQueueToTheGroup() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = makeGroup(rec, fake)
        g.handle(msg(GroupFixtures.groupJoined))
        g.queueFor = { id in [id, "e2", "e3"] }
        let opened = Opened()
        let r = router(g) { id, s in opened.all.append((id, s)) }
        let a = r.handle(msg(RemoteControlTests.play("PlayNow", ticks: 300_000_000)))
        XCTAssertEqual(a, .playNow(itemId: "film42", startSeconds: 30))
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/SetNewQueue") }
        XCTAssertTrue(ok)
        let b = rec.body("/SyncPlay/SetNewQueue")
        XCTAssertEqual(b?["PlayingQueue"] as? [String], ["film42", "e2", "e3"])
        XCTAssertEqual(b?["PlayingItemPosition"] as? Int, 0)
        XCTAssertEqual((b?["StartPositionTicks"] as? NSNumber)?.int64Value, 300_000_000)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(opened.all.isEmpty)              // nothing opens before the group's PlayQueue update
    }

    func testPlayNowOutsideAGroupOpensLocally() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = makeGroup(rec, fake)
        let opened = Opened()
        let r = router(g) { id, s in opened.all.append((id, s)) }
        r.handle(msg(RemoteControlTests.play("PlayNow", ticks: 100_000_000)))
        let ok = await waitUntil { !opened.all.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(opened.all.first?.0, "film42")
        XCTAssertEqual(opened.all.first?.1, 10)
        XCTAssertFalse(rec.paths.contains("/SyncPlay/SetNewQueue"))
    }

    func testGroupPlayNowFallsBackToTheItemWhenTheQueueDoesNotStartWithIt() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = makeGroup(rec, fake)
        g.handle(msg(GroupFixtures.groupJoined))
        g.queueFor = { _ in ["other"] }
        XCTAssertTrue(g.remotePlayNow("film42", startTicks: -5))
        _ = await waitUntil { rec.paths.contains("/SyncPlay/SetNewQueue") }
        XCTAssertEqual(rec.body("/SyncPlay/SetNewQueue")?["PlayingQueue"] as? [String], ["film42"])
        XCTAssertEqual((rec.body("/SyncPlay/SetNewQueue")?["StartPositionTicks"] as? NSNumber)?.int64Value, 0)
    }

    // MARK: Glass Up next countdown text (shared with Glass3D)

    func testGroupCountdownText() {
        XCTAssertEqual(GroupUpNext.text(12), "Next episode for everyone in 0:12")
        XCTAssertEqual(GroupUpNext.text(65), "Next episode for everyone in 1:05")
    }
}
