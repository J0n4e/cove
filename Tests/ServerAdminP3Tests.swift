import XCTest
@testable import Cove

/// Server management phases 3-4: Devices, session actions, stream details, Plugins, Logs, Activity log, server alerts.
final class ServerAdminP3Tests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }

    // MARK: Devices

    func testDevicesJellyfin() {
        let l = AdminDevice.decodeList(d(#"{"Items":[{"Id":"abc","Name":"iPhone","AppName":"Swiftfin","AppVersion":"1.2","LastUserName":"anna","DateLastActivity":"2026-11-20T10:00:00.0000000Z"},{"Id":"mac1","Name":"Mac","CustomName":"Studio","AppName":"Cove","AppVersion":"1.19","DateLastActivity":"2026-11-21T10:00:00Z"}]}"#))!
        XCTAssertEqual(l.map(\.id), ["mac1", "abc"])   // newest first
        XCTAssertEqual(l[0].displayName, "Studio")
        XCTAssertEqual(l[1].lastUser, "anna")
        XCTAssertTrue(l[0].isOwn("mac1"))
        XCTAssertNotNil(DeviceAdminAPI.removeBlocked(l[0], myDeviceId: "mac1"))
        XCTAssertNil(DeviceAdminAPI.removeBlocked(l[1], myDeviceId: "mac1"))
        XCTAssertEqual(DeviceAdminAPI.remove("abc", kind: .jellyfin).path, "/Devices?id=abc")
        let r = DeviceAdminAPI.rename(l[1], to: " Phone ", kind: .jellyfin)
        XCTAssertEqual(r.path, "/Devices/Options?id=abc")
        XCTAssertEqual(json(r.body)["CustomName"] as? String, "Phone")
    }

    func testDevicesEmbyReportedId() {
        let l = AdminDevice.decodeList(d(#"{"Items":[{"Id":"17","ReportedDeviceId":"mac-xyz","Name":"Mac","AppName":"Cove"}]}"#))!
        XCTAssertEqual(l[0].id, "17"); XCTAssertEqual(l[0].deviceId, "mac-xyz")
        XCTAssertTrue(l[0].isOwn("mac-xyz"))
        XCTAssertEqual(DeviceAdminAPI.remove("17", kind: .emby).path, "/Devices?Id=17")
        XCTAssertEqual(SessionAdminAPI.device(for: "mac-xyz", in: l)?.id, "17")
        XCTAssertTrue(AdminDevice.matches(l[0], "cove")); XCTAssertFalse(AdminDevice.matches(l[0], "roku"))
    }

    // MARK: Sessions

    func testSessionRequests() {
        let m = SessionAdminAPI.message("s1", text: String(repeating: "x", count: 300))
        XCTAssertEqual(m.method, "POST"); XCTAssertEqual(m.path, "/Sessions/s1/Message")
        let b = json(m.body)
        XCTAssertEqual(b["Header"] as? String, "Cove"); XCTAssertEqual((b["Text"] as? String)?.count, 200)
        XCTAssertEqual(b["TimeoutMs"] as? Int, 8000)
        XCTAssertEqual(SessionAdminAPI.stop("s1").path, "/Sessions/s1/Playing/Stop")
        XCTAssertTrue(SessionAdminAPI.offersActions(isAdmin: true, sessionDeviceId: "other", myDeviceId: "me"))
        XCTAssertFalse(SessionAdminAPI.offersActions(isAdmin: true, sessionDeviceId: "me", myDeviceId: "me"))
        XCTAssertFalse(SessionAdminAPI.offersActions(isAdmin: false, sessionDeviceId: "other", myDeviceId: "me"))
        XCTAssertFalse(SessionAdminAPI.offersActions(isAdmin: nil, sessionDeviceId: "other", myDeviceId: "me"))
    }

    func testStreamDetails() throws {
        let j = #"{"Id":"s","Client":"Jellyfin Web","ApplicationVersion":"10.9","DeviceName":"Chrome","RemoteEndPoint":"192.168.1.5","DeviceId":"dev","PlayState":{"PlayMethod":"Transcode"},"NowPlayingItem":{"Id":"i","Name":"Film","MediaStreams":[{"Type":"Video","Codec":"hevc"},{"Type":"Audio","Codec":"truehd","IsDefault":true}]},"TranscodingInfo":{"IsVideoDirect":false,"IsAudioDirect":false,"VideoCodec":"h264","AudioCodec":"aac","Bitrate":8000000,"TranscodeReasons":["VideoCodecNotSupported"]}}"#
        let s = try JSONDecoder().decode(ActiveSession.self, from: d(j))
        XCTAssertEqual(s.DeviceId, "dev")
        let r = Dictionary(uniqueKeysWithValues: StreamDetails.rows(s).map { ($0.label, $0.value) })
        XCTAssertEqual(r["Video"], "HEVC → H264")
        XCTAssertEqual(r["Audio"], "TRUEHD → AAC")
        XCTAssertEqual(r["Bitrate"], "8.0 Mbps")
        XCTAssertEqual(r["Reason"], "Video codec not supported")
        XCTAssertEqual(r["Address"], "192.168.1.5 · Local")
        XCTAssertEqual(r["Playback"], "Transcoding")
        XCTAssertEqual(StreamDetails.network("8.8.8.8"), "Remote")
        let direct = try JSONDecoder().decode(ActiveSession.self, from: d(#"{"Id":"s","NowPlayingItem":{"Id":"i","Name":"F","MediaStreams":[{"Type":"Video","Codec":"h264"}]}}"#))
        XCTAssertEqual(StreamDetails.rows(direct).first { $0.label == "Video" }?.value, "H264 (direct)")
    }

    // MARK: Plugins

    func testPluginsAndUpdates() {
        let p = AdminPlugin.decodeList(d(#"[{"Id":"a-1","Name":"OpenSubtitles","Version":"20.0.0.0","Status":"Active","CanUninstall":true},{"Id":"b2","Name":"Trakt","Version":"1.0","Status":"Restart"}]"#))!
        XCTAssertEqual(p.map(\.name), ["OpenSubtitles", "Trakt"])
        XCTAssertEqual(p[1].statusTitle, "Restart required"); XCTAssertTrue(p[1].needsRestart)
        let pk = AdminPackage.decodeList(d(#"[{"name":"OpenSubtitles","guid":"A1","versions":[{"version":"19.0.0.0"},{"version":"21.0.0.0"}]},{"name":"Trakt","guid":"b2","versions":[{"version":"1.0.0.0"}]}]"#))
        let u = PluginUpdates.apply(p, packages: pk)
        XCTAssertEqual(u[0].update, "21.0.0.0"); XCTAssertNil(u[1].update)
        XCTAssertEqual(PluginUpdates.compare("10.9.2", "10.9.2.0"), 0)
        XCTAssertEqual(PluginUpdates.compare("1.10", "1.9"), 1)
        XCTAssertEqual(PluginAdminAPI.install(pk[0], kind: .jellyfin).path, "/Packages/Installed/OpenSubtitles?assemblyGuid=A1&version=21.0.0.0")
        XCTAssertEqual(PluginAdminAPI.enable(p[0], false).path, "/Plugins/a-1/20.0.0.0/Disable")
        XCTAssertEqual(PluginAdminAPI.uninstall(p[0], kind: .jellyfin).path, "/Plugins/a-1/20.0.0.0")
        XCTAssertEqual(PluginAdminAPI.uninstall(p[0], kind: .emby).path, "/Plugins/a-1")
        let emby = AdminPlugin.decodeList(d(#"[{"Id":"x","Name":"Webhooks","Version":"3.1"}]"#))!
        XCTAssertNil(emby[0].statusTitle)
        XCTAssertEqual(AdminPackage.decodeList(d(#"[{"name":"Webhooks","guid":"x","versionStr":"3.2"}]"#)).first?.version, "3.2")
    }

    // MARK: Logs

    func testLogsListAndParse() {
        let f = AdminLogFile.decodeList(d(#"[{"Name":"old.log","Size":10,"DateModified":"2026-11-01T00:00:00Z"},{"Name":"log_20261121.log","Size":2048,"DateModified":"2026-11-21T00:00:00Z"}]"#))!
        XCTAssertEqual(f.first?.name, "log_20261121.log")
        XCTAssertEqual(LogAdminAPI.file("a b.log", kind: .jellyfin).path, "/System/Logs/Log?name=a%20b.log")
        XCTAssertEqual(LogAdminAPI.file("a.log", kind: .emby).path, "/System/Logs/a.log")
        let text = """
        [2026-11-21 10:00:00.123 +00:00] [INF] [1] Main: Started
        [2026-11-21 10:00:01.000 +00:00] [ERR] [7] Boom
           at Foo.Bar()
        [2026-11-21 10:00:02.000 +00:00] [WRN] [7] Careful
        2026-11-21 10:00:03.000 Error App: emby style
        """
        let l = LogAdminAPI.parse(text)
        XCTAssertEqual(l.map(\.level), [.info, .error, .error, .warn, .error])
        XCTAssertEqual(LogAdminAPI.filter(l, levels: [.error], query: "").count, 3)
        XCTAssertEqual(LogAdminAPI.filter(l, levels: [], query: "careful").count, 1)
        XCTAssertEqual(LogAdminAPI.parse((1...2500).map { "line \($0)" }.joined(separator: "\n")).count, 2000)
        XCTAssertEqual(LogAdminAPI.parse((1...2500).map { "line \($0)" }.joined(separator: "\n")).last?.text, "line 2500")
        XCTAssertFalse(LogAdminAPI.hasLevels(LogAdminAPI.parse("plain\ntext")))
        XCTAssertEqual(LogAdminAPI.downloadName("a/b:c.log"), "a_b_c.log")
    }

    func testActivityLog() {
        let a = AdminActivity.decodeList(d(#"{"Items":[{"Id":1,"Name":"anna signed in","Type":"AuthenticationSucceeded","Date":"2026-11-21T09:00:00Z","Severity":"Information","UserId":"u1"},{"Id":2,"Name":"Failed login try from bob","ShortOverview":"IP address: 1.2.3.4","Type":"AuthenticationFailed","Date":"2026-11-21T10:00:00Z","Severity":"Error"},{"Id":3,"Name":"Scan failed","Type":"ScheduledTaskFailed","Severity":"Warning","UserId":"00000000-0000-0000-0000-000000000000"}],"TotalRecordCount":3}"#))!
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a[1].severity, .error); XCTAssertEqual(a[2].severity, .warning); XCTAssertNil(a[2].userId)
        XCTAssertEqual(AdminActivity.filter(a, .logins).map(\.id), ["1", "2"])
        XCTAssertEqual(AdminActivity.filter(a, .errors).map(\.id), ["2", "3"])
        XCTAssertTrue(ServerAlertDetector.isFailedLogin(a[1])); XCTAssertFalse(ServerAlertDetector.isFailedLogin(a[0]))
    }

    func testTabs() {
        XCTAssertEqual(ServerAdmin.Tab.allCases.first, .overview)
        XCTAssertEqual(ServerAdmin.Tab.allCases.map(\.title), ["Overview", "Users", "Libraries", "Tasks", "Devices", "Plugins", "Logs", "Trash"])
    }

    // MARK: Server alerts

    private func info(restart: Bool = false, update: String? = nil) -> ServerAdminInfo {
        ServerAdminInfo(name: "S", product: "Emby", version: "4.8", os: "", localAddress: nil, wanAddress: nil,
                        updateAvailable: update != nil, updateVersion: update, restartPending: restart,
                        cachePath: nil, transcodePath: nil, logPath: nil, startTime: nil)
    }
    private func task(_ id: String, _ name: String, status: String, end: Double) -> ServerTask {
        ServerTask(id: id, name: name, description: "", category: "", hidden: false, state: .idle, progress: nil,
                   last: .init(status: status, start: Date(timeIntervalSince1970: end - 60), end: Date(timeIntervalSince1970: end), error: status == "Failed" ? "Disk full" : nil),
                   triggers: [])
    }
    private let all: (ServerAlertKind) -> Bool = { _ in true }

    func testAlertsBaselineThenEvents() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // First round: a baseline only (old failures and a pending restart aren't news)
        var r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, info: info(restart: true), tasks: [task("t", "Refresh", status: "Failed", end: 100)]),
                                           state: ServerAlertState(), now: now, isOn: all)
        XCTAssertTrue(r.alerts.isEmpty); XCTAssertTrue(r.state.baselined)
        // Restart already pending → nothing; a new failed run → one alert; an update → once per version
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, info: info(restart: true, update: "4.9"),
                                                           tasks: [task("t", "Refresh", status: "Failed", end: 200)]),
                                       state: r.state, now: now, isOn: all)
        XCTAssertEqual(r.alerts.map(\.kind), [.serverUpdate, .taskFailed])
        XCTAssertEqual(r.alerts[1].body, "Disk full")
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, info: info(restart: true, update: "4.9"),
                                                           tasks: [task("t", "Refresh", status: "Failed", end: 200)]),
                                       state: r.state, now: now, isOn: all)
        XCTAssertTrue(r.alerts.isEmpty)
        // Restart flag false → true
        var s = r.state; s.restartPending = false
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, info: info(restart: true)), state: s, now: now, isOn: all)
        XCTAssertEqual(r.alerts.map(\.kind), [.restartNeeded])
    }

    func testAlertsOfflineAndBack() {
        var st = ServerAlertState(); st.baselined = true
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: false), state: st, now: t0, isOn: all)
        XCTAssertTrue(r.alerts.isEmpty)
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: false), state: r.state, now: t0.addingTimeInterval(60), isOn: all)
        XCTAssertTrue(r.alerts.isEmpty)
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: false), state: r.state, now: t0.addingTimeInterval(130), isOn: all)
        XCTAssertEqual(r.alerts.map(\.title), ["Server unreachable"])
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: false), state: r.state, now: t0.addingTimeInterval(200), isOn: all)
        XCTAssertTrue(r.alerts.isEmpty)   // once
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true), state: r.state, now: t0.addingTimeInterval(260), isOn: all)
        XCTAssertEqual(r.alerts.map(\.title), ["Server back online"])
        // A short blip: nothing at all
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: false), state: r.state, now: t0.addingTimeInterval(300), isOn: all)
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true), state: r.state, now: t0.addingTimeInterval(330), isOn: all)
        XCTAssertTrue(r.alerts.isEmpty)
    }

    func testAlertsSocketRestart() {
        var st = ServerAlertState(); st.baselined = true
        let now = Date(timeIntervalSince1970: 5_000)
        let a = ServerAlertDetector.socket("ServerRestarting", state: st, now: now, isOn: all)
        XCTAssertEqual(a.alert?.title, "Server is restarting"); XCTAssertTrue(a.state.restarting)
        XCTAssertNil(ServerAlertDetector.socket("ServerRestarting", state: a.state, now: now, isOn: all).alert)
        let back = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true), state: a.state, now: now, isOn: all)
        XCTAssertEqual(back.alerts.map(\.title), ["Server back online"])
        XCTAssertEqual(ServerAlertDetector.socket("RestartRequired", state: st, now: now, isOn: all).alert?.kind, .restartNeeded)
        XCTAssertTrue(ServerAlertDetector.socketTypes.contains("ScheduledTaskEnded"))
    }

    func testAlertsPluginsLoginsScanAndPrefs() {
        var st = ServerAlertState(); st.baselined = true; st.activityAfter = 100
        let now = Date(timeIntervalSince1970: 10_000)
        var p = AdminPlugin.decodeList(d(#"[{"Id":"a","Name":"Subs","Version":"1"}]"#))!; p[0].update = "2"
        let acts = AdminActivity.decodeList(d(#"[{"Id":5,"Name":"Failed login try from bob","ShortOverview":"IP address: 1.2.3.4","Type":"AuthenticationFailed","Date":"1970-01-01T01:00:00Z","Severity":"Error"},{"Id":4,"Name":"old fail","Type":"AuthenticationFailed","Date":"1970-01-01T00:00:50Z"}]"#))!
        st.taskEnds["scan"] = 50
        var r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, tasks: [task("scan", "Scan media library", status: "Completed", end: 90)],
                                                               pluginUpdates: p, activity: acts),
                                           state: st, now: now, isOn: all)
        XCTAssertEqual(Set(r.alerts.map(\.kind)), [.pluginUpdates, .failedLogins, .scanFinished])
        XCTAssertEqual(r.alerts.first { $0.kind == .failedLogins }?.title, "1 failed sign-in")
        XCTAssertEqual(r.alerts.first { $0.kind == .pluginUpdates }?.tab, .plugins)
        XCTAssertEqual(r.state.activityAfter, 3600)
        // Same plugin set and no new entries: nothing
        r = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, pluginUpdates: p, activity: acts), state: r.state, now: now, isOn: all)
        XCTAssertTrue(r.alerts.isEmpty)
        // Scan finished is off by default
        XCTAssertFalse(ServerAlertKind.scanFinished.defaultOn); XCTAssertTrue(ServerAlertKind.taskFailed.defaultOn)
        let off = ServerAlertDetector.detect(ServerAlertSnapshot(reachable: true, tasks: [task("scan", "Scan media library", status: "Completed", end: 95)]),
                                             state: r.state, now: now, isOn: { $0 != .scanFinished })
        XCTAssertTrue(off.alerts.isEmpty)
    }

    func testAlertNotificationTarget() {
        let a = ServerAlert(kind: .taskFailed, key: "k", title: "Task failed: X", body: "err", symbol: "exclamationmark.triangle", tab: .tasks)
        let n = ServerAlertDetector.notification(a, server: "https://s", serverName: "Home", userId: "u")
        XCTAssertTrue(n.images.isEmpty)
        let info = NewMediaService.userInfo(n)
        XCTAssertEqual(info["kind"], "server"); XCTAssertEqual(info["tab"], String(ServerAdmin.Tab.tasks.rawValue))
        XCTAssertEqual(NewMediaService.target(info), .server(tab: ServerAdmin.Tab.tasks.rawValue, symbol: "exclamationmark.triangle"))
        XCTAssertEqual(n.cardDetail, "Home · err")
        XCTAssertNotEqual(ServerAlertDetector.stateKey(server: "https://A"), ServerAlertDetector.stateKey(server: "https://b"))
    }
}
