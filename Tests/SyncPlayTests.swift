import XCTest
@testable import Cove

// SyncPlay phase 1: time sync math, socket messages, keep-alive, reconnects, the socket link, and that Emby
// servers get nothing. Fixtures are shaped like Jellyfin's own JSON (PascalCase, .NET dates with 7 digits).

/// A socket that never touches the network: replays `inbox`, then waits until it is closed or cancelled.
final class StubTransport: SocketTransport {
    private let lock = NSLock()
    private var inbox: [String]
    private var _sent: [String] = []
    private var closed = false
    let failOpen: Bool

    init(inbox: [String] = [], failOpen: Bool = false) { self.inbox = inbox; self.failOpen = failOpen }

    var sent: [String] { lock.withLock { _sent } }

    func open() async throws { if failOpen { throw URLError(.cannotConnectToHost) } }
    func send(_ text: String) async throws { lock.withLock { _sent.append(text) } }
    func receive() async throws -> String {
        while true {
            let next: String?? = lock.withLock {
                if closed { return .some(nil) }
                return inbox.isEmpty ? nil : .some(inbox.removeFirst())
            }
            switch next {
            case .some(.some(let m)): return m
            case .some(.none): throw URLError(.networkConnectionLost)
            case .none: try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
    func close() { lock.withLock { closed = true } }
}

/// Records requests and answers them by path.
final class HTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [URLRequest] = []
    var answers: [String: String] = [:]
    var seen: [URLRequest] { lock.withLock { _seen } }
    var paths: [String] { seen.compactMap { $0.url?.path } }

    func handle(_ r: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _seen.append(r) }
        let path = r.url?.path ?? ""
        let body = answers[path]
        let resp = HTTPURLResponse(url: r.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        return (Data((body ?? "").utf8), resp)
    }
}

/// Records every wait it is asked for, then either returns at once (up to `returnFor` times) or waits "forever".
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [TimeInterval] = []
    let returnFor: Int
    let throwAfter: Int?
    init(returnFor: Int = 0, throwAfter: Int? = nil) { self.returnFor = returnFor; self.throwAfter = throwAfter }
    var waits: [TimeInterval] { lock.withLock { _waits } }

    func sleep(_ t: TimeInterval) async throws {
        let n = lock.withLock { _waits.append(t); return _waits.count }
        if let k = throwAfter, n >= k { throw CancellationError() }
        if n <= returnFor { return }
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
}

enum SyncPlayFixtures {
    static let forceKeepAlive = #"{"MessageType":"ForceKeepAlive","Data":40,"MessageId":"3c2b5a0e-8f3a-4d2b-9a51-0d0f3c1b7e11"}"#
    static let keepAlive = #"{"MessageType":"KeepAlive","MessageId":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}"#
    static let command = #"""
    {"MessageType":"SyncPlayCommand","MessageId":"7d3b2c1a-0000-4000-8000-000000000001","Data":{"GroupId":"a1b2c3d4-0000-4000-8000-00000000000a","PlaylistItemId":"b1b2c3d4-0000-4000-8000-00000000000b","When":"2026-11-16T10:00:05.1234567Z","PositionTicks":123450000,"Command":"Unpause","EmittedAt":"2026-11-16T10:00:04.9000000Z"}}
    """#
    static let userJoined = #"""
    {"MessageType":"SyncPlayGroupUpdate","MessageId":"7d3b2c1a-0000-4000-8000-000000000002","Data":{"GroupId":"a1b2c3d4-0000-4000-8000-00000000000a","Type":"UserJoined","Data":"alice"}}
    """#
    static let stateUpdate = #"""
    {"MessageType":"SyncPlayGroupUpdate","MessageId":"7d3b2c1a-0000-4000-8000-000000000003","Data":{"GroupId":"a1b2c3d4-0000-4000-8000-00000000000a","Type":"StateUpdate","Data":{"State":"Waiting","Reason":"Buffer"}}}
    """#
    static let groupJoined = #"""
    {"MessageType":"SyncPlayGroupUpdate","MessageId":"7d3b2c1a-0000-4000-8000-000000000004","Data":{"GroupId":"a1b2c3d4-0000-4000-8000-00000000000a","Type":"GroupJoined","Data":{"GroupId":"a1b2c3d4-0000-4000-8000-00000000000a","GroupName":"Movie night","State":"Idle","Participants":["alice","bob"],"LastUpdatedAt":"2026-11-16T10:00:00.0000000Z"}}}
    """#
    static let playstate = #"""
    {"MessageType":"Playstate","MessageId":"7d3b2c1a-0000-4000-8000-000000000005","Data":{"Command":"Pause","ControllingUserId":"c0ffee00000040008000000000000001"}}
    """#
    static let utcTime = #"{"RequestReceptionTime":"2026-11-16T10:00:00.5000000Z","ResponseTransmissionTime":"2026-11-16T10:00:00.5001000Z"}"#
    static let publicInfo = #"{"LocalAddress":"http://192.168.1.2:8096","ServerName":"Home","Version":"10.10.3","ProductName":"Jellyfin Server","Id":"abc","StartupWizardCompleted":true}"#
    static let user = #"{"Name":"jonas","Id":"u1","Policy":{"IsAdministrator":true,"SyncPlayAccess":"CreateAndJoinGroups"}}"#
}

@MainActor
final class SyncPlayTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private let creds = SyncPlayService.Credentials(server: "http://jf.test:8096", token: "SECRET-TOKEN-123", userId: "u1",
                                                    deviceId: "dev-1", authHeader: #"MediaBrowser Client="Cove", Device="Mac", DeviceId="dev-1", Version="1.0""#)

    // MARK: time sync

    func testOffsetAndDelay() {
        let s = TimeSample(t0: Date(timeIntervalSince1970: 100), t1: Date(timeIntervalSince1970: 105),
                           t2: Date(timeIntervalSince1970: 105.5), t3: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(s.offset, 4.75, accuracy: 1e-9)   // ((105-100) + (105.5-101)) / 2
        XCTAssertEqual(s.delay, 0.5, accuracy: 1e-9)     // (101-100) - (105.5-105)
    }

    private func sample(offset: TimeInterval, delay: TimeInterval, at t: TimeInterval) -> TimeSample {
        // Symmetric path: the server is `offset` ahead, the network takes delay/2 each way, no processing time
        TimeSample(t0: Date(timeIntervalSince1970: t), t1: Date(timeIntervalSince1970: t + delay / 2 + offset),
                   t2: Date(timeIntervalSince1970: t + delay / 2 + offset), t3: Date(timeIntervalSince1970: t + delay))
    }

    func testBestSampleIsLowestDelayInLastEight() {
        var ts = TimeSync()
        XCTAssertFalse(ts.isReady)
        XCTAssertEqual(ts.offset, 0)
        ts.add(sample(offset: 9, delay: 0.001, at: 0))                // the best, but it falls out of the window
        for i in 1...8 { ts.add(sample(offset: Double(i), delay: 0.1 * Double(i), at: Double(i))) }
        XCTAssertEqual(ts.samples.count, 8)
        XCTAssertEqual(ts.best?.delay ?? -1, 0.1, accuracy: 1e-6)
        XCTAssertEqual(ts.offset, 1, accuracy: 1e-6)
        let local = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ts.serverNow(local: local).timeIntervalSince1970, 1001, accuracy: 1e-6)
        XCTAssertEqual(ts.localDate(forServer: Date(timeIntervalSince1970: 1001)).timeIntervalSince1970, 1000, accuracy: 1e-6)
    }

    func testPollSchedule() {
        XCTAssertEqual((0...5).map { TimeSync.pollInterval(afterPings: $0) }, [1, 1, 1, 60, 60, 60])
    }

    func testDotNetDatesAndUtcTimeResponse() throws {
        let d = try XCTUnwrap(TimeSync.parseDate("2026-11-16T10:00:00.1234567Z"))
        let whole = try XCTUnwrap(TimeSync.parseDate("2026-11-16T10:00:00Z"))
        XCTAssertEqual(d.timeIntervalSince(whole), 0.1234567, accuracy: 1e-6)
        XCTAssertEqual(TimeSync.parseDate("2026-11-16T10:00:00.5"), whole.addingTimeInterval(0.5))
        XCTAssertEqual(TimeSync.parseDate("2026-11-16T10:00:00"), whole)          // no zone = UTC
        XCTAssertNil(TimeSync.parseDate("yesterday"))

        let r = try JSONDecoder().decode(UtcTimeResponse.self, from: Data(SyncPlayFixtures.utcTime.utf8))
        let t0 = whole.addingTimeInterval(-0.5), t3 = whole.addingTimeInterval(0.7)
        let s = try XCTUnwrap(r.sample(sent: t0, received: t3))
        XCTAssertEqual(s.delay, 1.2 - 0.0001, accuracy: 1e-6)
        XCTAssertEqual(s.offset, (1.0 + (0.5001 - 0.7)) / 2, accuracy: 1e-6)
    }

    // MARK: socket messages

    func testEnvelopeDecoding() throws {
        func msg(_ s: String) throws -> SocketMessage { try XCTUnwrap(SocketEnvelope.decode(s)).message }
        XCTAssertEqual(try msg(SyncPlayFixtures.forceKeepAlive), .forceKeepAlive(timeout: 40))
        XCTAssertEqual(SocketEnvelope.decode(SyncPlayFixtures.forceKeepAlive)?.messageId, "3c2b5a0e-8f3a-4d2b-9a51-0d0f3c1b7e11")
        XCTAssertEqual(try msg(SyncPlayFixtures.keepAlive), .keepAlive)
        XCTAssertEqual(try msg(SyncPlayFixtures.playstate), .other("Playstate"))
        XCTAssertNil(SocketEnvelope.decode("not json"))

        guard case .syncPlayCommand(let c) = try msg(SyncPlayFixtures.command) else { return XCTFail("command") }
        XCTAssertEqual(c.Command, "Unpause")
        XCTAssertEqual(c.PositionTicks, 123_450_000)
        XCTAssertNotNil(TimeSync.parseDate(c.When))

        guard case .syncPlayGroupUpdate(let j) = try msg(SyncPlayFixtures.userJoined) else { return XCTFail("joined") }
        XCTAssertEqual(j.type, "UserJoined"); XCTAssertEqual(j.text, "alice"); XCTAssertNil(j.state)

        guard case .syncPlayGroupUpdate(let s) = try msg(SyncPlayFixtures.stateUpdate) else { return XCTFail("state") }
        XCTAssertEqual(s.type, "StateUpdate"); XCTAssertEqual(s.state, "Waiting"); XCTAssertEqual(s.reason, "Buffer")

        guard case .syncPlayGroupUpdate(let g) = try msg(SyncPlayFixtures.groupJoined) else { return XCTFail("group") }
        XCTAssertEqual(g.type, "GroupJoined"); XCTAssertEqual(g.state, "Idle"); XCTAssertNil(g.text)
    }

    func testKeepAliveAnswersForceKeepAliveAndRepeatsEveryHalfTimeout() async throws {
        let t = StubTransport(inbox: [SyncPlayFixtures.forceKeepAlive, SyncPlayFixtures.command, SyncPlayFixtures.playstate])
        let sleeps = SleepRecorder()
        let r = try XCTUnwrap(ServerSocket.request(server: "http://jf.test", deviceId: "d", authorization: "x"))
        let s = ServerSocket(request: r, makeTransport: { _ in t }, sleep: sleeps.sleep)
        var got: [SocketMessage] = []
        s.onMessage = { got.append($0) }
        s.start()
        let ok = await waitUntil { t.sent.contains(ServerSocket.keepAliveText) && sleeps.waits.contains(20) && !got.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertTrue(s.connected)
        XCTAssertEqual(s.keepAliveInterval, 20)
        XCTAssertEqual(got.count, 1)                    // only SyncPlay messages are passed on
        s.stop()
        XCTAssertFalse(s.connected)
    }

    func testKeepAliveLoopSendsOnSchedule() async throws {
        let t = StubTransport()
        let sleeps = SleepRecorder(returnFor: 2)        // two intervals pass at once, the third waits
        let r = try XCTUnwrap(ServerSocket.request(server: "http://jf.test", deviceId: "d", authorization: "x"))
        let s = ServerSocket(request: r, makeTransport: { _ in t }, sleep: sleeps.sleep)
        s.start()
        let ok = await waitUntil { t.sent.count == 2 && sleeps.waits.count == 3 }
        XCTAssertTrue(ok)
        XCTAssertEqual(sleeps.waits, [30, 30, 30])
        XCTAssertEqual(t.sent, [ServerSocket.keepAliveText, ServerSocket.keepAliveText])
        s.stop()
    }

    func testReconnectBackoff() async throws {
        XCTAssertEqual((0...8).map { ServerSocket.backoff(attempt: $0) }, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        var made = 0
        let sleeps = SleepRecorder(returnFor: 100, throwAfter: 8)
        let r = try XCTUnwrap(ServerSocket.request(server: "http://jf.test", deviceId: "d", authorization: "x"))
        let s = ServerSocket(request: r, makeTransport: { _ in made += 1; return StubTransport(failOpen: true) }, sleep: sleeps.sleep)
        s.start()
        let ok = await waitUntil { sleeps.waits.count == 8 }
        XCTAssertTrue(ok)
        XCTAssertEqual(sleeps.waits, [1, 2, 4, 8, 16, 32, 60, 60])
        XCTAssertEqual(made, 8)
        s.stop()
    }

    // MARK: socket link

    func testSocketURL() throws {
        let a = try XCTUnwrap(ServerSocket.request(server: "http://jf.test:8096", deviceId: "dev-1", authorization: "MediaBrowser Token=\"T0K\""))
        XCTAssertEqual(a.url?.absoluteString, "ws://jf.test:8096/socket?deviceId=dev-1")
        XCTAssertEqual(a.value(forHTTPHeaderField: "Authorization"), "MediaBrowser Token=\"T0K\"")
        let b = try XCTUnwrap(ServerSocket.request(server: "https://jf.test/jellyfin/", deviceId: "d", authorization: "x"))
        XCTAssertEqual(b.url?.absoluteString, "wss://jf.test/jellyfin/socket?deviceId=d")
        XCTAssertFalse(a.url!.absoluteString.contains("T0K"))
        XCTAssertFalse(a.url!.absoluteString.lowercased().contains("api_key"))

        XCTAssertNil(ServerSocket.request(server: "ftp://jf.test", deviceId: "d", authorization: "x"))
        XCTAssertNil(ServerSocket.request(server: "http://", deviceId: "d", authorization: "x"))
        XCTAssertNil(ServerSocket.request(server: "", deviceId: "d", authorization: "x"))
        let server = URL(string: "http://good.test:8096")!
        XCTAssertTrue(ServerSocket.sameOrigin(ws: URL(string: "ws://good.test:8096/socket")!, server: server))
        XCTAssertFalse(ServerSocket.sameOrigin(ws: URL(string: "ws://evil.test:8096/socket")!, server: server))
        XCTAssertFalse(ServerSocket.sameOrigin(ws: URL(string: "wss://good.test:8096/socket")!, server: server))
        XCTAssertFalse(ServerSocket.sameOrigin(ws: URL(string: "ws://good.test:9000/socket")!, server: server))
        XCTAssertFalse(ServerSocket.sameOrigin(ws: URL(string: "http://good.test:8096/socket")!, server: server))
    }

    // MARK: service

    func testJellyfinConnectsPostsCapabilitiesAndNeverLogsToken() async throws {
        let http = HTTPRecorder()
        http.answers = ["/System/Info/Public": SyncPlayFixtures.publicInfo, "/Users/u1": SyncPlayFixtures.user,
                        "/GetUtcTime": SyncPlayFixtures.utcTime, "/Sessions/Capabilities/Full": ""]
        var requests: [URLRequest] = []
        var logs: [String] = []
        let sleeps = SleepRecorder()
        let svc = SyncPlayService(enabled: true, http: http.handle,
                                  makeTransport: { requests.append($0); return StubTransport() },
                                  sleep: sleeps.sleep, log: { logs.append($0) })
        svc.update(creds, isJellyfin: true)
        let ok = await waitUntil { svc.connected && http.paths.contains("/Sessions/Capabilities/Full")
            && svc.syncPlayAccess != nil && svc.timeSync.isReady }
        XCTAssertTrue(ok)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, "ws://jf.test:8096/socket?deviceId=dev-1")
        XCTAssertTrue(requests.first?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"SECRET-TOKEN-123\"") ?? false)

        let caps = try XCTUnwrap(http.seen.first { $0.url?.path == "/Sessions/Capabilities/Full" })
        XCTAssertEqual(caps.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: caps.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["PlayableMediaTypes"] as? [String], ["Video", "Audio"])
        XCTAssertEqual(body["SupportsMediaControl"] as? Bool, true)
        XCTAssertTrue((body["SupportedCommands"] as? [String])?.contains("PlayState") ?? false)

        XCTAssertEqual(svc.serverVersion, "10.10.3")
        XCTAssertEqual(svc.syncPlayAccess, "CreateAndJoinGroups")
        XCTAssertTrue(svc.syncPlayAvailable)

        // Same session again: nothing restarts
        svc.update(creds, isJellyfin: true)
        XCTAssertEqual(requests.count, 1)

        XCTAssertFalse(logs.isEmpty)
        for l in logs {
            XCTAssertFalse(l.contains("SECRET-TOKEN-123"), l)
            XCTAssertFalse(l.contains("deviceId="), l)
        }
        XCTAssertFalse(http.seen.contains { $0.url?.absoluteString.contains("SECRET-TOKEN-123") ?? false })

        svc.update(nil, isJellyfin: true)                          // sign-out
        XCTAssertFalse(svc.connected)
        XCTAssertNil(svc.socket)
        XCTAssertFalse(svc.syncPlayAvailable)
    }

    func testEmbyGetsNoSocketAndNoCapabilities() async throws {
        let http = HTTPRecorder()
        var made = 0
        let svc = SyncPlayService(enabled: true, http: http.handle,
                                  makeTransport: { _ in made += 1; return StubTransport() },
                                  sleep: SleepRecorder().sleep, log: { _ in })
        svc.update(creds, isJellyfin: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(made, 0)
        XCTAssertTrue(http.seen.isEmpty)
        XCTAssertNil(svc.socket)
        XCTAssertFalse(svc.syncPlayAvailable)

        // A Jellyfin session that then turns out to be Emby stops everything
        svc.update(creds, isJellyfin: true)
        let ok = await waitUntil { svc.connected }
        XCTAssertTrue(ok)
        svc.update(creds, isJellyfin: false)
        XCTAssertNil(svc.socket)
        XCTAssertFalse(svc.connected)
    }

    func testEmbyObjectDoesNotStartSyncPlayInTests() {
        // The app's own service is switched off inside the test runner (no sockets from other test classes)
        let e = Emby()
        XCTAssertNil(e.syncPlay.socket)
    }

    func testAvailability() {
        XCTAssertTrue(SyncPlayService.available(version: "10.8.0", access: "JoinGroups"))
        XCTAssertTrue(SyncPlayService.available(version: "10.10.3", access: "CreateAndJoinGroups"))
        XCTAssertTrue(SyncPlayService.available(version: "11.0.0", access: "JoinGroups"))
        XCTAssertFalse(SyncPlayService.available(version: "10.7.7", access: "CreateAndJoinGroups"))
        XCTAssertFalse(SyncPlayService.available(version: "10.10.3", access: "None"))
        XCTAssertFalse(SyncPlayService.available(version: nil, access: "JoinGroups"))
        XCTAssertFalse(SyncPlayService.available(version: "10.9.0", access: nil))
    }

    // MARK: live connection setting

    func testLiveConnectionOffOpensNoSocketUntilNeededOrSwitchedOn() async throws {
        let http = HTTPRecorder()
        http.answers = ["/System/Info/Public": SyncPlayFixtures.publicInfo, "/Users/u1": SyncPlayFixtures.user,
                        "/GetUtcTime": SyncPlayFixtures.utcTime, "/Sessions/Capabilities/Full": ""]
        var made = 0
        var live = false
        let svc = SyncPlayService(enabled: true, http: http.handle,
                                  makeTransport: { _ in made += 1; return StubTransport() },
                                  sleep: SleepRecorder().sleep, log: { _ in }, liveSetting: { live })
        // Off: sign-in opens no socket, but capabilities, server info and time sync still run
        svc.update(creds, isJellyfin: true)
        let ok = await waitUntil { http.paths.contains("/Sessions/Capabilities/Full") && svc.syncPlayAccess != nil }
        XCTAssertTrue(ok)
        XCTAssertNil(svc.socket)
        XCTAssertEqual(made, 0)

        // SyncPlay joins a group: the socket opens; leaving closes it
        svc.setSocketNeeded(true)
        XCTAssertNotNil(svc.socket)
        XCTAssertEqual(made, 1)
        let up = await waitUntil { svc.connected }
        XCTAssertTrue(up)
        svc.setSocketNeeded(false)
        XCTAssertNil(svc.socket)
        XCTAssertFalse(svc.connected)

        // Switching the setting on starts the socket right away; off again closes it
        live = true
        svc.liveSettingChanged()
        XCTAssertNotNil(svc.socket)
        XCTAssertEqual(made, 2)
        live = false
        svc.liveSettingChanged()
        XCTAssertNil(svc.socket)
    }

    func testLiveConnectionDefaultsOn() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: SyncPlayService.liveSocketKey)
        d.removeObject(forKey: SyncPlayService.liveSocketKey)
        XCTAssertTrue(SyncPlayService.liveSocketDefault())
        d.set(false, forKey: SyncPlayService.liveSocketKey)
        XCTAssertFalse(SyncPlayService.liveSocketDefault())
        if let saved { d.set(saved, forKey: SyncPlayService.liveSocketKey) } else { d.removeObject(forKey: SyncPlayService.liveSocketKey) }
    }
}
