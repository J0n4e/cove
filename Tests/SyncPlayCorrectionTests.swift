import XCTest
@testable import Cove

// SyncPlay phase 3: drift correction (jellyfin-web PlaybackCore.syncPlaybackTime thresholds), mid-playback
// Buffering / Ready, rejoin after a reconnect, and "Don't wait for others" (SetIgnoreWait).

@MainActor
final class DriftFakePlayback: SyncPlayPlayback {
    var ticks: Int64 = 0
    var playing = false
    var itemId: String? = "film42"
    var ready = true
    var stalled = false
    var rates: [Double] = []
    var seeks: [Int64] = []

    var syncPlayTicks: Int64 { ticks }
    var syncPlayIsPlaying: Bool { playing }
    var syncPlayItemId: String? { itemId }
    var syncPlayReady: Bool { ready }
    var syncPlayStalled: Bool { stalled }
    func syncPlayPlay() { playing = true }
    func syncPlayPause() { playing = false }
    func syncPlaySeek(ticks: Int64) { self.ticks = ticks; seeks.append(ticks) }
    func syncPlaySetRate(_ rate: Double) { rates.append(rate) }
}

@MainActor
final class SyncPlayCorrectionTests: XCTestCase {
    typealias A = SyncCorrection.Action
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let pos: Int64 = 6_000_000_000   // 10 min
    let sec: Int64 = 10_000_000

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

    private func rate(_ a: A) -> Double? { if case .speed(let r, _) = a { return r }; return nil }
    private func duration(_ a: A) -> Double? { if case .speed(_, let d) = a { return d }; return nil }

    // MARK: Pure decision

    func testDecisionTableAtTheEdges() {
        let e: Int64 = 123_456
        XCTAssertEqual(SyncCorrection.decide(delayMs: 0, expectedTicks: e), .none)
        XCTAssertEqual(SyncCorrection.decide(delayMs: 59.9, expectedTicks: e), .none)
        XCTAssertEqual(SyncCorrection.decide(delayMs: -59.9, expectedTicks: e), .none)
        let a = SyncCorrection.decide(delayMs: 60, expectedTicks: e)
        XCTAssertEqual(rate(a) ?? 0, 1.06, accuracy: 1e-9); XCTAssertEqual(duration(a) ?? 0, 1.0, accuracy: 1e-9)
        let b = SyncCorrection.decide(delayMs: -60, expectedTicks: e)
        XCTAssertEqual(rate(b) ?? 0, 0.94, accuracy: 1e-9); XCTAssertEqual(duration(b) ?? 0, 1.0, accuracy: 1e-9)
        // Behind a lot: 2× for long enough to recover all of it
        let c = SyncCorrection.decide(delayMs: 2999, expectedTicks: e)
        XCTAssertEqual(rate(c) ?? 0, 2.0, accuracy: 1e-9); XCTAssertEqual(duration(c) ?? 0, 2.999, accuracy: 1e-9)
        // Ahead: never below 0.5×, stretched
        let d = SyncCorrection.decide(delayMs: -600, expectedTicks: e)
        XCTAssertEqual(rate(d) ?? 0, 0.5, accuracy: 1e-9); XCTAssertEqual(duration(d) ?? 0, 1.2, accuracy: 1e-9)
        // From maxDelaySpeedToSync on: skip
        XCTAssertEqual(SyncCorrection.decide(delayMs: 3000, expectedTicks: e), .skip(ticks: e))
        XCTAssertEqual(SyncCorrection.decide(delayMs: -3000, expectedTicks: e), .skip(ticks: e))
        XCTAssertEqual(SyncCorrection.decide(delayMs: 5000, expectedTicks: -5), .skip(ticks: 0))
        // Without SpeedToSync: skip only from 400 ms
        var s = SyncCorrection.Settings.web; s.useSpeedToSync = false
        XCTAssertEqual(SyncCorrection.decide(delayMs: 399, expectedTicks: e, settings: s), .none)
        XCTAssertEqual(SyncCorrection.decide(delayMs: 400, expectedTicks: e, settings: s), .skip(ticks: e))
        s.useSkipToSync = false
        XCTAssertEqual(SyncCorrection.decide(delayMs: 5000, expectedTicks: e, settings: s), .none)
        XCTAssertEqual(SyncCorrection.Settings.web.checkInterval, 1.5)
    }

    func testExpectedPositionMath() {
        XCTAssertEqual(SyncCorrection.expectedTicks(positionTicks: pos, when: t0, serverNow: t0.addingTimeInterval(2.5)),
                       pos + 25_000_000)
        XCTAssertEqual(SyncCorrection.expectedTicks(positionTicks: pos, when: t0, serverNow: t0), pos)
        XCTAssertEqual(SyncCorrection.delayMs(expected: pos + sec, current: pos), 1000)
        XCTAssertEqual(SyncCorrection.delayMs(expected: pos, current: pos + sec / 2), -500)
    }

    // MARK: Driver

    private func anchored() -> SyncDriver {
        var d = SyncDriver()
        d.unpaused(.init(positionTicks: pos, when: t0, playlistItemId: "pl-1", appliedAt: t0))
        return d
    }

