import Foundation
import XCTest
@testable import Cove

// SyncPlay timing: exact starts on the group's clock, Ready sooner, capabilities retried on 5xx.

@MainActor
final class TimingFakePlayback: SyncPlayPlayback {
    var ticks: Int64 = 0
    var playing = false
    var itemId: String? = "film42"
    var ready = true
    var seeking = false
    var buffered: Double = 10
    var keepUp = false
    /// The player accepts a timed start
    var canTimedStart = true
    var calls: [String] = []
    var timed: [(item: Double?, delay: TimeInterval)] = []
    var groupMode: [Bool] = []

    var syncPlayTicks: Int64 { ticks }
    var syncPlayIsPlaying: Bool { playing }
    var syncPlayItemId: String? { itemId }
    var syncPlayReady: Bool { ready }
    var syncPlaySeeking: Bool { seeking }
    var syncPlayBufferedAhead: Double { buffered }
    var syncPlayLikelyToKeepUp: Bool { keepUp }
    func syncPlayPlay() { playing = true; calls.append("play") }
    func syncPlayPause() { playing = false; calls.append("pause") }
    func syncPlaySeek(ticks: Int64) { self.ticks = ticks; calls.append("seek") }
    func syncPlaySetGroupMode(_ on: Bool) { groupMode.append(on) }
    func syncPlayPlay(atItemSeconds: Double?, hostDelay: TimeInterval) -> Bool {
        guard canTimedStart else { return false }
        timed.append((atItemSeconds, hostDelay)); playing = true; calls.append("timed")
        return true
    }
}

@MainActor
final class SyncPlayTimingTests: XCTestCase {
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

    private func group(_ rec: GroupRecorder, _ fake: TimingFakePlayback, sleep: ((TimeInterval) async throws -> Void)? = nil) -> SyncPlayGroup {
        let g = SyncPlayGroup()
        g.runsDriver = false
        g.available = { true }
        g.send = { path, body, post in
            let o = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            rec.requests.append((path, o, post))
            return rec.answers[path] ?? Data()
        }
        g.playback = { fake }
        g.opener = { id, start in rec.opened.append((id, start)) }
        g.log = { _ in }
        if let sleep { g.sleep = sleep }
        g.handle(msg(GroupFixtures.groupJoined))
        return g
    }

    // MARK: Start math

    func testOnTimeStartsFromTheCurrentPositionAtTheCommandsTime() {
        // At the command's position, 0.45 s ahead: start from here in 0.45 s, no seek
        let p = SyncPlayGroup.startPlan(positionTicks: 600_000_000, delay: 0.45, currentTicks: 600_000_000)
        XCTAssertNil(p.itemSeconds)
        XCTAssertEqual(p.hostDelay, 0.45, accuracy: 1e-9)
        // 0.2 s behind the command's position: that point of the group's timeline comes 0.2 s earlier
        let b = SyncPlayGroup.startPlan(positionTicks: 600_000_000, delay: 0.45, currentTicks: 598_000_000)
        XCTAssertNil(b.itemSeconds)
        XCTAssertEqual(b.hostDelay, 0.25, accuracy: 1e-9)
    }

    func testLateCommandJumpsAheadByTheTimeMissed() {
        let p = SyncPlayGroup.startPlan(positionTicks: 600_000_000, delay: -0.3, currentTicks: 600_000_000)
        XCTAssertEqual(p.itemSeconds ?? -1, 60.3, accuracy: 1e-9)
        XCTAssertEqual(p.hostDelay, 0)
    }

    func testFarFromThePositionSeeksThere() {
        let p = SyncPlayGroup.startPlan(positionTicks: 600_000_000, delay: 0.4, currentTicks: 0)
        XCTAssertEqual(p.itemSeconds ?? -1, 60, accuracy: 1e-9)
        XCTAssertEqual(p.hostDelay, 0.4, accuracy: 1e-9)
    }

    func testHostTimeIsAheadByTheDelay() {
        let a = PlayerModel.hostTime(after: 0).seconds
        let b = PlayerModel.hostTime(after: 0.5).seconds
        XCTAssertEqual(b - a, 0.5, accuracy: 0.05)
    }

    // MARK: Unpause

