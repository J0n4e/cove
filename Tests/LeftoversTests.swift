import XCTest
@testable import Cove

/// v1.19.0 part 3 (leftovers from v1.18.4): badge rollback, season / episode badges, live Now Playing on Jellyfin.
@MainActor
final class LeftoversTests: XCTestCase {
    static let host = "https://leftovers.test"

    override class func setUp() {
        super.setUp()
        ServerStub.install()
    }
    override func setUp() async throws { ServerStub.reset() }
    override func tearDown() async throws { ServerStub.reset() }

    private func emby() -> Emby {
        let e = Emby()
        e.server = Self.host; e.token = "tok"; e.userId = "u1"; e.isJellyfin = true
        return e
    }

    // MARK: Rollback

    func testAccepted() {
        XCTAssertTrue(BadgeRollback.accepted(200))
        XCTAssertTrue(BadgeRollback.accepted(204))
        XCTAssertFalse(BadgeRollback.accepted(500))
        XCTAssertFalse(BadgeRollback.accepted(404))
        XCTAssertFalse(BadgeRollback.accepted(nil))
        XCTAssertEqual(BadgeRollback.failureText, "Couldn\u{2019}t update \u{2014} try again")
        XCTAssertNotEqual(BadgeRollback.failureToast.id, BadgeRollback.failureToast.id)
    }

    func testFavSuccessKeepsState() async {
        ServerStub.on("/Users/u1/FavoriteItems/i1", .status(200))
        let e = emby()
        let ok = await e.setFavChecked("i1", true, name: "Film")
        XCTAssertTrue(ok)
        XCTAssertEqual(e.faved["i1"], true)
        XCTAssertNotEqual(e.toast?.text, BadgeRollback.failureText)
        XCTAssertEqual(ServerStub.requests.last?.method, "POST")
    }

    func testFavFailureRollsBack() async {
        ServerStub.on("/Users/u1/FavoriteItems/i1", .status(500))
        let e = emby()
        e.faved["i1"] = false
        let ok = await e.setFavChecked("i1", true, name: "Film")
        XCTAssertFalse(ok)
        XCTAssertEqual(e.faved["i1"], false)
        XCTAssertEqual(e.toast?.text, BadgeRollback.failureText)
    }

    func testPlayedSuccessAndFailure() async {
        ServerStub.on("/Users/u1/PlayedItems/s1", .status(204))
        let e = emby()
        let ok = await e.setPlayedChecked("s1", true)
        XCTAssertTrue(ok)
        XCTAssertEqual(e.played["s1"], true)

        ServerStub.on("/Users/u1/PlayedItems/s1", .status(500))
        e.positions["s1"] = 120
        let bad = await e.setPlayedChecked("s1", false)
        XCTAssertFalse(bad)
        XCTAssertEqual(e.played["s1"], true, "back to watched")
        XCTAssertEqual(e.toast?.text, BadgeRollback.failureText)
    }

    func testUnreachableRollsBack() async {
        ServerStub.on("/Users/u1/PlayedItems/x", .fail(.cannotConnectToHost))
        let e = emby()
        let ok = await e.setPlayedChecked("x", true)
        XCTAssertFalse(ok)
        XCTAssertNil(e.played["x"])
    }

    func testOldSignatureDoesNotRollBack() async {
        ServerStub.on("/Users/u1/FavoriteItems/i2", .status(500))
        let e = emby()
        await e.setFav("i2", true)
        XCTAssertEqual(e.faved["i2"], true, "other callers keep their behaviour")
        XCTAssertNotEqual(e.toast?.text, BadgeRollback.failureText)
    }

    // MARK: Season / episode badges

    func testSeasonAndEpisodeBadgeRules() {
        XCTAssertEqual(ItemBadgeRules.badges(.season), ["fav", "watched"])
        XCTAssertEqual(ItemBadgeRules.badges(.episode), ["fav", "watched"])
        XCTAssertFalse(ItemBadgeRules.favAtTopRight(.season))
        XCTAssertTrue(ItemBadgeRules.favAtTopRight(.episode))
        XCTAssertEqual(ItemBadgeRules.unwatched(.season, played: false, count: 7), 7)
        XCTAssertEqual(ItemBadgeRules.unwatched(.season, played: true, count: 7), 0)
        XCTAssertEqual(ItemBadgeRules.unwatched(.episode, played: false, count: 7), 0)
        // Watched episode: ✓ filled; unwatched: outline only on hover
        XCTAssertEqual(PosterBadges.watchedContent(played: true, unwatched: 0, hover: false)?.outline, false)
        XCTAssertEqual(PosterBadges.watchedContent(played: false, unwatched: 0, hover: false)?.outline, true)
        XCTAssertEqual(PosterBadges.watchedContent(played: false, unwatched: 3, hover: false)?.text, "3")
    }

