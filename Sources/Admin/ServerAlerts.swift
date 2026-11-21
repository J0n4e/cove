import Foundation
import Combine
import AppKit

// Server alerts (admins only): restart needed, restarting / unreachable / back online, server and plugin
// updates, failed scheduled tasks, failed sign-ins and (off by default) library scans finished. Posted through
// Cove's own notification path (Activity → Notifications, the glass toast, the macOS banner). The detector is pure
// (tested in Tests/ServerAdminP3Tests.swift); the service polls the CURRENT server every 5 minutes while Cove runs
// (every 30 s while it doesn't answer) and listens to Jellyfin's socket for RestartRequired / ServerRestarting /
// ServerShuttingDown / ScheduledTaskEnded. Each server keeps its own state, so nothing is announced twice.

enum ServerAlertKind: String, CaseIterable {
    case restartNeeded, power, serverUpdate, pluginUpdates, taskFailed, failedLogins, scanFinished

    var prefKey: String { "serverAlert." + rawValue }
    var defaultOn: Bool { self != .scanFinished }
    var title: String {
        switch self {
        case .restartNeeded: return "Server restart needed"
        case .power: return "Server restarting / unreachable / back online"
        case .serverUpdate: return "Server update available"
        case .pluginUpdates: return "Plugin updates available"
        case .taskFailed: return "Scheduled task failed"
        case .failedLogins: return "Failed sign-in attempts"
        case .scanFinished: return "Library scan finished"
        }
    }
    func isOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: prefKey) == nil ? defaultOn : d.bool(forKey: prefKey) }
}

/// One alert, ready for the notification path.
struct ServerAlert: Equatable {
    let kind: ServerAlertKind
    /// Stable per event (the inbox replaces a same-id copy).
    let key: String
    let title: String
    let body: String
    let symbol: String
    let tab: ServerAdmin.Tab
}

/// What one poll saw. nil fields = not read this round (left unchanged in the state).
struct ServerAlertSnapshot {
    var reachable: Bool
    var info: ServerAdminInfo? = nil
    var tasks: [ServerTask]? = nil
    /// Plugins with a newer catalog version.
    var pluginUpdates: [AdminPlugin]? = nil
    var activity: [AdminActivity]? = nil
}

/// Per server, saved in UserDefaults.
struct ServerAlertState: Codable, Equatable {
    var baselined = false
    var restartPending = false
    var notifiedUpdate: String?
    var pluginSet: String?
    /// Task id → last end time seen (s since 1970).
    var taskEnds: [String: Double] = [:]
    /// Activity entries newer than this are new (s since 1970).
    var activityAfter: Double?
    // Only while Cove runs (reset at launch):
    var offlineSince: Double?
    var offlineNotified = false
    var restarting = false
}

enum ServerAlertDetector {
    static let offlineAfter: TimeInterval = 120

    static func isFailedLogin(_ a: AdminActivity) -> Bool {
        let t = a.type.lowercased(), n = a.name.lowercased()
        return t.contains("authenticationfailed") || n.contains("failed to sign in") || n.contains("failed login")
            || (a.isLogin && a.severity == .error)
    }

