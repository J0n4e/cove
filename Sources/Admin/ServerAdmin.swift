import Foundation

// Server management, phase 1 (admins only): Overview + Tasks. Pure decoding and logic live here, apart from the
// views (Glass3DServerWindow.swift), so everything can be tested without a server. The network goes through ONE
// injectable closure (`ServerAdminAPI.call`).

// MARK: - Server kind (the small Emby / Jellyfin differences)

enum ServerAdminKind: Equatable {
    case emby, jellyfin

    var product: String { self == .jellyfin ? "Jellyfin" : "Emby" }
    /// Emby reports a pending server update in /System/Info; Jellyfin has no update API (only shown if the field exists).
    var reportsUpdates: Bool { self == .emby }
}

// MARK: - /System/Info

struct ServerAdminInfo: Equatable {
    var name: String
    var product: String
    var version: String
    var os: String
    var localAddress: String?
    var wanAddress: String?
    /// nil: the server doesn't say (Jellyfin).
    var updateAvailable: Bool?
    var updateVersion: String?
    var restartPending: Bool
    var cachePath: String?
    var transcodePath: String?
    var logPath: String?
    var startTime: Date?

    /// Both server shapes. Tolerant: missing fields stay empty/nil rather than failing the whole card.
    static func decode(_ data: Data, kind: ServerAdminKind) -> ServerAdminInfo? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func s(_ k: String) -> String? {
            guard let v = o[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }
        func b(_ k: String) -> Bool? { (o[k] as? Bool) ?? (o[k] as? NSNumber)?.boolValue }
        let product = s("ProductName").map { $0.localizedCaseInsensitiveContains("jellyfin") ? "Jellyfin" : ($0.localizedCaseInsensitiveContains("emby") ? "Emby" : $0) } ?? kind.product
        let local = s("LocalAddress") ?? (o["LocalAddresses"] as? [String])?.first
        let wan = s("WanAddress") ?? (o["RemoteAddresses"] as? [String])?.first
        return ServerAdminInfo(
            name: s("ServerName") ?? "",
            product: product,
            version: s("Version") ?? "",
            os: s("OperatingSystemDisplayName") ?? s("OperatingSystem") ?? "",
            localAddress: local, wanAddress: wan,
            updateAvailable: b("HasUpdateAvailable"),
            updateVersion: s("UpdateVersion") ?? s("AvailableUpdateVersion"),
            restartPending: b("HasPendingRestart") ?? false,
            cachePath: s("CachePath"),
            transcodePath: s("TranscodingTempPath") ?? s("TranscodeTempPath"),
            logPath: s("LogPath"),
            startTime: s("StartTime").flatMap(ServerAdminDate.parse) ?? s("ServerStartTime").flatMap(ServerAdminDate.parse))
    }

    /// "Update available: 4.9.1" / "Update available" / nil (none, or the server can't tell).
    var updateLine: String? {
        guard updateAvailable == true else { return nil }
        if let v = updateVersion { return "Update available: \(v)" }
        return "Update available"
    }
}

// MARK: - Dates

enum ServerAdminDate {
    /// "2026-11-20T03:00:12.1234567Z", "...+00:00", without fraction. Year 0001 (Emby's "never") → nil.
    static func parse(_ s: String) -> Date? {
        let plain = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var d = f.date(from: plain)
        if d == nil {   // no zone given: the servers mean UTC
            d = f.date(from: plain + "Z")
        }
        guard let d, d.timeIntervalSince1970 > 0 else { return nil }
        return d
    }

    /// "4 s", "1 min 4 s", "2 h 5 min".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) min"
    }

    static func relative(_ d: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: now)
    }
}

// MARK: - /ScheduledTasks