    // MARK: Now Playing live

    static let sessionsMessage = #"""
    {"MessageType":"Sessions","MessageId":"m1","Data":[
     {"Id":"b","UserName":"zoe","Client":"Jellyfin Web","PlayState":{"PositionTicks":600000000,"IsPaused":true,"PlayMethod":"DirectPlay"},
      "NowPlayingItem":{"Id":"e1","Name":"Pilot","SeriesName":"Show","RunTimeTicks":30000000000,"Type":"Episode"}},
     {"Id":"a","UserName":"anna","Client":"Cove","PlayState":{"PositionTicks":10,"IsPaused":false},
      "NowPlayingItem":{"Id":"m1","Name":"Film","RunTimeTicks":60000000000,"Type":"Movie"}},
     {"Id":"c","UserName":"idle","Client":"Android"}
    ]}
    """#

    func testSessionsMessageDecodes() throws {
        let env = try XCTUnwrap(SocketEnvelope.decode(Self.sessionsMessage))
        guard case .sessions(let live) = env.message else { return XCTFail("not decoded as Sessions") }
        XCTAssertEqual(live.list.count, 3)
        let shown = Emby.playingSessions(live.list)
        XCTAssertEqual(shown.map { $0.Id }, ["a", "b"], "only playing, sorted by user")
        XCTAssertEqual(shown[1].PlayState?.IsPaused, true)
        XCTAssertEqual(shown[1].NowPlayingItem?.Name, "Pilot")
    }

    func testOtherMessagesUnchanged() {
        XCTAssertEqual(SocketEnvelope.decode(#"{"MessageType":"UserDataChanged","Data":{}}"#)?.message, .other("UserDataChanged"))
        XCTAssertEqual(SocketEnvelope.decode(#"{"MessageType":"KeepAlive"}"#)?.message, .keepAlive)
    }

    func testStartStopText() throws {
        let start = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NowPlayingLive.startText.utf8)) as? [String: String])
        XCTAssertEqual(start, ["MessageType": "SessionsStart", "Data": "0,1500"])
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NowPlayingLive.stopText.utf8)) as? [String: String])
        XCTAssertEqual(stop["MessageType"], "SessionsStop")
    }

    func testSourceSelection() {
        XCTAssertEqual(NowPlayingLive.source(isJellyfin: true, liveSetting: true, socketConnected: true), .socket)
        XCTAssertEqual(NowPlayingLive.source(isJellyfin: false, liveSetting: true, socketConnected: true), .polling)
        XCTAssertEqual(NowPlayingLive.source(isJellyfin: true, liveSetting: false, socketConnected: true), .polling)
        XCTAssertEqual(NowPlayingLive.source(isJellyfin: true, liveSetting: true, socketConnected: false), .polling)
        let now = Date()
        XCTAssertTrue(NowPlayingLive.shouldPoll(.polling, lastPush: now, now: now))
        XCTAssertTrue(NowPlayingLive.shouldPoll(.socket, lastPush: nil, now: now), "until the first push")
        XCTAssertFalse(NowPlayingLive.shouldPoll(.socket, lastPush: now.addingTimeInterval(-2), now: now))
        XCTAssertTrue(NowPlayingLive.shouldPoll(.socket, lastPush: now.addingTimeInterval(-11), now: now), "pushes stopped")
        XCTAssertEqual(NowPlayingLive.pollInterval, 5)
    }

    func testServerSocketSendsTextAndForwardsSessions() async {
        let t = LeftoversTransport()
        let s = ServerSocket(request: URLRequest(url: URL(string: "wss://x.test/socket")!), makeTransport: { _ in t },
                             sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000_000) })
        var got: [ActiveSession] = []
        s.onSessions = { got = $0 }
        let before = await s.sendText(NowPlayingLive.startText)
        XCTAssertFalse(before, "not connected yet")
        s.start()
        for _ in 0..<100 where !s.connected { try? await Task.sleep(for: .milliseconds(20)) }
        let ok = await s.sendText(NowPlayingLive.startText)
        XCTAssertTrue(ok)
        XCTAssertTrue(t.sent.contains(NowPlayingLive.startText))
        t.push(Self.sessionsMessage)
        for _ in 0..<100 where got.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(got.count, 3)
        s.stop()
    }
}

/// A socket transport that opens at once and hands out pushed messages.
private final class LeftoversTransport: SocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String] = []
    private var _sent: [String] = []
    var sent: [String] { lock.withLock { _sent } }
    func push(_ s: String) { lock.withLock { queue.append(s) } }
    func open() async throws {}
    func send(_ text: String) async throws { lock.withLock { _sent.append(text) } }
    func receive() async throws -> String {
        while true {
            try Task.checkCancellation()
            if let m: String = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) { return m }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func close() {}
}