    private func step(_ d: inout SyncDriver, at s: TimeInterval, ticks: Int64, playing: Bool = true,
                      stalled: Bool = false, busy: Bool = false) -> [SyncDriver.Output] {
        let n = t0.addingTimeInterval(s)
        return d.step(now: n, serverNow: n, ticks: ticks, playing: playing, stalled: stalled, busy: busy, playlistItemId: "pl-1")
    }

    func testNoCorrectionInTheFirstSecondsOrWhilePausedOrSeeking() {
        var d = anchored()
        // 1 s behind, but within the 1.5 s after the Unpause
        XCTAssertEqual(step(&d, at: 1.0, ticks: pos), [])
        XCTAssertEqual(step(&d, at: 2.0, ticks: pos, playing: false), [])
        XCTAssertEqual(step(&d, at: 2.0, ticks: pos, busy: true), [])
        XCTAssertEqual(step(&d, at: 2.0, ticks: pos + 2 * sec + 100_000), [])   // 10 ms: in step
        // Throttled to one check per 1.5 s
        XCTAssertEqual(step(&d, at: 2.5, ticks: pos), [])
        let out = step(&d, at: 3.6, ticks: pos + 2 * sec + 6 * sec / 10)   // 1 s behind
        XCTAssertEqual(out, [.correct(.speed(rate: 2.0, duration: 1.0), delayMs: 1000)])
        // While the speed-up runs, nothing else; then back to 1.0
        XCTAssertEqual(step(&d, at: 4.0, ticks: pos), [])
        XCTAssertEqual(step(&d, at: 4.7, ticks: pos + 47 * sec / 10), [.resetRate])
        // After a Pause there is nothing to correct from
        var p = anchored(); p.stopped()
        XCTAssertEqual(step(&p, at: 10, ticks: 0), [])
    }

    func testLargeDelaySkips() {
        var d = anchored()
        let out = step(&d, at: 5, ticks: pos)
        XCTAssertEqual(out, [.correct(.skip(ticks: pos + 5 * sec), delayMs: 5000)])
        // Quiet for 1.5 s after a skip
        XCTAssertEqual(step(&d, at: 6, ticks: pos), [])
    }

    func testShortStallIsDebouncedLongOneReportsBufferingThenReady() {
        var d = anchored()
        XCTAssertEqual(step(&d, at: 2, ticks: pos + 2 * sec, stalled: true), [])
        XCTAssertEqual(step(&d, at: 4.9, ticks: pos + 2 * sec, stalled: true), [])
        // Recovered under 3 s: nothing reported
        XCTAssertEqual(step(&d, at: 5, ticks: pos + 2 * sec), [.correct(.skip(ticks: pos + 5 * sec), delayMs: 3000)])
        var e = anchored()
        XCTAssertEqual(step(&e, at: 2, ticks: pos + 2 * sec, stalled: true), [])
        XCTAssertEqual(step(&e, at: 5, ticks: pos + 2 * sec, stalled: true), [.buffering])
        XCTAssertEqual(step(&e, at: 8, ticks: pos + 2 * sec, stalled: true), [])   // once
        XCTAssertEqual(step(&e, at: 9, ticks: pos + 2 * sec), [.ready])
        XCTAssertEqual(step(&e, at: 9.5, ticks: pos + 2 * sec), [])   // no correction from the old Unpause yet
    }

    // MARK: Group

    private func make(_ rec: GroupRecorder, _ fake: DriftFakePlayback, clock: @escaping () -> Date) -> SyncPlayGroup {
        let g = SyncPlayGroup()
        g.runsDriver = false
        g.available = { true }
        g.send = { path, body, post in
            let o = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            rec.requests.append((path, o, post))
            return rec.answers[path] ?? Data()
        }
        g.socketNeeded = { rec.socket.append($0) }
        g.playback = { fake }
        g.now = clock
        g.log = { _ in }
        g.handle(msg(GroupFixtures.groupJoined))
        // The queue's playlist item (Reason "Queue" doesn't load anything)
        g.handle(msg(GroupFixtures.playQueue(reason: "Queue", start: pos, playing: true)))
        return g
    }

    func testDriftIsCorrectedWithTheRate() {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        var now = t0
        let g = make(rec, fake, clock: { now })
        fake.ticks = pos
        g.handle(msg(GroupFixtures.command("Unpause", when: t0, ticks: pos)))
        XCTAssertTrue(fake.playing)
        now = t0.addingTimeInterval(2); fake.ticks = pos + sec   // 1 s behind
        g.driverStep()
        XCTAssertEqual(fake.rates, [2.0])
        now = t0.addingTimeInterval(3.1); g.driverStep()
        XCTAssertEqual(fake.rates, [2.0, 1.0])
        // A Pause stops corrections (and the rate is normal)
        g.handle(msg(GroupFixtures.command("Pause", when: now, ticks: pos)))
        now = t0.addingTimeInterval(20); fake.playing = true; fake.ticks = 0
        g.driverStep()
        XCTAssertEqual(fake.rates, [2.0, 1.0])
        XCTAssertEqual(fake.seeks, [pos])
    }