    func testUnpauseUsesTheTimedStartWithoutSleeping() async {
        let rec = GroupRecorder(), fake = TimingFakePlayback()
        fake.ticks = 1_000_000_000
        var slept: [TimeInterval] = []
        let g = group(rec, fake, sleep: { slept.append($0); try await Task.sleep(nanoseconds: 30_000_000_000) })
        XCTAssertEqual(fake.groupMode, [true])
        g.handle(msg(GroupFixtures.command("Unpause", when: Date().addingTimeInterval(0.4))))
        XCTAssertEqual(fake.timed.count, 1)
        XCTAssertNil(fake.timed.first?.item)
        XCTAssertEqual(fake.timed.first?.delay ?? 0, 0.4, accuracy: 0.1)
        XCTAssertFalse(fake.calls.contains("play"))
        XCTAssertNotNil(g.driver.anchor)
        XCTAssertFalse(slept.contains { $0 > 0.3 && $0 < 0.5 }, "no sleep until the command's time")
        g.reset()
        XCTAssertEqual(fake.groupMode, [true, false])
    }

    func testFallsBackToTheScheduledPlayWhenTheTimedStartIsNotPossible() async {
        let rec = GroupRecorder(), fake = TimingFakePlayback()
        fake.ticks = 1_000_000_000
        fake.canTimedStart = false
        let g = group(rec, fake)
        g.handle(msg(GroupFixtures.command("Unpause", when: Date().addingTimeInterval(0.05))))
        XCTAssertTrue(fake.timed.isEmpty)
        XCTAssertFalse(fake.playing)
        let ok = await waitUntil { fake.calls.contains("play") }
        XCTAssertTrue(ok)
        XCTAssertNotNil(g.driver.anchor)
    }

    func testPauseIsUnchanged() {
        let rec = GroupRecorder(), fake = TimingFakePlayback()
        fake.playing = true
        let g = group(rec, fake)
        g.handle(msg(GroupFixtures.command("Pause", when: Date().addingTimeInterval(-0.01))))
        XCTAssertEqual(fake.calls, ["pause", "seek"])
        XCTAssertTrue(fake.timed.isEmpty)
    }

    // MARK: Ready

    func testReadyConditions() {
        XCTAssertTrue(SyncPlayGroup.readyToReport(ready: true, seeking: false, bufferedAhead: 2, likelyToKeepUp: false))
        XCTAssertTrue(SyncPlayGroup.readyToReport(ready: true, seeking: false, bufferedAhead: 0.5, likelyToKeepUp: true))
        XCTAssertFalse(SyncPlayGroup.readyToReport(ready: false, seeking: false, bufferedAhead: 10, likelyToKeepUp: true))
        XCTAssertFalse(SyncPlayGroup.readyToReport(ready: true, seeking: true, bufferedAhead: 10, likelyToKeepUp: true))
        XCTAssertFalse(SyncPlayGroup.readyToReport(ready: true, seeking: false, bufferedAhead: 1.9, likelyToKeepUp: false))
    }

    func testReadyWaitsForTheSeekAndTheBuffer() async {
        let rec = GroupRecorder(), fake = TimingFakePlayback()
        fake.seeking = true; fake.buffered = 0
        let g = group(rec, fake)
        g.handle(msg(GroupFixtures.playQueue(start: 600_000_000)))
        let buffering = await waitUntil { rec.paths.contains("/SyncPlay/Buffering") }
        XCTAssertTrue(buffering)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rec.paths.contains("/SyncPlay/Ready"), "seek still running")
        fake.seeking = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rec.paths.contains("/SyncPlay/Ready"), "nothing buffered yet")
        fake.buffered = 2.5
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/Ready") }
        XCTAssertTrue(ok)
    }

    func testReadyIsSentAnywayAfterTheTimeout() async {
        let rec = GroupRecorder(), fake = TimingFakePlayback()
        fake.ready = false
        var waits = 0
        let g = group(rec, fake, sleep: { t in
            // Only the Ready polls pass at once (the ping loop waits "forever")
            guard t == SyncPlayGroup.readyPoll else { try await Task.sleep(nanoseconds: 30_000_000_000); return }
            waits += 1; await Task.yield()
        })
        g.handle(msg(GroupFixtures.playQueue(start: 600_000_000)))
        let ok = await waitUntil { rec.paths.contains("/SyncPlay/Ready") }
        XCTAssertTrue(ok)
        XCTAssertEqual(waits, Int(SyncPlayGroup.readyTimeout / SyncPlayGroup.readyPoll))
    }
}

