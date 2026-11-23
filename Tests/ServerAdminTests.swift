import XCTest
@testable import Cove

/// Server management phase 1: /System/Info and /ScheduledTasks decoding (Emby + Jellyfin), task grouping,
/// progress, the restart wait, the model's calls and the admin-only menu row.
@MainActor
final class ServerAdminTests: XCTestCase {
    func data(_ s: String) -> Data { Data(s.utf8) }

    let embyInfo = """
    {"ServerName":"Home","Version":"4.8.10.0","OperatingSystemDisplayName":"Linux","LocalAddress":"http://192.168.1.5:8096",
     "WanAddress":"https://emby.example.com","HasUpdateAvailable":true,"HasPendingRestart":true,
     "CachePath":"/var/lib/emby/cache","TranscodingTempPath":"/tmp/transcode","LogPath":"/var/lib/emby/logs","Id":"abc"}
    """
    let jellyfinInfo = """
    {"ServerName":"Jelly","Version":"10.10.3","ProductName":"Jellyfin Server","OperatingSystem":"Linux",
     "LocalAddress":"http://10.0.0.2:8096","HasPendingRestart":false,"CachePath":"/cache","TranscodingTempPath":"/cache/transcodes",
     "LogPath":"/config/log","Id":"x"}
    """

    func testDecodeEmbyInfo() throws {
        let i = try XCTUnwrap(ServerAdminInfo.decode(data(embyInfo), kind: .emby))
        XCTAssertEqual(i.name, "Home"); XCTAssertEqual(i.product, "Emby"); XCTAssertEqual(i.version, "4.8.10.0")
        XCTAssertEqual(i.os, "Linux"); XCTAssertEqual(i.wanAddress, "https://emby.example.com")
        XCTAssertEqual(i.updateAvailable, true); XCTAssertEqual(i.updateLine, "Update available")
        XCTAssertTrue(i.restartPending)
        XCTAssertEqual(i.transcodePath, "/tmp/transcode"); XCTAssertEqual(i.logPath, "/var/lib/emby/logs")
    }

    func testDecodeJellyfinInfo() throws {
        let i = try XCTUnwrap(ServerAdminInfo.decode(data(jellyfinInfo), kind: .jellyfin))
        XCTAssertEqual(i.product, "Jellyfin"); XCTAssertEqual(i.os, "Linux")
        XCTAssertNil(i.updateAvailable); XCTAssertNil(i.updateLine)   // Jellyfin can't tell: nothing shown
        XCTAssertNil(i.wanAddress); XCTAssertFalse(i.restartPending)
        XCTAssertEqual(i.localAddress, "http://10.0.0.2:8096")
        XCTAssertNil(ServerAdminInfo.decode(data("[]"), kind: .emby))
    }

    let embyTasks = """
    [{"Name":"Scan media library","State":"Running","CurrentProgressPercentage":42.5,"Id":"t1","Category":"Library",
      "Description":"Scans folders","IsHidden":false,"Triggers":[{"Type":"IntervalTrigger","IntervalTicks":432000000000}],
      "LastExecutionResult":{"StartTimeUtc":"2026-11-20T03:00:00.0000000Z","EndTimeUtc":"2026-11-20T03:01:04.0000000Z","Status":"Completed"}},
     {"Name":"Backup","State":"Idle","Id":"t2","Category":"Application","IsHidden":false,
      "Triggers":[{"Type":"DailyTrigger","TimeOfDayTicks":108000000000}],
      "LastExecutionResult":{"StartTimeUtc":"2026-11-20T03:00:00.0000000+00:00","EndTimeUtc":"2026-11-20T03:00:04.0000000+00:00","Status":"Failed","ErrorMessage":"disk full"}},
     {"Name":"Hidden","State":"Idle","Id":"t3","Category":"Application","IsHidden":true}]
    """
    let jellyfinTasks = """
    [{"Name":"Refresh People","State":"Idle","Id":"j1","Key":"RefreshPeople","Category":"Library","IsHidden":false,
      "Triggers":[{"Type":"WeeklyTrigger","TimeOfDayTicks":18000000000,"DayOfWeek":"Sunday"}]},
     {"Name":"Clean Log Directory","State":"Cancelling","CurrentProgressPercentage":120,"Id":"j2","Category":"Maintenance","IsHidden":false,
      "Triggers":[{"Type":"StartupTrigger"}],"LastExecutionResult":{"Status":"Cancelled","StartTimeUtc":"0001-01-01T00:00:00.0000000Z"}},
     {"Name":"Audio Normalization","State":"Idle","Id":"j3","Category":"Library","IsHidden":false}]
    """