    func testMidPlaybackStallSendsBufferingThenReady() async {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        var now = t0
        let g = make(rec, fake, clock: { now })
        fake.ticks = pos
        g.handle(msg(GroupFixtures.command("Unpause", when: t0, ticks: pos)))
        rec.requests = []
        fake.stalled = true; fake.ticks = pos + 2 * sec
        now = t0.addingTimeInterval(2); g.driverStep()
        now = t0.addingTimeInterval(4); g.driverStep()
        XCTAssertFalse(rec.paths.contains("/SyncPlay/Buffering"))
        now = t0.addingTimeInterval(5.5); g.driverStep()
        let sent = await waitUntil { rec.paths.contains("/SyncPlay/Buffering") }
        XCTAssertTrue(sent)
        let b = rec.body("/SyncPlay/Buffering")
        XCTAssertEqual(b?["PositionTicks"] as? Int64, pos + 2 * sec)
        XCTAssertEqual(b?["IsPlaying"] as? Bool, true)
        XCTAssertEqual(b?["PlaylistItemId"] as? String, "pl-1")
        XCTAssertEqual(b?["When"] as? String, SyncPlayGroup.iso(now))
        fake.stalled = false
        now = t0.addingTimeInterval(7); g.driverStep()
        let ready = await waitUntil { rec.paths.contains("/SyncPlay/Ready") }
        XCTAssertTrue(ready)
        XCTAssertEqual(rec.paths.filter { $0 == "/SyncPlay/Buffering" }.count, 1)
        XCTAssertEqual(rec.body("/SyncPlay/Ready")?["PlaylistItemId"] as? String, "pl-1")
    }

    func testShortStallSendsNothing() async {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        var now = t0
        let g = make(rec, fake, clock: { now })
        fake.ticks = pos
        g.handle(msg(GroupFixtures.command("Unpause", when: t0, ticks: pos)))
        rec.requests = []
        fake.stalled = true
        now = t0.addingTimeInterval(2); g.driverStep()
        now = t0.addingTimeInterval(2.4); g.driverStep()
        fake.stalled = false
        now = t0.addingTimeInterval(2.6); g.driverStep()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rec.paths.contains("/SyncPlay/Buffering"))
        XCTAssertFalse(rec.paths.contains("/SyncPlay/Ready"))
    }

    func testSetIgnoreWaitBodyAndStallsDontHoldTheGroup() async {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        var now = t0
        let g = make(rec, fake, clock: { now })
        await g.setIgnoreWait(true)
        XCTAssertTrue(g.ignoreWait)
        XCTAssertEqual(rec.body("/SyncPlay/SetIgnoreWait")?["IgnoreWait"] as? Bool, true)
        fake.ticks = pos
        g.handle(msg(GroupFixtures.command("Unpause", when: t0, ticks: pos)))
        fake.stalled = true
        now = t0.addingTimeInterval(2); g.driverStep()
        now = t0.addingTimeInterval(6); g.driverStep()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rec.paths.contains("/SyncPlay/Buffering"))
        await g.setIgnoreWait(false)
        XCTAssertEqual(rec.body("/SyncPlay/SetIgnoreWait")?["IgnoreWait"] as? Bool, false)
        // Per session: leaving resets it
        await g.setIgnoreWait(true)
        await g.leave()
        XCTAssertFalse(g.ignoreWait)
    }

    func testRejoinWhenTheGroupStillExists() async {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        let g = make(rec, fake, clock: { Date() })
        rec.answers["/SyncPlay/List"] = Data("[\(GroupFixtures.groupInfo)]".utf8)
        rec.requests = []
        await g.rejoin()
        XCTAssertEqual(rec.paths, ["/SyncPlay/List", "/SyncPlay/Join"])
        XCTAssertEqual(rec.body("/SyncPlay/Join")?["GroupId"] as? String, GroupFixtures.gid)
        XCTAssertTrue(g.isInGroup)
        // The server's restore: GroupJoined again, still the same group
        g.handle(msg(GroupFixtures.groupJoined))
        XCTAssertEqual(g.info?.id, GroupFixtures.gid)
    }

    func testRejoinWhenTheGroupHasEnded() async {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        let g = make(rec, fake, clock: { Date() })
        rec.answers["/SyncPlay/List"] = Data("[]".utf8)
        rec.requests = []
        await g.rejoin()
        XCTAssertEqual(rec.paths, ["/SyncPlay/List"])
        XCTAssertEqual(g.state, .notInGroup)
        XCTAssertEqual(g.toast, SyncPlayGroup.endedText)
        XCTAssertEqual(rec.socket.last, false)
    }

    func testNotInGroupTriesToRejoin() async {
        let rec = GroupRecorder(), fake = DriftFakePlayback()
        let g = make(rec, fake, clock: { Date() })
        rec.answers["/SyncPlay/List"] = Data("[\(GroupFixtures.groupInfo)]".utf8)
        rec.requests = []
        g.handle(msg(GroupFixtures.notInGroup))
        let joined = await waitUntil { rec.paths.contains("/SyncPlay/Join") }
        XCTAssertTrue(joined)
        XCTAssertTrue(g.isInGroup)
    }
}
