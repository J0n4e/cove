import Foundation

// Server management, phases 3-4 (admins only): Devices, Plugins, Logs + Activity log, and the admin actions on the
// Activity → Now Playing cards. Pure request shapes, decoding and rules live here (tested in
// Tests/ServerAdminP3Tests.swift); the views are in Sources/Classic/Glass3DServerDevices.swift,
// Glass3DServerLogs.swift and Glass3DSessionAdmin.swift. Nothing here logs a token.

private func adminBool(_ v: Any?) -> Bool? { (v as? Bool) ?? (v as? NSNumber)?.boolValue }
private func adminString(_ o: [String: Any], _ keys: String...) -> String? {
    for k in keys { if let s = o[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s } }
    return nil
}
private func adminItems(_ data: Data) -> [[String: Any]]? {
    let j = try? JSONSerialization.jsonObject(with: data)
    return (j as? [[String: Any]]) ?? ((j as? [String: Any])?["Items"] as? [[String: Any]])
}

// MARK: - Devices

struct AdminDevice: Identifiable, Equatable {
    /// The id the /Devices calls take (Emby: its internal number; Jellyfin: the device id).
    let id: String
    /// The id the client reports (Emby: ReportedDeviceId; Jellyfin: the same as `id`). Compared with Cove's own.
    let deviceId: String
    var name: String
    var customName: String?
    var appName: String
    var appVersion: String
    var lastUser: String?
    var lastSeen: Date?

    var displayName: String { customName ?? name }

    static func decode(_ o: [String: Any]) -> AdminDevice? {
        guard let id = adminString(o, "Id") else { return nil }
        let name = adminString(o, "Name") ?? id
        return AdminDevice(id: id, deviceId: adminString(o, "ReportedDeviceId") ?? id, name: name,
                           customName: adminString(o, "CustomName").flatMap { $0 == name ? nil : $0 },
                           appName: adminString(o, "AppName") ?? "", appVersion: adminString(o, "AppVersion") ?? "",
                           lastUser: adminString(o, "LastUserName"),
                           lastSeen: adminString(o, "DateLastActivity").flatMap(ServerAdminDate.parse))
    }

    /// GET /Devices: {Items:[…]} on both servers (a bare array is accepted too). Newest activity first.
    static func decodeList(_ data: Data) -> [AdminDevice]? {
        guard let a = adminItems(data) else { return nil }
        return sorted(a.compactMap(decode))
    }