    func testDecodeEmbyTasks() throws {
        let t = try XCTUnwrap(ServerTask.decodeList(data(embyTasks)))
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t[0].state, .running); XCTAssertEqual(t[0].progress, 42.5)
        XCTAssertEqual(t[0].triggers, ["Every 12 h"])
        XCTAssertEqual(t[0].last?.duration, 64); XCTAssertFalse(t[0].last!.failed)
        XCTAssertTrue(t[1].last!.failed); XCTAssertEqual(t[1].last?.error, "disk full"); XCTAssertEqual(t[1].last?.duration, 4)
        XCTAssertEqual(t[1].triggers, ["Daily at 03:00"]); XCTAssertNil(t[1].progress)
        XCTAssertTrue(t[2].hidden)
    }

    func testDecodeJellyfinTasks() throws {
        let t = try XCTUnwrap(ServerTask.decodeList(data(jellyfinTasks)))
        XCTAssertEqual(t[0].triggers, ["Sundays at 00:30"])
        XCTAssertEqual(t[1].state, .cancelling); XCTAssertEqual(t[1].progress, 100)   // clamped
        XCTAssertTrue(t[1].running); XCTAssertEqual(t[1].triggers, ["At startup"])
        XCTAssertNil(t[1].last?.start)   // year 0001 = never
        XCTAssertNil(t[2].last)
    }

    func testGroupingCommonFirstAndSorted() throws {
        let t = try XCTUnwrap(ServerTask.decodeList(data(embyTasks))) + XCTUnwrap(ServerTask.decodeList(data(jellyfinTasks)))
        let s = ServerTaskGrouping.sections(t)
        XCTAssertEqual(s.map(\.title), ["Common", "Application", "Library", "Maintenance"])
        XCTAssertEqual(s[0].tasks.map(\.name), ["Scan media library", "Refresh People"])
        XCTAssertEqual(s[1].tasks.map(\.name), ["Backup"])   // hidden left out
        XCTAssertEqual(s[2].tasks.map(\.name), ["Audio Normalization"])
        XCTAssertEqual(ServerTaskGrouping.sections(t, query: "log").map(\.title), ["Maintenance"])
        XCTAssertEqual(ServerTaskGrouping.sections(t, query: "folders").first?.tasks.map(\.id), ["t1"])   // description
        XCTAssertTrue(ServerTaskGrouping.sections(t, query: "zzz").isEmpty)
    }

    func testPollInterval() throws {
        let t = try XCTUnwrap(ServerTask.decodeList(data(embyTasks)))
        XCTAssertEqual(ServerTaskGrouping.pollInterval(t), 2)
        XCTAssertEqual(ServerTaskGrouping.pollInterval([t[1]]), 30)
    }

    func testDurationAndDates() {
        XCTAssertEqual(ServerAdminDate.duration(4), "4 s")
        XCTAssertEqual(ServerAdminDate.duration(64), "1 min 4 s")
        XCTAssertEqual(ServerAdminDate.duration(7500), "2 h 5 min")
        XCTAssertNotNil(ServerAdminDate.parse("2026-11-20T03:00:00"))
        XCTAssertNil(ServerAdminDate.parse("0001-01-01T00:00:00Z"))
    }

    func testSessionsCount() {
        XCTAssertEqual(ServerAdminSessions.activeStreams(data(#"[{"Id":"a","NowPlayingItem":{"Id":"1"}},{"Id":"b"}]"#)), 1)
        XCTAssertNil(ServerAdminSessions.activeStreams(data("{}")))
    }

    // MARK: Restart wait

    func runWait(_ answers: [Bool], grace: TimeInterval = 20, timeout: TimeInterval = 180) async -> (ServerRestartWait.Outcome, Int) {
        var clock: TimeInterval = 0
        var i = 0
        let out = await ServerRestartWait.wait(isUp: { defer { i += 1 }; return i < answers.count ? answers[i] : false },
                                               sleep: { clock += $0 }, elapsed: { clock },
                                               interval: 2, graceUp: grace, timeout: timeout)
        return (out, i)
    }

    func testRestartWaitDownThenUp() async {
        let (o, n) = await runWait([true, false, false, true])
        XCTAssertEqual(o, .back); XCTAssertEqual(n, 4)   // the first "up" (still going down) doesn't count
    }

    func testRestartWaitUpOnlyAfterGrace() async {
        let (o, n) = await runWait(Array(repeating: true, count: 50), grace: 10)
        XCTAssertEqual(o, .back); XCTAssertEqual(n, 5)   // 5 × 2 s
    }

    func testRestartWaitTimesOut() async {
        let (o, n) = await runWait([], timeout: 180)
        XCTAssertEqual(o, .timedOut); XCTAssertEqual(n, 90)
    }

    // MARK: Model

    final class Fake {
        var calls: [String] = []
        var answers: [String: (String, Int)] = [:]
        func api() -> ServerAdminAPI {
            ServerAdminAPI(call: { m, p in
                self.calls.append("\(m) \(p)")
                let a = self.answers["\(m) \(p)"] ?? ("", 204)
                return (Data(a.0.utf8), a.1)
            }, userId: "u1")
        }
    }

    func testModelLoadsAndRuns() async {
        let f = Fake()
        f.answers["GET /System/Info"] = (embyInfo, 200)
        f.answers["GET /Sessions?ActiveWithinSeconds=960"] = (#"[{"NowPlayingItem":{}},{"NowPlayingItem":{}}]"#, 200)
        f.answers["GET /ScheduledTasks?IsHidden=false"] = (embyTasks, 200)
        let m = ServerAdmin(kind: .emby, api: f.api())
        await m.loadOverview()
        XCTAssertEqual(m.info?.name, "Home"); XCTAssertEqual(m.streams, 2)
        await m.loadTasks()
        XCTAssertEqual(m.tasks.count, 3)
        await m.run(m.tasks[1])
        await m.stop(m.tasks[0])
        await m.scanAll()
        XCTAssertTrue(f.calls.contains("POST /ScheduledTasks/Running/t2"))
        XCTAssertTrue(f.calls.contains("DELETE /ScheduledTasks/Running/t1"))
        XCTAssertTrue(f.calls.contains("POST /Library/Refresh"))
        XCTAssertEqual(m.message, "Library scan started.")
        XCTAssertFalse(m.forbidden)
    }

    func testModelForbidden() async {
        let f = Fake()
        f.answers["GET /System/Info"] = ("", 403)
        let m = ServerAdmin(kind: .jellyfin, api: f.api())
        await m.loadOverview()
        XCTAssertTrue(m.forbidden)
        let f2 = Fake()
        f2.answers["GET /Users/u1"] = (#"{"Policy":{"IsAdministrator":false}}"#, 200)
        let m2 = ServerAdmin(kind: .emby, api: f2.api())
        await m2.checkAdmin()
        XCTAssertTrue(m2.forbidden)
    }

    func testModelRestartWaitsAndRefreshes() async {
        let f = Fake()
        f.answers["POST /System/Restart"] = ("", 204)
        f.answers["GET /System/Info/Public"] = ("{}", 0)   // down…
        f.answers["GET /System/Info"] = (jellyfinInfo, 200)
        let m = ServerAdmin(kind: .jellyfin, api: f.api())
        var naps = 0
        m.sleep = { _ in naps += 1; if naps == 3 { f.answers["GET /System/Info/Public"] = ("{}", 200) } }   // …then back
        await m.restart()
        XCTAssertEqual(m.power, .back)
        XCTAssertEqual(m.info?.name, "Jelly")
    }

    // MARK: Menu row

    func testManageServerRowOnlyForAdmins() {
        func input(_ admin: Bool?) -> ProfileMenuInput {
            ProfileMenuInput(name: "J", jellyfin: true, admin: admin, hasPicture: false, servers: [], currentServer: "")
        }
        XCTAssertEqual(ProfileMenuSpec.rows(.app, input(true)), [.manageServer, .settings, .checkUpdates, .about, .help])
        XCTAssertEqual(ProfileMenuSpec.rows(.app, input(false)), [.settings, .checkUpdates, .about, .help])
        XCTAssertEqual(ProfileMenuSpec.rows(.app, input(nil)), [.settings, .checkUpdates, .about, .help])
        XCTAssertEqual(ProfileMenuSpec.title(.manageServer), "Manage server…")
        XCTAssertEqual(ServerAdmin.Tab.allCases.map(\.title), ["Overview", "Users", "Libraries", "Tasks", "Devices", "Plugins", "Logs", "Trash"])
    }
}
