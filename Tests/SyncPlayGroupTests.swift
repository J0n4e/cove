import XCTest
@testable import Cove

// SyncPlay phase 2: group updates and commands decoded from server-shaped JSON (MediaBrowser.Model/SyncPlay),
// command scheduling, the user's own play / pause / seek routed through the group, join / leave / new group
// requests, the PlayQueue load + Buffering / Ready reports, and that Emby gets nothing.

@MainActor
final class FakeSyncPlayback: SyncPlayPlayback {
    var ticks: Int64 = 0
    var playing = true
    var itemId: String? = "item-1"
    var ready = true
    var calls: [String] = []
    var pausedAt: Date?

    var syncPlayTicks: Int64 { ticks }
    var syncPlayIsPlaying: Bool { playing }
    var syncPlayItemId: String? { itemId }
    var syncPlayReady: Bool { ready }
    func syncPlayPlay() { playing = true; calls.append("play") }
    func syncPlayPause() { playing = false; pausedAt = Date(); calls.append("pause") }
    func syncPlaySeek(ticks: Int64) { self.ticks = ticks; calls.append("seek") }
}

@MainActor
final class GroupRecorder {
    var requests: [(path: String, body: [String: Any]?, post: Bool)] = []
    var answers: [String: Data] = [:]
    var socket: [Bool] = []
    var opened: [(String, Double)] = []
    /// Paths without the 10-second pings
    var paths: [String] { requests.map(\.path).filter { $0 != "/SyncPlay/Ping" } }
    func body(_ path: String) -> [String: Any]? { requests.last { $0.path == path }?.body }
}