    static func sorted(_ d: [AdminDevice]) -> [AdminDevice] {
        d.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    func isOwn(_ myDeviceId: String) -> Bool { !myDeviceId.isEmpty && (deviceId == myDeviceId || id == myDeviceId) }

    static func matches(_ d: AdminDevice, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [d.displayName, d.name, d.appName, d.lastUser ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var icon: String { NowPlayingStyle.clientIcon(client: appName, device: name) }
}

enum DeviceAdminAPI {
    static let list = AdminRequest(method: "GET", path: "/Devices")
    /// Emby: Id=; Jellyfin: id= (both read the CustomName from the body).
    static func idParam(_ kind: ServerAdminKind) -> String { kind == .jellyfin ? "id" : "Id" }
    static func rename(_ d: AdminDevice, to name: String, kind: ServerAdminKind) -> AdminRequest {
        .json("POST", "/Devices/Options?\(idParam(kind))=\(AdminQuery.q(d.id))",
              ["CustomName": name.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
    static func remove(_ id: String, kind: ServerAdminKind) -> AdminRequest {
        AdminRequest(method: "DELETE", path: "/Devices?\(idParam(kind))=\(AdminQuery.q(id))")
    }
    /// nil = allowed; else why not. Cove never signs its own Mac out.
    static func removeBlocked(_ d: AdminDevice, myDeviceId: String) -> String? {
        d.isOwn(myDeviceId) ? "This is this Mac. Sign out from the profile menu instead." : nil
    }
}

// MARK: - Now Playing session actions

enum SessionAdminAPI {
    static let messageLimit = 200
    static func clampMessage(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(messageLimit))
    }
    static func message(_ sessionId: String, text: String) -> AdminRequest {
        .json("POST", "/Sessions/\(AdminQuery.q(sessionId))/Message",
              ["Header": "Cove", "Text": clampMessage(text), "TimeoutMs": 8000])
    }
    static func stop(_ sessionId: String) -> AdminRequest {
        AdminRequest(method: "POST", path: "/Sessions/\(AdminQuery.q(sessionId))/Playing/Stop")
    }
    /// Admin actions show on other people's sessions only (never on Cove's own).
    static func offersActions(isAdmin: Bool?, sessionDeviceId: String?, myDeviceId: String) -> Bool {
        isAdmin == true && (sessionDeviceId ?? "") != myDeviceId
    }
    /// The /Devices entry for a session's device (Emby reports it as ReportedDeviceId).
    static func device(for sessionDeviceId: String, in devices: [AdminDevice]) -> AdminDevice? {
        devices.first { $0.deviceId == sessionDeviceId } ?? devices.first { $0.id == sessionDeviceId }
    }
}

/// The 'i' popover: what the server is doing with the stream.
enum StreamDetails {
    struct Row: Equatable { let label: String; let value: String }

    static func codec(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0.uppercased() } }

    static func bitrate(_ b: Int?) -> String? {
        guard let b, b > 0 else { return nil }
        return b >= 1_000_000 ? String(format: "%.1f Mbps", Double(b) / 1_000_000) : "\(b / 1000) kbps"
    }

    /// "Local" for private / loopback addresses, else "Remote".
    static func network(_ ip: String?) -> String? {
        guard var h = ip?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("::ffff:") { h.removeFirst(7) }
        let p = h.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            if p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) { return "Local" }
            return "Remote"
        }
        let l = h.lowercased()
        return l == "::1" || l.hasPrefix("fe80") || l.hasPrefix("fd") || l.hasPrefix("fc") ? "Local" : "Remote"
    }

    static func rows(_ s: ActiveSession) -> [Row] {
        var out: [Row] = []
        let method = NowPlayingStyle.playMethod(s.PlayState?.PlayMethod).label
        out.append(Row(label: "Playback", value: method))
        let streams = s.NowPlayingItem?.MediaStreams ?? []
        let vIn = codec(streams.first { $0.`Type` == "Video" }?.Codec)
        let aIn = codec(streams.first { $0.`Type` == "Audio" && $0.IsDefault == true }?.Codec ?? streams.first { $0.`Type` == "Audio" }?.Codec)
        let t = s.TranscodingInfo
        func flow(_ input: String?, _ output: String?, direct: Bool?) -> String? {
            if direct == true || (t == nil) { return input.map { "\($0) (direct)" } }
            switch (input, output) {
            case let (i?, o?): return i == o ? "\(i) (copied)" : "\(i) → \(o)"
            case let (nil, o?): return "→ \(o)"
            case let (i?, nil): return i
            default: return nil
            }
        }
        if let v = flow(vIn, codec(t?.VideoCodec), direct: t?.IsVideoDirect) { out.append(Row(label: "Video", value: v)) }
        if let a = flow(aIn, codec(t?.AudioCodec), direct: t?.IsAudioDirect) { out.append(Row(label: "Audio", value: a)) }
        if let b = bitrate(t?.Bitrate) { out.append(Row(label: "Bitrate", value: b)) }
        if let r = t?.TranscodeReasons, !r.isEmpty { out.append(Row(label: "Reason", value: r.map(reason).joined(separator: ", "))) }
        let client = [s.Client, s.ApplicationVersion].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        if !client.isEmpty { out.append(Row(label: "Client", value: client)) }
        if let d = s.DeviceName, !d.isEmpty { out.append(Row(label: "Device", value: d)) }
        if let ip = s.RemoteEndPoint, !ip.isEmpty {
            out.append(Row(label: "Address", value: ip + (network(ip).map { " · \($0)" } ?? "")))
        }
        return out
    }

    /// "VideoCodecNotSupported" → "Video codec not supported".
    static func reason(_ r: String) -> String {
        var words: [String] = [], cur = ""
        for ch in r {
            if ch.isUppercase, !cur.isEmpty, !(cur.last?.isUppercase ?? false) { words.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { words.append(cur) }
        guard let first = words.first else { return r }
        return ([first] + words.dropFirst().map { $0.count > 1 && $0 == $0.uppercased() ? $0 : $0.lowercased() }).joined(separator: " ")
    }
}

// MARK: - Plugins

struct AdminPlugin: Identifiable, Equatable {
    let id: String
    var name: String
    var version: String
    var description: String
    /// Jellyfin: Active / Restart / Disabled / Malfunctioned / …; Emby: nil.
    var status: String?
    var canUninstall: Bool
    var update: String?

    var statusTitle: String? {
        switch status?.lowercased() {
        case nil: return nil
        case "active": return "Active"
        case "restart": return "Restart required"
        case "disabled": return "Disabled"
        case "malfunctioned": return "Failed to load"
        case "notsupported": return "Not supported"
        case "superceded", "superseded": return "Replaced"
        case "deleted": return "Removed (restart)"
        default: return status
        }
    }
    var isDisabled: Bool { status?.lowercased() == "disabled" }
    var needsRestart: Bool { ["restart", "deleted"].contains(status?.lowercased() ?? "") }

    static func decodeList(_ data: Data) -> [AdminPlugin]? {
        guard let a = adminItems(data) else { return nil }
        return a.compactMap { o in
            guard let id = adminString(o, "Id") else { return nil }
            return AdminPlugin(id: id, name: adminString(o, "Name") ?? id, version: adminString(o, "Version") ?? "",
                               description: adminString(o, "Description") ?? "", status: adminString(o, "Status"),
                               canUninstall: adminBool(o["CanUninstall"]) ?? true, update: nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One installable package version from /Packages (Jellyfin) or /Packages/Updates (Emby).
struct AdminPackage: Equatable {
    let name: String
    let guid: String
    let version: String

    /// Jellyfin /Packages: [{name, guid, versions:[{version, targetAbi}]}] (lower-case keys; Pascal accepted).
    /// Emby /Packages/Updates: [{name, guid, versionStr}]. The newest version per package.
    static func decodeList(_ data: Data) -> [AdminPackage] {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return a.compactMap { o in
            guard let name = adminString(o, "name", "Name"), let guid = adminString(o, "guid", "Guid", "Id") else { return nil }
            var versions = ((o["versions"] ?? o["Versions"]) as? [[String: Any]] ?? []).compactMap { adminString($0, "version", "Version", "versionStr") }
            if let v = adminString(o, "versionStr", "version", "Version") { versions.append(v) }
            guard let best = versions.max(by: { PluginUpdates.compare($0, $1) < 0 }) else { return nil }
            return AdminPackage(name: name, guid: guid, version: best)
        }
    }
}

enum PluginUpdates {
    /// -1 / 0 / 1 by numeric parts ("10.9.2.0" == "10.9.2").
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
        var x = parts(a), y = parts(b)
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        for (p, q) in zip(x, y) where p != q { return p < q ? -1 : 1 }
        return 0
    }

    static func sameGuid(_ a: String, _ b: String) -> Bool { UserAdminAPI.sameId(a, b) }

    /// Fills `update` where the catalog has a newer version of the same plugin (matched by guid, else name).
    static func apply(_ plugins: [AdminPlugin], packages: [AdminPackage]) -> [AdminPlugin] {
        plugins.map { p in
            var p = p
            let pkg = packages.first { sameGuid($0.guid, p.id) } ?? packages.first { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }
            if let pkg, compare(pkg.version, p.version) > 0 { p.update = pkg.version } else { p.update = nil }
            return p
        }
    }

    static func package(for p: AdminPlugin, in packages: [AdminPackage]) -> AdminPackage? {
        packages.first { sameGuid($0.guid, p.id) } ?? packages.first { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }
    }
}

enum PluginAdminAPI {
    static let list = AdminRequest(method: "GET", path: "/Plugins")
    static func catalog(_ kind: ServerAdminKind) -> AdminRequest {
        AdminRequest(method: "GET", path: kind == .jellyfin ? "/Packages" : "/Packages/Updates")
    }
    static func enable(_ p: AdminPlugin, _ on: Bool) -> AdminRequest {
        AdminRequest(method: "POST", path: "/Plugins/\(AdminQuery.q(p.id))/\(AdminQuery.q(p.version))/\(on ? "Enable" : "Disable")")
    }
    /// Jellyfin: DELETE /Plugins/{id}/{version}; Emby: DELETE /Plugins/{id}.
    static func uninstall(_ p: AdminPlugin, kind: ServerAdminKind) -> AdminRequest {
        AdminRequest(method: "DELETE", path: kind == .jellyfin ? "/Plugins/\(AdminQuery.q(p.id))/\(AdminQuery.q(p.version))"
                                                               : "/Plugins/\(AdminQuery.q(p.id))")
    }
    static func install(_ pkg: AdminPackage, kind: ServerAdminKind) -> AdminRequest {
        let g = kind == .jellyfin ? "assemblyGuid" : "AssemblyGuid", v = kind == .jellyfin ? "version" : "Version"
        return AdminRequest(method: "POST", path: "/Packages/Installed/\(AdminQuery.q(pkg.name))?\(g)=\(AdminQuery.q(pkg.guid))&\(v)=\(AdminQuery.q(pkg.version))")
    }
    /// Enable / disable / uninstall need Jellyfin's plugin manager (Emby: uninstall only).
    static func canToggle(_ kind: ServerAdminKind) -> Bool { kind == .jellyfin }
}

// MARK: - Logs

struct AdminLogFile: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let size: Int64?
    let modified: Date?

    static func decodeList(_ data: Data) -> [AdminLogFile]? {
        guard let a = adminItems(data) else { return nil }
        return a.compactMap { o in
            guard let n = adminString(o, "Name") else { return nil }
            return AdminLogFile(name: n, size: (o["Size"] as? NSNumber)?.int64Value,
                                modified: adminString(o, "DateModified", "DateCreated").flatMap(ServerAdminDate.parse))
        }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    var sizeText: String { size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "" }
}

enum LogLevel: String, CaseIterable, Equatable { case error = "Error", warn = "Warn", info = "Info", debug = "Debug" }

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let level: LogLevel?
}

enum LogAdminAPI {
    static let maxLines = 2000
    static let list = AdminRequest(method: "GET", path: "/System/Logs")
    /// Jellyfin: /System/Logs/Log?name=; Emby: /System/Logs/{name}.
    static func file(_ name: String, kind: ServerAdminKind) -> AdminRequest {
        AdminRequest(method: "GET", path: kind == .jellyfin ? "/System/Logs/Log?name=\(AdminQuery.q(name))" : "/System/Logs/\(AdminQuery.q(name))")
    }

    /// Jellyfin: "[2026-11-20 10:00:00.123 +00:00] [ERR] [12] …"; Emby: "2026-11-20 10:00:00.123 Error Main: …".
    static func level(_ line: String) -> LogLevel? {
        let head = String(line.prefix(64))
        if let r = head.range(of: #"\[(FTL|ERR|WRN|INF|DBG|VRB)\]"#, options: .regularExpression) {
            switch head[r] {
            case "[FTL]", "[ERR]": return .error
            case "[WRN]": return .warn
            case "[INF]": return .info
            default: return .debug
            }
        }
        if let r = head.range(of: #"^\S+ \S+ (Fatal|Error|Warn|Warning|Info|Debug|Trace)\b"#, options: .regularExpression) {
            let w = head[r].split(separator: " ").last.map(String.init) ?? ""
            switch w {
            case "Fatal", "Error": return .error
            case "Warn", "Warning": return .warn
            case "Info": return .info
            default: return .debug
            }
        }
        return nil
    }

    /// The last `maxLines` lines; a line without a level (stack trace) inherits the one above.
    static func parse(_ text: String, limit: Int = maxLines) -> [LogLine] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let tail = lines.suffix(limit)
        var out: [LogLine] = [], last: LogLevel?
        for (i, l) in tail.enumerated() {
            let lv = level(l) ?? (l.first?.isWhitespace == true || l.hasPrefix("at ") ? last : nil)
            if lv != nil { last = lv }
            out.append(LogLine(id: i, text: l, level: lv))
        }
        return out
    }

    /// The level chips filter: empty = everything. Lines without a level only show unfiltered.
    static func filter(_ lines: [LogLine], levels: Set<LogLevel>, query: String) -> [LogLine] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return lines.filter { l in
            (levels.isEmpty || l.level.map { levels.contains($0) } == true) && (q.isEmpty || l.text.localizedCaseInsensitiveContains(q))
        }
    }

    static func hasLevels(_ lines: [LogLine]) -> Bool { lines.contains { $0.level != nil } }

    /// A safe file name for ~/Downloads.
    static func downloadName(_ name: String) -> String {
        let s = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        return s.isEmpty ? "server.log" : s
    }
}

// MARK: - Activity log

struct AdminActivity: Identifiable, Equatable {
    enum Severity: Equatable { case info, warning, error }
    let id: String
    let name: String
    let overview: String?
    let type: String
    let date: Date?
    let userId: String?
    let severity: Severity

    static func decodeList(_ data: Data) -> [AdminActivity]? {
        guard let a = adminItems(data) else { return nil }
        return a.compactMap { o in
            let id = adminString(o, "Id") ?? (o["Id"] as? NSNumber)?.stringValue
            guard let id else { return nil }
            let sev = (adminString(o, "Severity") ?? "").lowercased()
            return AdminActivity(id: id, name: adminString(o, "Name") ?? "", overview: adminString(o, "ShortOverview", "Overview"),
                                 type: adminString(o, "Type") ?? "", date: adminString(o, "Date").flatMap(ServerAdminDate.parse),
                                 userId: adminString(o, "UserId").flatMap { $0.allSatisfy { $0 == "0" || $0 == "-" } ? nil : $0 },
                                 severity: sev.hasPrefix("err") || sev == "critical" || sev == "fatal" ? .error : (sev.hasPrefix("warn") ? .warning : .info))
        }
    }

    var isLogin: Bool {
        let t = type.lowercased()
        return t.contains("authentication") || t.contains("session") || t.contains("login") || t.contains("signedin")
    }
    var failed: Bool { severity == .error || type.lowercased().contains("failed") }

    var icon: String {
        let t = type.lowercased()
        if t.contains("authenticationfailed") { return "lock.trianglebadge.exclamationmark" }
        if isLogin { return "person.crop.circle" }
        if t.contains("playback") || t.contains("videoplayback") { return "play.circle" }
        if t.contains("task") { return "clock.arrow.circlepath" }
        if t.contains("plugin") || t.contains("package") { return "puzzlepiece.extension" }
        if t.contains("user") { return "person.2" }
        if t.contains("subtitle") { return "captions.bubble" }
        return severity == .error ? "exclamationmark.triangle" : "info.circle"
    }

    enum Filter: Int, CaseIterable { case all, errors, logins
        var title: String { ["All", "Errors only", "Logins"][rawValue] }
    }
    static func filter(_ a: [AdminActivity], _ f: Filter) -> [AdminActivity] {
        switch f {
        case .all: return a
        case .errors: return a.filter { $0.severity == .error || $0.failed }
        case .logins: return a.filter(\.isLogin)
        }
    }
}

enum ActivityAdminAPI {
    static let entries = AdminRequest(method: "GET", path: "/System/ActivityLog/Entries?startIndex=0&limit=100")
}

// MARK: - Models

@MainActor
final class ServerDevicesModel: ObservableObject {
    @Published var devices: [AdminDevice] = []
    @Published var loaded = false
    @Published var error: String?
    let kind: ServerAdminKind
    let api: ServerAdminAPI
    let myDeviceId: String

    init(kind: ServerAdminKind, api: ServerAdminAPI, myDeviceId: String) { self.kind = kind; self.api = api; self.myDeviceId = myDeviceId }

    func load() async {
        let (d, st) = await api.request(DeviceAdminAPI.list)
        if st == 200, let d, let l = AdminDevice.decodeList(d) { devices = l; error = nil }
        else { error = AdminMessage.text(status: st == 200 ? 500 : st, action: "read the devices") }
        loaded = true
    }

    func rename(_ d: AdminDevice, to name: String) async -> String? {
        let (_, st) = await api.request(DeviceAdminAPI.rename(d, to: name, kind: kind))
        if let m = AdminMessage.text(status: st, action: "rename the device") { return m }
        await load(); return nil
    }

    func remove(_ d: AdminDevice) async -> String? {
        if let m = DeviceAdminAPI.removeBlocked(d, myDeviceId: myDeviceId) { return m }
        let (_, st) = await api.request(DeviceAdminAPI.remove(d.id, kind: kind))
        if let m = AdminMessage.text(status: st, action: "remove the device") { return m }
        await load(); return nil
    }
}

@MainActor
final class ServerPluginsModel: ObservableObject {
    @Published var plugins: [AdminPlugin] = []
    @Published var packages: [AdminPackage] = []
    @Published var loaded = false
    @Published var error: String?
    @Published var restartNeeded = false
    let kind: ServerAdminKind
    let api: ServerAdminAPI

    init(kind: ServerAdminKind, api: ServerAdminAPI) { self.kind = kind; self.api = api }

    func load() async {
        let (d, st) = await api.request(PluginAdminAPI.list)
        if st == 200, let d, let l = AdminPlugin.decodeList(d) { plugins = l; error = nil }
        else { error = AdminMessage.text(status: st == 200 ? 500 : st, action: "read the plugins") }
        loaded = true
        if case let (cd?, 200) = await api.request(PluginAdminAPI.catalog(kind)) { packages = AdminPackage.decodeList(cd) }
        plugins = PluginUpdates.apply(plugins, packages: packages)
        if plugins.contains(where: \.needsRestart) { restartNeeded = true }
    }

    func run(_ r: AdminRequest, action: String, restart: Bool) async -> String? {
        let (_, st) = await api.request(r)
        if let m = AdminMessage.text(status: st, action: action) { return m }
        if restart { restartNeeded = true }
        await load(); return nil
    }

    func update(_ p: AdminPlugin) async -> String? {
        guard let pkg = PluginUpdates.package(for: p, in: packages), p.update != nil else { return "No update found." }
        return await run(PluginAdminAPI.install(pkg, kind: kind), action: "install the update", restart: true)
    }
}

@MainActor
final class ServerLogsModel: ObservableObject {
    @Published var files: [AdminLogFile] = []
    @Published var activity: [AdminActivity] = []
    @Published var loaded = false
    @Published var error: String?
    @Published var activityError: String?
    @Published var open: AdminLogFile?
    @Published var raw = ""
    @Published var lines: [LogLine] = []
    @Published var loadingFile = false
    let kind: ServerAdminKind
    let api: ServerAdminAPI

    init(kind: ServerAdminKind, api: ServerAdminAPI) { self.kind = kind; self.api = api }

    func load() async {
        let (d, st) = await api.request(LogAdminAPI.list)
        if st == 200, let d, let l = AdminLogFile.decodeList(d) { files = l; error = nil }
        else { error = AdminMessage.text(status: st == 200 ? 500 : st, action: "read the log list") }
        let (ad, ast) = await api.request(ActivityAdminAPI.entries)
        if ast == 200, let ad, let a = AdminActivity.decodeList(ad) { activity = a; activityError = nil }
        else { activityError = AdminMessage.text(status: ast == 200 ? 500 : ast, action: "read the activity log") }
        loaded = true
    }

    func openFile(_ f: AdminLogFile) async {
        open = f; loadingFile = true; lines = []; raw = ""
        let (d, st) = await api.request(LogAdminAPI.file(f.name, kind: kind))
        loadingFile = false
        guard open == f else { return }
        if st == 200, let d {
            let text = String(decoding: d, as: UTF8.self)
            lines = LogAdminAPI.parse(text)
            raw = lines.map(\.text).joined(separator: "\n")
        } else { error = AdminMessage.text(status: st == 200 ? 500 : st, action: "read the log") }
    }
}