    /// The alerts for this snapshot and the state to keep. The first round on a server only takes a baseline.
    static func detect(_ snap: ServerAlertSnapshot, state old: ServerAlertState, now: Date,
                       isOn: (ServerAlertKind) -> Bool = { $0.isOn() }) -> (alerts: [ServerAlert], state: ServerAlertState) {
        var s = old, out: [ServerAlert] = []
        let t = now.timeIntervalSince1970
        func add(_ a: ServerAlert) { if isOn(a.kind) && old.baselined { out.append(a) } }

        // Reachability
        if !snap.reachable {
            if s.offlineSince == nil { s.offlineSince = t }
            if !s.offlineNotified, let since = s.offlineSince, t - since >= offlineAfter, old.baselined {
                s.offlineNotified = true
                add(ServerAlert(kind: .power, key: "offline-\(Int(since))", title: "Server unreachable",
                                body: "The server hasn't answered for \(Int((t - since) / 60)) minutes.", symbol: "bolt.horizontal.circle", tab: .overview))
            }
            return (out, s)
        }
        if s.offlineNotified || s.restarting {
            add(ServerAlert(kind: .power, key: "back-\(Int(t))", title: "Server back online",
                            body: "The server is answering again.", symbol: "checkmark.circle", tab: .overview))
        }
        s.offlineSince = nil; s.offlineNotified = false; s.restarting = false

        if let i = snap.info {
            if i.restartPending && !s.restartPending {
                add(ServerAlert(kind: .restartNeeded, key: "restart-\(Int(t))", title: "Server restart needed",
                                body: "Restart the server to finish installing updates or changes.", symbol: "arrow.clockwise.circle", tab: .overview))
            }
            s.restartPending = i.restartPending
            if i.updateAvailable == true {
                let v = i.updateVersion ?? "new"
                if s.notifiedUpdate != v {
                    add(ServerAlert(kind: .serverUpdate, key: "update-\(v)", title: "Server update available",
                                    body: i.updateVersion.map { "\(i.product) \($0) is available." } ?? "A new \(i.product) version is available.",
                                    symbol: "arrow.down.circle", tab: .overview))
                    s.notifiedUpdate = v
                }
            }
        }

        if let p = snap.pluginUpdates {
            let set = p.map { "\($0.id)@\($0.update ?? "")" }.sorted().joined(separator: ",")
            if !p.isEmpty, set != s.pluginSet {
                let names = p.prefix(3).map(\.name).joined(separator: ", ") + (p.count > 3 ? "…" : "")
                add(ServerAlert(kind: .pluginUpdates, key: "plugins-\(set.hashValue)",
                                title: p.count == 1 ? "1 plugin update available" : "\(p.count) plugin updates available",
                                body: names, symbol: "puzzlepiece.extension", tab: .plugins))
            }
            s.pluginSet = p.isEmpty ? nil : set
        }

        if let tasks = snap.tasks {
            for task in tasks {
                guard let r = task.last, let end = r.end?.timeIntervalSince1970 else { continue }
                let seen = s.taskEnds[task.id]
                s.taskEnds[task.id] = end
                guard let seen, end > seen else { continue }
                if r.failed {
                    add(ServerAlert(kind: .taskFailed, key: "task-\(task.id)-\(Int(end))", title: "Task failed: \(task.name)",
                                    body: r.error.map { String($0.prefix(200)) } ?? "The task \(r.status.lowercased()).",
                                    symbol: "exclamationmark.triangle", tab: .tasks))
                } else if task.name.lowercased().contains("scan media library") {
                    add(ServerAlert(kind: .scanFinished, key: "scan-\(Int(end))", title: "Library scan finished",
                                    body: r.duration.map { "Took \(ServerAdminDate.duration($0))." } ?? "The library scan is done.",
                                    symbol: "checkmark.circle", tab: .libraries))
                }
            }
        }

        if let a = snap.activity {
            let after = s.activityAfter ?? t
            let fresh = a.filter { ($0.date?.timeIntervalSince1970 ?? 0) > after && isFailedLogin($0) }
            if !fresh.isEmpty {
                let who = fresh.prefix(3).map { [$0.name, $0.overview].compactMap { $0 }.joined(separator: " · ") }.joined(separator: "\n")
                add(ServerAlert(kind: .failedLogins, key: "logins-\(Int(t))",
                                title: fresh.count == 1 ? "1 failed sign-in" : "\(fresh.count) failed sign-ins",
                                body: who, symbol: "lock.trianglebadge.exclamationmark", tab: .logs))
            }
            let newest = a.compactMap { $0.date?.timeIntervalSince1970 }.max()
            s.activityAfter = max(after, newest ?? after)
        }

        s.baselined = true
        return (out, s)
    }