struct ServerTask: Identifiable, Equatable {
    enum State: Equatable { case idle, running, cancelling }
    struct Result: Equatable {
        var status: String
        var start: Date?
        var end: Date?
        var error: String?
        var failed: Bool { ["failed", "aborted"].contains(status.lowercased()) }
        var duration: TimeInterval? {
            guard let start, let end, end >= start else { return nil }
            return end.timeIntervalSince(start)
        }
    }

    var id: String
    var name: String
    var description: String
    var category: String
    var hidden: Bool
    var state: State
    /// 0…100 while running.
    var progress: Double?
    var last: Result?
    var triggers: [String]

    var running: Bool { state != .idle }

    static func decodeList(_ data: Data) -> [ServerTask]? {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return a.compactMap(decode)
    }

    static func decode(_ o: [String: Any]) -> ServerTask? {
        guard let id = o["Id"] as? String, !id.isEmpty else { return nil }
        let stateText = ((o["State"] as? String) ?? "Idle").lowercased()
        let state: State = stateText == "running" ? .running : (stateText == "cancelling" ? .cancelling : .idle)
        var last: Result?
        if let r = o["LastExecutionResult"] as? [String: Any] {
            last = Result(status: (r["Status"] as? String) ?? "",
                          start: (r["StartTimeUtc"] as? String).flatMap(ServerAdminDate.parse),
                          end: (r["EndTimeUtc"] as? String).flatMap(ServerAdminDate.parse),
                          error: (r["ErrorMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        let progress = (o["CurrentProgressPercentage"] as? NSNumber)?.doubleValue
        let triggers = ((o["Triggers"] as? [[String: Any]]) ?? []).compactMap(triggerText)
        return ServerTask(id: id, name: (o["Name"] as? String) ?? id,
                          description: (o["Description"] as? String) ?? "",
                          category: ((o["Category"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "Other",
                          hidden: (o["IsHidden"] as? Bool) ?? false,
                          state: state, progress: state == .idle ? nil : progress.map { min(100, max(0, $0)) },
                          last: last, triggers: triggers)
    }

    /// "Every 12 h", "Daily at 03:00", "Sundays at 02:30", "At startup". Unknown kinds are left out.
    static func triggerText(_ t: [String: Any]) -> String? {
        let ticks = 10_000_000.0
        let type = (t["Type"] as? String) ?? ""
        func hm(_ v: Any?) -> String? {
            guard let n = (v as? NSNumber)?.doubleValue else { return nil }
            let m = Int(n / ticks / 60)
            return String(format: "%02d:%02d", (m / 60) % 24, m % 60)
        }
        switch type {
        case "IntervalTrigger":
            guard let n = (t["IntervalTicks"] as? NSNumber)?.doubleValue, n > 0 else { return nil }
            let min = Int(n / ticks / 60)
            if min % 1440 == 0 { return min == 1440 ? "Every day" : "Every \(min / 1440) days" }
            if min % 60 == 0 { return "Every \(min / 60) h" }
            return "Every \(min) min"
        case "DailyTrigger": return hm(t["TimeOfDayTicks"]).map { "Daily at \($0)" }
        case "WeeklyTrigger":
            guard let at = hm(t["TimeOfDayTicks"]) else { return nil }
            return "\((t["DayOfWeek"] as? String) ?? "Weekly")s at \(at)"
        case "StartupTrigger": return "At startup"
        default: return nil
        }
    }
}

/// The task list as shown: filtered, a "Common" section first, then the server's categories A→Z.
enum ServerTaskGrouping {
    static let commonSection = "Common"
    /// Matched by name (lower-cased, contains), in this order.
    static let commonNames = ["scan media library", "refresh people", "download missing subtitles",
                              "refresh guide", "refresh chapter images", "extract chapter images", "clean transcode"]

    static func commonRank(_ t: ServerTask) -> Int? {
        let n = t.name.lowercased()
        return commonNames.firstIndex { n.contains($0) }
    }

    static func matches(_ t: ServerTask, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [t.name, t.description, t.category].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    static func sections(_ tasks: [ServerTask], query: String = "") -> [(title: String, tasks: [ServerTask])] {
        let visible = tasks.filter { !$0.hidden && matches($0, query) }
        let common = visible.filter { commonRank($0) != nil }.sorted { commonRank($0)! < commonRank($1)! }
        let rest = visible.filter { commonRank($0) == nil }
        var out: [(title: String, tasks: [ServerTask])] = []
        if !common.isEmpty { out.append((commonSection, common)) }
        let cats = Dictionary(grouping: rest, by: \.category)
        for c in cats.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            out.append((c, cats[c]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
        }
        return out
    }

    /// Poll every 2 s while anything runs, else every 30 s.
    static func pollInterval(_ tasks: [ServerTask]) -> Double { tasks.contains { $0.running } ? 2 : 30 }
}

// MARK: - /Sessions

enum ServerAdminSessions {
    /// Sessions that are playing something right now.
    static func activeStreams(_ data: Data) -> Int? {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return a.filter { $0["NowPlayingItem"] is [String: Any] }.count
    }
}

// MARK: - Restart wait

enum ServerRestartWait {
    enum Outcome: Equatable { case back, timedOut }

    /// Polls `isUp` (GET /System/Info/Public) until the server is back. The server can still answer for a moment
    /// after accepting the restart, so "back" needs either a seen outage followed by an answer, or an answer once
    /// `graceUp` seconds have passed. Gives up after `timeout` (3 min).
    static func wait(isUp: () async -> Bool, sleep: (Double) async -> Void, elapsed: () -> TimeInterval,
                     interval: Double = 2, graceUp: TimeInterval = 20, timeout: TimeInterval = 180) async -> Outcome {
        var sawDown = false
        while elapsed() < timeout {
            await sleep(interval)
            if Task.isCancelled { return .timedOut }
            let up = await isUp()
            if !up { sawDown = true; continue }
            if sawDown || elapsed() >= graceUp { return .back }
        }
        return .timedOut
    }
}

// MARK: - Network seam

struct ServerAdminAPI {
    /// (method, path) → (body, HTTP status; 0 = no answer). Paths start with "/".
    var call: (_ method: String, _ path: String) async -> (Data?, Int)
    var userId: String
    /// With a JSON body (phase 2). nil: falls back to `call` without a body (tests of phase 1).
    var send: ((_ method: String, _ path: String, _ body: Data?) async -> (Data?, Int))? = nil

    func request(_ r: AdminRequest) async -> (Data?, Int) {
        if let send { return await send(r.method, r.path, r.body) }
        return await call(r.method, r.path)
    }
}

extension Emby {
    /// One authorised request for the admin panel. Never logs the token or the full URL.
    func adminCall(_ method: String, _ path: String, body: Data? = nil) async -> (Data?, Int) {
        guard let u = URL(string: server + path) else { return (nil, 0) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = method
        authorize(&r)
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (d, resp) = try? await Net.session.data(for: r) else { return (nil, 0) }
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Model

@MainActor
final class ServerAdmin: ObservableObject {
    enum Tab: Int, CaseIterable, Identifiable {
        case overview, tasks, users, libraries
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .tasks: return "Tasks"
            case .users: return "Users"
            case .libraries: return "Libraries"
            }
        }
    }
    enum Power: Equatable { case none, restarting, shuttingDown, back, timedOut, shutDown, failed(String) }

    @Published var info: ServerAdminInfo?
    @Published var infoError: String?
    @Published var streams: Int?
    @Published var tasks: [ServerTask] = []
    @Published var tasksLoaded = false
    @Published var tasksError: String?
    @Published var forbidden = false
    @Published var power: Power = .none
    @Published var message: String?

    let kind: ServerAdminKind
    let api: ServerAdminAPI
    var sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    init(kind: ServerAdminKind, api: ServerAdminAPI) {
        self.kind = kind
        self.api = api
    }

    static func live(_ emby: Emby) -> ServerAdmin {
        ServerAdmin(kind: emby.isJellyfin ? .jellyfin : .emby,
                    api: ServerAdminAPI(call: { [weak emby] m, p in await emby?.adminCall(m, p) ?? (nil, 0) }, userId: emby.userId,
                                        send: { [weak emby] m, p, b in await emby?.adminCall(m, p, body: b) ?? (nil, 0) }))
    }

    private func denied(_ status: Int) -> Bool {
        if status == 401 || status == 403 { forbidden = true; return true }
        return false
    }

    /// Checks the admin flag again when the window opens (the menu row could be stale).
    func checkAdmin() async {
        guard !api.userId.isEmpty else { return }
        let (d, st) = await api.call("GET", "/Users/\(api.userId)")
        if denied(st) { return }
        if st == 200, let d, StatsDecode.isAdministrator(d) == false { forbidden = true }
    }

    func loadOverview() async {
        let (d, st) = await api.call("GET", "/System/Info")
        if denied(st) { return }
        if st == 200, let d, let i = ServerAdminInfo.decode(d, kind: kind) { info = i; infoError = nil }
        else { infoError = "Couldn't read the server info." }
        let (sd, sst) = await api.call("GET", "/Sessions?ActiveWithinSeconds=960")
        streams = sst == 200 ? sd.flatMap(ServerAdminSessions.activeStreams) : nil
    }

    func loadTasks() async {
        let (d, st) = await api.call("GET", "/ScheduledTasks?IsHidden=false")
        if denied(st) { return }
        if st == 200, let d, let t = ServerTask.decodeList(d) { tasks = t; tasksError = nil }
        else if !tasksLoaded || st != 0 { tasksError = "Couldn't read the scheduled tasks." }
        tasksLoaded = true
    }

    /// The Tasks tab's loop (cancelled when the tab goes away): 2 s while a task runs, else 30 s.
    func pollTasks() async {
        while !Task.isCancelled {
            await loadTasks()
            if forbidden { return }
            await sleep(ServerTaskGrouping.pollInterval(tasks))
        }
    }

    func run(_ t: ServerTask) async {
        let (_, st) = await api.call("POST", "/ScheduledTasks/Running/\(t.id)")
        if denied(st) { return }
        if (200..<300).contains(st), let i = tasks.firstIndex(where: { $0.id == t.id }) {
            tasks[i].state = .running; tasks[i].progress = 0
        } else if !(200..<300).contains(st) { message = "Couldn't start \u{201C}\(t.name)\u{201D}." }
        await loadTasks()
    }

    func stop(_ t: ServerTask) async {
        let (_, st) = await api.call("DELETE", "/ScheduledTasks/Running/\(t.id)")
        if denied(st) { return }
        if !(200..<300).contains(st) { message = "Couldn't stop \u{201C}\(t.name)\u{201D}." }
        await loadTasks()
    }

    func scanAll() async {
        let (_, st) = await api.call("POST", "/Library/Refresh")
        if denied(st) { return }
        message = (200..<300).contains(st) ? "Library scan started." : "Couldn't start the library scan."
    }

    func shutdown() async {
        let (_, st) = await api.call("POST", "/System/Shutdown")
        if denied(st) { return }
        power = (200..<300).contains(st) ? .shutDown : .failed("The server didn't accept the shutdown.")
    }

    func restart() async {
        let (_, st) = await api.call("POST", "/System/Restart")
        if denied(st) { return }
        guard (200..<300).contains(st) else { power = .failed("The server didn't accept the restart."); return }
        power = .restarting
        let start = Date()
        let out = await ServerRestartWait.wait(
            isUp: { [api] in await api.call("GET", "/System/Info/Public").1 == 200 },
            sleep: sleep, elapsed: { Date().timeIntervalSince(start) })
        power = out == .back ? .back : .timedOut
        if out == .back { await loadOverview(); await loadTasks() }
    }
}