// MARK: Capabilities retry

final class CapabilitiesHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [Int]
    private var _caps: [URLRequest] = []
    init(codes: [Int]) { self.codes = codes }
    var caps: [URLRequest] { lock.withLock { _caps } }

    func handle(_ r: URLRequest) async throws -> (Data, URLResponse) {
        let path = r.url?.path ?? ""
        var code = 404
        if path == "/Sessions/Capabilities/Full" {
            code = lock.withLock { _caps.append(r); return codes.count > 1 ? codes.removeFirst() : (codes.first ?? 204) }
        }
        return (Data(), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class SyncPlayCapabilitiesRetryTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func creds(_ token: String) -> SyncPlayService.Credentials {
        .init(server: "http://jf.test:8096", token: token, userId: "u1", deviceId: "dev-1", authHeader: #"MediaBrowser Client="Cove""#)
    }

    func testRetriesOn503UntilAccepted() async {
        let http = CapabilitiesHTTP(codes: [503, 503, 204])
        let waits = SleepRecorderBox()
        var logs: [String] = []
        let svc = SyncPlayService(enabled: true, http: http.handle, makeTransport: { _ in StubTransport() },
                                  sleep: { t in
                                      waits.add(t)
                                      // Backoff waits pass at once; the time-sync poll waits "forever"
                                      if !SyncPlayService.capabilitiesBackoff.contains(t) { try await Task.sleep(nanoseconds: 30_000_000_000) }
                                  },
                                  log: { logs.append($0) }, liveSetting: { false })
        svc.update(creds("A"), isJellyfin: true)
        let ok = await waitUntil { http.caps.count == 3 }
        XCTAssertTrue(ok)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(http.caps.count, 3, "no retry after the 204")
        XCTAssertEqual(waits.values.filter { SyncPlayService.capabilitiesBackoff.contains($0) }, [2, 4])
        XCTAssertTrue(logs.contains { $0.contains("HTTP 503 (try 1/5)") })
        XCTAssertTrue(logs.contains { $0.contains("HTTP 204 (try 3/5)") })
        svc.stop()
    }

    func testGivesUpAfterFiveTries() async {
        let http = CapabilitiesHTTP(codes: [502])
        let svc = SyncPlayService(enabled: true, http: http.handle, makeTransport: { _ in StubTransport() },
                                  sleep: { t in if !SyncPlayService.capabilitiesBackoff.contains(t) { try await Task.sleep(nanoseconds: 30_000_000_000) } },
                                  log: { _ in }, liveSetting: { false })
        svc.update(creds("A"), isJellyfin: true)
        let ok = await waitUntil { http.caps.count == 5 }
        XCTAssertTrue(ok)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(http.caps.count, 5)
        svc.stop()
    }

    func testStopsWhenTheSessionChanges() async {
        let http = CapabilitiesHTTP(codes: [503])
        let gate = SleepRecorderBox()
        let svc = SyncPlayService(enabled: true, http: http.handle, makeTransport: { _ in StubTransport() },
                                  sleep: { t in
                                      gate.add(t)
                                      if SyncPlayService.capabilitiesBackoff.contains(t) {
                                          // Hold the first backoff until the test has switched the session
                                          while !gate.released { try await Task.sleep(nanoseconds: 5_000_000) }
                                      } else { try await Task.sleep(nanoseconds: 30_000_000_000) }
                                  },
                                  log: { _ in }, liveSetting: { false })
        svc.update(creds("A"), isJellyfin: true)
        let waiting = await waitUntil { gate.values.contains(2) }
        XCTAssertTrue(waiting)
        svc.update(creds("B"), isJellyfin: true)
        gate.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let oldTries = http.caps.filter { $0.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"A\"") ?? false }
        XCTAssertEqual(oldTries.count, 1, "the old session's post isn't retried")
        svc.stop()
    }
}

final class SleepRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []
    private var _released = false
    var values: [TimeInterval] { lock.withLock { _values } }
    var released: Bool { lock.withLock { _released } }
    func add(_ t: TimeInterval) { lock.withLock { _values.append(t) } }
    func release() { lock.withLock { _released = true } }
}