    /// Jellyfin socket messages that matter here.
    static let socketTypes: Set<String> = ["RestartRequired", "ServerRestarting", "ServerShuttingDown", "ScheduledTaskEnded"]

    /// A socket message → an immediate alert (restart needed / restarting); nil = only poll again soon.
    static func socket(_ type: String, state old: ServerAlertState, now: Date,
                       isOn: (ServerAlertKind) -> Bool = { $0.isOn() }) -> (alert: ServerAlert?, state: ServerAlertState) {
        var s = old
        let t = Int(now.timeIntervalSince1970)
        switch type {
        case "RestartRequired":
            guard !s.restartPending else { return (nil, s) }
            s.restartPending = true
            let a = ServerAlert(kind: .restartNeeded, key: "restart-\(t)", title: "Server restart needed",
                                body: "Restart the server to finish installing updates or changes.", symbol: "arrow.clockwise.circle", tab: .overview)
            return (isOn(.restartNeeded) ? a : nil, s)
        case "ServerRestarting", "ServerShuttingDown":
            guard !s.restarting else { return (nil, s) }
            s.restarting = true
            let restart = type == "ServerRestarting"
            let a = ServerAlert(kind: .power, key: "power-\(t)", title: restart ? "Server is restarting" : "Server is shutting down",
                                body: restart ? "Cove will tell you when it's back." : "The server is going offline.",
                                symbol: "power.circle", tab: .overview)
            return (isOn(.power) ? a : nil, s)
        default: return (nil, s)
        }
    }

    static func stateKey(server: String) -> String { "serverAlerts.state." + server.lowercased() }

    /// The notification (target .server → Manage server on the right tab; no picture).
    static func notification(_ a: ServerAlert, server: String, serverName: String, userId: String) -> NewMediaNotification {
        NewMediaNotification(id: "server-\(a.key)", title: a.title, body: a.body.isEmpty ? serverName : a.body,
                             thread: "cove-server-\(server.lowercased())", target: .server(tab: a.tab.rawValue, symbol: a.symbol),
                             images: [], server: server, userId: userId, libraryId: "",
                             cardTitle: a.title, cardDetail: a.body.isEmpty ? serverName : "\(serverName) · \(a.body)")
    }
}

@MainActor
final class ServerAlertService {
    static let shared = ServerAlertService()
    static let pollInterval: TimeInterval = 300
    static let offlineInterval: TimeInterval = 30
    /// The plugin catalog is heavy (Jellyfin asks its repositories): at most every 6 h.
    static let catalogInterval: TimeInterval = 6 * 3600

    private weak var emby: Emby?
    private var loop: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var key = ""
    private var lastCatalog: Date?
    private var cachedPluginUpdates: [AdminPlugin]?
    private let defaults = UserDefaults.standard
    private let enabled = NSClassFromString("XCTestCase") == nil