enum GroupFixtures {
    static let gid = "a1b2c3d40000400080000000000000aa"
    static func update(_ type: String, _ data: String) -> String {
        #"{"MessageType":"SyncPlayGroupUpdate","MessageId":"m1","Data":{"GroupId":"\#(gid)","Type":"\#(type)","Data":\#(data)}}"#
    }
    static let groupInfo = #"{"GroupId":"\#(gid)","GroupName":"jonae's group","State":"Idle","Participants":["jonae"],"LastUpdatedAt":"2026-11-16T10:00:00.0000000Z"}"#
    static let groupJoined = update("GroupJoined", groupInfo)
    static let userJoined = update("UserJoined", #""ldoctoru""#)
    static let userLeft = update("UserLeft", #""ldoctoru""#)
    static let groupLeft = update("GroupLeft", #""\#(gid)""#)
    static let notInGroup = update("NotInGroup", #""""#)
    static let doesNotExist = update("GroupDoesNotExist", #""""#)
    static let accessDenied = update("LibraryAccessDenied", #""""#)
    static let waiting = update("StateUpdate", #"{"State":"Waiting","Reason":"Seek"}"#)
    static func playQueue(reason: String = "NewPlaylist", start: Int64 = 600_000_000, playing: Bool = false) -> String {
        update("PlayQueue", #"{"Reason":"\#(reason)","LastUpdate":"2026-11-16T10:00:00.0000000Z","Playlist":[{"ItemId":"film42","PlaylistItemId":"pl-1"}],"PlayingItemIndex":0,"StartPositionTicks":\#(start),"IsPlaying":\#(playing),"ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}"#)
    }
    static func command(_ c: String, when: Date, ticks: Int64? = 1_000_000_000, group: String = gid) -> String {
        let pos = ticks.map { String($0) } ?? "null"
        return #"{"MessageType":"SyncPlayCommand","MessageId":"m2","Data":{"GroupId":"\#(group)","PlaylistItemId":"pl-1","When":"\#(SyncPlayGroup.iso(when))","PositionTicks":\#(pos),"Command":"\#(c)","EmittedAt":"\#(SyncPlayGroup.iso(Date()))"}}"#
    }
}

@MainActor
final class SyncPlayGroupTests: XCTestCase {
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

    private func make(_ rec: GroupRecorder, _ fake: FakeSyncPlayback?, available: Bool = true) -> SyncPlayGroup {
        let g = SyncPlayGroup()
        g.available = { available }
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

    private func joined(_ rec: GroupRecorder, _ fake: FakeSyncPlayback?) -> SyncPlayGroup {
        let g = make(rec, fake)
        g.handle(msg(GroupFixtures.groupJoined))
        return g
    }

    // MARK: Decoding

    func testDecodesEveryGroupUpdate() {
        guard case .syncPlayGroupUpdate(let j) = msg(GroupFixtures.groupJoined) else { return XCTFail() }
        XCTAssertEqual(j.type, "GroupJoined")
        XCTAssertEqual(j.group?.GroupName, "jonae's group")
        XCTAssertEqual(j.group?.Participants, ["jonae"])
        guard case .syncPlayGroupUpdate(let u) = msg(GroupFixtures.userJoined) else { return XCTFail() }
        XCTAssertEqual(u.type, "UserJoined"); XCTAssertEqual(u.text, "ldoctoru")
        guard case .syncPlayGroupUpdate(let l) = msg(GroupFixtures.userLeft) else { return XCTFail() }
        XCTAssertEqual(l.type, "UserLeft"); XCTAssertEqual(l.text, "ldoctoru")
        guard case .syncPlayGroupUpdate(let s) = msg(GroupFixtures.waiting) else { return XCTFail() }
        XCTAssertEqual(s.state, "Waiting"); XCTAssertEqual(s.reason, "Seek")
        guard case .syncPlayGroupUpdate(let q) = msg(GroupFixtures.playQueue()) else { return XCTFail() }
        XCTAssertEqual(q.queue?.playing?.ItemId, "film42")
        XCTAssertEqual(q.queue?.playing?.PlaylistItemId, "pl-1")
        XCTAssertEqual(q.queue?.StartPositionTicks, 600_000_000)
        for (f, t) in [(GroupFixtures.groupLeft, "GroupLeft"), (GroupFixtures.notInGroup, "NotInGroup"),
                       (GroupFixtures.doesNotExist, "GroupDoesNotExist"), (GroupFixtures.accessDenied, "LibraryAccessDenied")] {
            guard case .syncPlayGroupUpdate(let x) = msg(f) else { return XCTFail(t) }
            XCTAssertEqual(x.type, t)
            XCTAssertNil(x.group); XCTAssertNil(x.queue)
        }
    }

    func testDecodesEveryCommand() {
        for c in ["Unpause", "Pause", "Seek", "Stop"] {
            guard case .syncPlayCommand(let x) = msg(GroupFixtures.command(c, when: Date())) else { return XCTFail(c) }
            XCTAssertEqual(x.Command, c)
            XCTAssertEqual(x.PositionTicks, 1_000_000_000)
            XCTAssertNotNil(TimeSync.parseDate(x.When))
        }
        guard case .syncPlayCommand(let s) = msg(GroupFixtures.command("Stop", when: Date(), ticks: nil)) else { return XCTFail() }
        XCTAssertNil(s.PositionTicks)
    }

    // MARK: Group updates

    func testJoinedUsersAndState() async {
        let rec = GroupRecorder()
        let g = joined(rec, FakeSyncPlayback())
        XCTAssertEqual(g.info?.name, "jonae's group")
        g.handle(msg(GroupFixtures.userJoined))
        XCTAssertEqual(g.info?.participants, ["jonae", "ldoctoru"])
        XCTAssertEqual(g.toast, "ldoctoru joined")
        g.handle(msg(GroupFixtures.waiting))
        XCTAssertEqual(g.info?.state, "Waiting")
        XCTAssertEqual(SyncPlayGroup.stateText("Waiting"), "Waiting for others…")
        g.handle(msg(GroupFixtures.userLeft))
        XCTAssertEqual(g.info?.participants, ["jonae"])
        XCTAssertEqual(g.toast, "ldoctoru left")
        g.handle(msg(GroupFixtures.groupLeft))
        XCTAssertEqual(g.state, .notInGroup)
        XCTAssertEqual(rec.socket.last, false)
    }

    func testGroupDoesNotExistDropsOut() {
        let rec = GroupRecorder()
        let g = joined(rec, nil)
        g.handle(msg(GroupFixtures.doesNotExist))
        XCTAssertEqual(g.state, .notInGroup)
    }

    // MARK: Scheduling

    func testPauseInTheFutureRunsAtItsTime() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = joined(rec, fake)
        let sent = Date()
        g.handle(msg(GroupFixtures.command("Pause", when: sent.addingTimeInterval(0.3))))
        XCTAssertTrue(fake.playing, "not before its time")
        let ok = await waitUntil(2) { !fake.playing }
        XCTAssertTrue(ok)
        XCTAssertGreaterThanOrEqual(fake.pausedAt?.timeIntervalSince(sent) ?? 0, 0.25)
        XCTAssertEqual(fake.ticks, 1_000_000_000, "pauses at the group's position")
    }

    func testPauseInThePastRunsNow() {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = joined(rec, fake)
        g.handle(msg(GroupFixtures.command("Pause", when: Date().addingTimeInterval(-1))))
        XCTAssertFalse(fake.playing)
    }

    func testLateUnpauseSeeksForwardByTheTimeMissed() {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        fake.playing = false
        let g = joined(rec, fake)
        g.handle(msg(GroupFixtures.command("Unpause", when: Date().addingTimeInterval(-2), ticks: 1_000_000_000)))
        XCTAssertTrue(fake.playing)
        let secs = Double(fake.ticks) / SyncPlayGroup.ticksPerSecond
        XCTAssertEqual(secs, 102, accuracy: 0.5)   // 100 s + the 2 s since When
    }

    func testCommandForAnotherGroupIsIgnored() {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = joined(rec, fake)
        g.handle(msg(GroupFixtures.command("Pause", when: Date(), group: "other")))
        XCTAssertTrue(fake.playing)
    }

    func testSeekCommandReportsBufferingThenReady() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = joined(rec, fake)
        g.handle(msg(GroupFixtures.playQueue(reason: "Queue")))   // sets the playlist entry only
        g.handle(msg(GroupFixtures.command("Seek", when: Date().addingTimeInterval(-0.01), ticks: 50_000_000)))
        XCTAssertFalse(fake.playing)
        XCTAssertEqual(fake.ticks, 50_000_000)
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/Ready") }
        XCTAssertTrue(ok)
        let p = rec.paths
        XCTAssertLessThan(p.firstIndex(of: "/SyncPlay/Buffering") ?? 99, p.firstIndex(of: "/SyncPlay/Ready") ?? -1)
        XCTAssertEqual(rec.body("/SyncPlay/Ready")?["PlaylistItemId"] as? String, "pl-1")
        XCTAssertEqual((rec.body("/SyncPlay/Ready")?["PositionTicks"] as? NSNumber)?.int64Value, 50_000_000)
    }

    // MARK: The user's own actions

    func testLocalPauseIsSentNotApplied() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        let g = joined(rec, fake)
        XCTAssertTrue(g.intercept(.pause))
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/Pause") }
        XCTAssertTrue(ok)
        XCTAssertTrue(fake.playing, "waits for the group's command")
        XCTAssertTrue(g.intercept(.seek(ticks: 42)))
        let seek = await waitUntil { rec.paths.contains("/SyncPlay/Seek") }
        XCTAssertTrue(seek)
        XCTAssertEqual((rec.body("/SyncPlay/Seek")?["PositionTicks"] as? NSNumber)?.int64Value, 42)
        XCTAssertTrue(g.intercept(.play))
        let play = await waitUntil { rec.paths.contains("/SyncPlay/Unpause") }
        XCTAssertTrue(play)
    }

    func testNotInGroupThePlayerActsItself() {
        let g = make(GroupRecorder(), FakeSyncPlayback())
        XCTAssertFalse(g.intercept(.pause))
    }

    // MARK: Join, leave, new group

    func testJoinOpensTheSocketAndLeaveClosesIt() async {
        let rec = GroupRecorder()
        let g = make(rec, FakeSyncPlayback())
        await g.join(GroupFixtures.gid)
        XCTAssertEqual(rec.socket, [true])
        XCTAssertEqual(rec.paths, ["/SyncPlay/Join"])
        XCTAssertEqual(rec.body("/SyncPlay/Join")?["GroupId"] as? String, GroupFixtures.gid)
        XCTAssertEqual(g.state, .joining)
        g.handle(msg(GroupFixtures.groupJoined))
        XCTAssertTrue(g.isInGroup)
        await g.leave()
        XCTAssertEqual(rec.socket.last, false)
        XCTAssertEqual(rec.paths.last, "/SyncPlay/Leave")
        XCTAssertEqual(g.state, .notInGroup)
    }

    func testNewGroupThenQueue() async {
        let rec = GroupRecorder()
        rec.answers["/SyncPlay/New"] = Data(GroupFixtures.groupInfo.utf8)
        let g = make(rec, nil)
        await g.create(name: "jonae's group", itemId: "film42", startTicks: 123_000_000)
        XCTAssertEqual(rec.paths, ["/SyncPlay/New", "/SyncPlay/SetNewQueue"])
        XCTAssertEqual(rec.body("/SyncPlay/New")?["GroupName"] as? String, "jonae's group")
        let q = rec.body("/SyncPlay/SetNewQueue")
        XCTAssertEqual(q?["PlayingQueue"] as? [String], ["film42"])
        XCTAssertEqual((q?["PlayingItemPosition"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((q?["StartPositionTicks"] as? NSNumber)?.int64Value, 123_000_000)
        XCTAssertTrue(rec.requests.allSatisfy { $0.post })
        XCTAssertTrue(g.isInGroup)
        XCTAssertEqual(rec.socket, [true])
    }

    func testPlayQueueOpensTheItemAndReportsReady() async {
        let rec = GroupRecorder(), fake = FakeSyncPlayback()
        fake.itemId = nil; fake.ready = false; fake.playing = false
        let g = joined(rec, fake)
        g.handle(msg(GroupFixtures.playQueue(start: 600_000_000)))
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/Ready") }
        XCTAssertTrue(ok)
        XCTAssertEqual(rec.opened.first?.0, "film42")
        XCTAssertEqual(rec.opened.first?.1 ?? 0, 60, accuracy: 0.01)
        let p = rec.paths
        XCTAssertLessThan(p.firstIndex(of: "/SyncPlay/Buffering") ?? 99, p.firstIndex(of: "/SyncPlay/Ready") ?? -1)
        let r = rec.body("/SyncPlay/Ready")
        XCTAssertEqual(r?["PlaylistItemId"] as? String, "pl-1")
        XCTAssertEqual(r?["IsPlaying"] as? Bool, false)
        XCTAssertNotNil((r?["When"] as? String).flatMap(TimeSync.parseDate))
    }

    func testPingWhileInGroup() async {
        let rec = GroupRecorder()
        _ = joined(rec, nil)
        let ok = await waitUntil { rec.requests.contains { $0.path == "/SyncPlay/Ping" } }
        XCTAssertTrue(ok)
        XCTAssertNotNil(rec.requests.first { $0.path == "/SyncPlay/Ping" }?.body?["Ping"] as? NSNumber)
    }

    // MARK: Gating

    func testUnavailableSendsNothing() async {
        let rec = GroupRecorder()
        let g = make(rec, nil, available: false)
        await g.join("x")
        await g.create(name: "n", itemId: "i", startTicks: 0)
        await g.refreshList()
        XCTAssertTrue(rec.requests.isEmpty)
        XCTAssertTrue(rec.socket.isEmpty)
        XCTAssertEqual(g.state, .notInGroup)
    }

    func testEmbyGetsNoRequests() async {
        let http = HTTPRecorder()
        let s = SyncPlayService(enabled: true, http: { try await http.handle($0) },
                                makeTransport: { _ in StubTransport() }, sleep: { _ in try await Task.sleep(nanoseconds: 30_000_000_000) },
                                log: { _ in }, liveSetting: { false })
        let c = SyncPlayService.Credentials(server: "http://emby.test:8096", token: "T", userId: "u1", deviceId: "d",
                                            authHeader: "MediaBrowser Client=\"Cove\"")
        s.update(c, isJellyfin: false)
        XCTAssertFalse(s.syncPlayAvailable)
        await s.group.join("x")
        await s.group.refreshList()
        XCTAssertFalse(s.group.intercept(.pause))
        let none = await s.send("/SyncPlay/List", body: nil, post: false)
        XCTAssertNil(none)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(http.seen.isEmpty)
        XCTAssertNil(s.socket)
    }

    func testDefaultGroupName() {
        XCTAssertEqual(SyncPlayGroup.defaultName(user: "jonae"), "jonae's group")
        XCTAssertEqual(SyncPlayGroup.watchingText(1), "1 watching")
        XCTAssertEqual(SyncPlayGroup.watchingText(3), "3 watching")
    }
}