    func attach(to emby: Emby) {
        guard enabled, self.emby == nil else { return }
        self.emby = emby
        Publishers.CombineLatest3(emby.$server, emby.$token, emby.$userId)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] s, t, u in MainActor.assumeIsolated { self?.restart(server: s, ok: !t.isEmpty && !u.isEmpty) } }
            .store(in: &bag)
        emby.syncPlay.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] m in
                MainActor.assumeIsolated { if case .other(let type) = m { self?.socket(type) } }
            }
            .store(in: &bag)
    }

    private var anyOn: Bool { ServerAlertKind.allCases.contains { $0.isOn(defaults) } }

    private func restart(server: String, ok: Bool) {
        loop?.cancel(); loop = nil
        cachedPluginUpdates = nil; lastCatalog = nil
        key = ok ? ServerAlertDetector.stateKey(server: server) : ""
        guard ok, !server.isEmpty else { return }
        var st = state(); st.offlineSince = nil; st.offlineNotified = false; st.restarting = false; save(st)
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // let sign-in settle
            while !Task.isCancelled {
                let wait = await self?.poll() ?? Self.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func state() -> ServerAlertState {
        guard let d = defaults.data(forKey: key), let s = try? JSONDecoder().decode(ServerAlertState.self, from: d) else { return ServerAlertState() }
        return s
    }
    private func save(_ s: ServerAlertState) {
        guard !key.isEmpty, let d = try? JSONEncoder().encode(s) else { return }
        defaults.set(d, forKey: key)
    }

    private func isAdmin(_ emby: Emby) async -> Bool {
        if let a = ProfileModel.shared.admin { return a }
        let (d, st) = await emby.adminCall("GET", "/Users/\(emby.userId)")
        return st == 200 && d.flatMap(StatsDecode.isAdministrator) == true
    }

    /// One round; returns the wait before the next.
    private func poll() async -> TimeInterval {
        guard let emby, anyOn, !emby.token.isEmpty else { return Self.pollInterval }
        let myKey = key
        let (pub, pst) = await emby.adminCall("GET", "/System/Info/Public")
        _ = pub
        var snap = ServerAlertSnapshot(reachable: pst == 200)
        if snap.reachable {
            guard await isAdmin(emby) else { return Self.pollInterval }
            let kind: ServerAdminKind = emby.isJellyfin ? .jellyfin : .emby
            if case let (d?, 200) = await emby.adminCall("GET", "/System/Info") { snap.info = ServerAdminInfo.decode(d, kind: kind) }
            if case let (d?, 200) = await emby.adminCall("GET", "/ScheduledTasks?IsHidden=false") { snap.tasks = ServerTask.decodeList(d) }
            if case let (d?, 200) = await emby.adminCall("GET", ActivityAdminAPI.entries.path) { snap.activity = AdminActivity.decodeList(d) }
            if ServerAlertKind.pluginUpdates.isOn(defaults) {
                if lastCatalog == nil || Date().timeIntervalSince(lastCatalog!) > Self.catalogInterval {
                    if case let (d?, 200) = await emby.adminCall("GET", "/Plugins"), let plugins = AdminPlugin.decodeList(d),
                       case let (cd?, 200) = await emby.adminCall("GET", PluginAdminAPI.catalog(kind).path) {
                        cachedPluginUpdates = PluginUpdates.apply(plugins, packages: AdminPackage.decodeList(cd)).filter { $0.update != nil }
                        lastCatalog = Date()
                    }
                }
                snap.pluginUpdates = cachedPluginUpdates
            }
        }
        guard myKey == key else { return Self.pollInterval }   // switched server meanwhile
        let (alerts, st) = ServerAlertDetector.detect(snap, state: state(), now: Date(), isOn: { $0.isOn(self.defaults) })
        save(st)
        for a in alerts { await post(a) }
        return snap.reachable ? Self.pollInterval : Self.offlineInterval
    }

    private func socket(_ type: String) {
        guard ServerAlertDetector.socketTypes.contains(type), !key.isEmpty, ProfileModel.shared.admin == true else { return }
        let (a, st) = ServerAlertDetector.socket(type, state: state(), now: Date(), isOn: { $0.isOn(self.defaults) })
        save(st)
        if let a { Task { await post(a) } }
        // A restart / task end: look again soon (back online, failed task)
        if type != "RestartRequired" {
            loop?.cancel()
            let server = emby?.server ?? ""
            let k = key
            loop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.key == k, !server.isEmpty else { return }
                while !Task.isCancelled {
                    let wait = await self.poll()
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
    }

    private func post(_ a: ServerAlert) async {
        guard let emby else { return }
        DebugLog.write("Server alerts: \(a.kind.rawValue)")
        let n = ServerAlertDetector.notification(a, server: emby.server, serverName: emby.currentServerName, userId: emby.userId)
        await NewMediaService.shared.postServerAlert(n)
    }
}
