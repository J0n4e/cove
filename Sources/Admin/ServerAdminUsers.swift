import Foundation

// Server management, phase 2: Users. Pure request shapes, decoding and the self-protection rules, tested in
// Tests/ServerAdminP2Tests.swift. The user's Policy is edited as the server's own JSON dictionary: only the keys
// Cove knows are changed, everything else (including fields newer servers add) is sent back untouched.

/// One server call with an optional JSON body.
struct AdminRequest: Equatable {
    let method: String
    let path: String
    var body: Data? = nil

    static func json(_ method: String, _ path: String, _ o: Any) -> AdminRequest {
        AdminRequest(method: method, path: path, body: try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
    }
}

enum AdminQuery {
    /// Strict query encoding (names and paths can hold &, =, +, spaces, slashes).
    static func q(_ s: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }
}

// MARK: - Users

struct AdminUser: Identifiable, Equatable {
    let id: String
    var name: String
    var isAdmin: Bool
    var isDisabled: Bool
    var isHidden: Bool
    var hasPassword: Bool
    var lastActivity: Date?
    var lastLogin: Date?
    var imageTag: String?
    /// The server's full user record (sorted-keys JSON), sent back for a rename.
    var raw: Data

    var rawObject: [String: Any] { ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]) ?? [:] }
    var policy: [String: Any] { rawObject["Policy"] as? [String: Any] ?? [:] }

    static func bool(_ v: Any?) -> Bool? { (v as? Bool) ?? (v as? NSNumber)?.boolValue }

    static func decode(_ o: [String: Any]) -> AdminUser? {
        guard let id = o["Id"] as? String, !id.isEmpty else { return nil }
        let p = o["Policy"] as? [String: Any] ?? [:]
        // Emby: HasPassword / HasConfiguredPassword; Jellyfin: HasPassword (and HasConfiguredPassword on older)
        let pw = bool(o["HasConfiguredPassword"]) ?? bool(o["HasPassword"]) ?? false
        return AdminUser(id: id, name: (o["Name"] as? String) ?? "", isAdmin: bool(p["IsAdministrator"]) ?? false,
                         isDisabled: bool(p["IsDisabled"]) ?? false, isHidden: bool(p["IsHidden"]) ?? false,
                         hasPassword: pw,
                         lastActivity: (o["LastActivityDate"] as? String).flatMap(ServerAdminDate.parse),
                         lastLogin: (o["LastLoginDate"] as? String).flatMap(ServerAdminDate.parse),
                         imageTag: (o["PrimaryImageTag"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         raw: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data())
    }

    /// GET /Users: a plain array on both servers (Emby /Users/Query wraps it in Items; accepted too).
    static func decodeList(_ data: Data) -> [AdminUser]? {
        let j = try? JSONSerialization.jsonObject(with: data)
        guard let a = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["Items"] as? [[String: Any]]) else { return nil }
        return a.compactMap(decode).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        let s = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    static func matches(_ u: AdminUser, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || u.name.localizedCaseInsensitiveContains(q)
    }

    /// "Active 3 hours ago" / "Never signed in".
    func activityLine(now: Date = Date()) -> String {
        if let d = lastActivity ?? lastLogin { return "Active " + ServerAdminDate.relative(d, now: now) }
        return "Never signed in"
    }
}

/// The policy switches the detail sheet shows. Applied onto the server's own dictionary.
struct UserPolicyEdit: Equatable {
    var isAdministrator = false
    var isDisabled = false
    var isHidden = false
    var enableRemoteAccess = true
    var enableMediaPlayback = true
    var enableVideoTranscoding = true
    var enableAudioTranscoding = true
    var enableDownloads = true
    /// nil = no limit.
    var maxParentalRating: Int?
    var enableAllFolders = true
    var enabledFolders: [String] = []
    /// Jellyfin only: CreateAndJoinGroups / JoinGroups / None. nil = the server has no such field.
    var syncPlayAccess: String?

    /// Server key ↔ edit field (Bool switches).
    static let boolKeys: [(key: String, path: WritableKeyPath<UserPolicyEdit, Bool>, title: String)] = [
        ("IsAdministrator", \.isAdministrator, "Administrator"),
        ("IsDisabled", \.isDisabled, "Disabled"),
        ("IsHidden", \.isHidden, "Hide from login screen"),
        ("EnableRemoteAccess", \.enableRemoteAccess, "Allow remote access"),
        ("EnableMediaPlayback", \.enableMediaPlayback, "Allow media playback"),
        ("EnableVideoPlaybackTranscoding", \.enableVideoTranscoding, "Allow video transcoding"),
        ("EnableAudioPlaybackTranscoding", \.enableAudioTranscoding, "Allow audio transcoding"),
        ("EnableContentDownloading", \.enableDownloads, "Allow downloads"),
        ("EnableAllFolders", \.enableAllFolders, "All libraries"),
    ]

    static func from(_ p: [String: Any]) -> UserPolicyEdit {
        var e = UserPolicyEdit()
        for k in boolKeys { if let v = AdminUser.bool(p[k.key]) { e[keyPath: k.path] = v } }
        e.maxParentalRating = (p["MaxParentalRating"] as? NSNumber)?.intValue
        e.enabledFolders = (p["EnabledFolders"] as? [String]) ?? []
        e.syncPlayAccess = p["SyncPlayAccess"] as? String
        return e
    }

    /// The full policy to POST: the original dictionary with only Cove's keys replaced.
    func apply(to original: [String: Any]) -> [String: Any] {
        var p = original
        for k in Self.boolKeys { p[k.key] = self[keyPath: k.path] }
        if let r = maxParentalRating { p["MaxParentalRating"] = r } else { p.removeValue(forKey: "MaxParentalRating") }
        p["EnabledFolders"] = enableAllFolders ? (original["EnabledFolders"] as? [String] ?? []) : enabledFolders
        if let s = syncPlayAccess, original["SyncPlayAccess"] != nil { p["SyncPlayAccess"] = s }
        return p
    }

    /// The Save summary: "Administrator: on", "Libraries: 2 selected", …
    func changes(from old: UserPolicyEdit, ratingName: (Int?) -> String = { $0.map(String.init) ?? "No limit" }) -> [String] {
        var out: [String] = []
        for k in Self.boolKeys where k.key != "EnableAllFolders" && self[keyPath: k.path] != old[keyPath: k.path] {
            out.append("\(k.title): \(self[keyPath: k.path] ? "on" : "off")")
        }
        if maxParentalRating != old.maxParentalRating { out.append("Max parental rating: \(ratingName(maxParentalRating))") }
        if enableAllFolders != old.enableAllFolders || (!enableAllFolders && Set(enabledFolders) != Set(old.enabledFolders)) {
            out.append(enableAllFolders ? "Libraries: all" : "Libraries: \(enabledFolders.count) selected")
        }
        if syncPlayAccess != old.syncPlayAccess, let s = syncPlayAccess { out.append("SyncPlay: \(UserAdminAPI.syncPlayTitle(s))") }
        return out
    }
}

/// The rules that keep an admin from locking themselves (or everyone) out.
enum UserAdminRules {
    static func canDelete(_ user: AdminUser, me: String) -> Bool { user.id != me }

    /// nil = OK to save; else the sentence to show.
    static func validate(_ edit: UserPolicyEdit, user: AdminUser, me: String, users: [AdminUser]) -> String? {
        if user.id == me {
            if !edit.isAdministrator { return "You can't remove your own administrator rights." }
            if edit.isDisabled { return "You can't disable your own account." }
        }
        let otherAdmins = users.filter { $0.id != user.id && $0.isAdmin && !$0.isDisabled }
        if user.isAdmin, otherAdmins.isEmpty, !edit.isAdministrator || edit.isDisabled {
            return "This is the only active administrator. Make someone else an administrator first."
        }
        return nil
    }

    /// Delete asks for the user's name typed exactly.
    static func deleteConfirmed(_ typed: String, user: AdminUser) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t == user.name
    }
}

enum UserAdminAPI {
    static let syncPlayOptions = ["CreateAndJoinGroups", "JoinGroups", "None"]
    static func syncPlayTitle(_ s: String) -> String {
        switch s {
        case "CreateAndJoinGroups": return "Create and join groups"
        case "JoinGroups": return "Join groups"
        case "None": return "No access"
        default: return s
        }
    }

    static let list = AdminRequest(method: "GET", path: "/Users")
    static func user(_ id: String) -> AdminRequest { AdminRequest(method: "GET", path: "/Users/\(AdminQuery.q(id))") }

    /// POST /Users/New. Jellyfin takes {Name, Password}; Emby only reads Name (the password is set afterwards
    /// with `password`, see `createNeedsPasswordStep`).
    static func create(name: String, password: String, kind: ServerAdminKind) -> AdminRequest {
        var b: [String: Any] = ["Name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
        if kind == .jellyfin, !password.isEmpty { b["Password"] = password }
        return .json("POST", "/Users/New", b)
    }
    static func createNeedsPasswordStep(_ kind: ServerAdminKind, password: String) -> Bool { kind == .emby && !password.isEmpty }

    /// POST /Users/{id} with the full record, only Name changed.
    static func rename(_ user: AdminUser, to name: String) -> AdminRequest {
        var o = user.rawObject
        o["Name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .json("POST", "/Users/\(AdminQuery.q(user.id))", o)
    }

    /// POST /Users/{id}/Password. Setting: {Id, CurrentPw, NewPw, ResetPassword:false}; CurrentPw only matters
    /// for your own account (both servers skip it when an admin sets someone else's). Reset (clear): ResetPassword
    /// true. Both servers read the same field names (Emby also accepts the legacy CurrentPassword/NewPassword).
    static func password(userId: String, new: String, current: String? = nil) -> AdminRequest {
        .json("POST", "/Users/\(AdminQuery.q(userId))/Password",
              ["Id": userId, "CurrentPw": current ?? "", "NewPw": new, "ResetPassword": false])
    }
    static func resetPassword(userId: String) -> AdminRequest {
        .json("POST", "/Users/\(AdminQuery.q(userId))/Password", ["Id": userId, "ResetPassword": true])
    }

    static func policy(userId: String, _ p: [String: Any]) -> AdminRequest {
        .json("POST", "/Users/\(AdminQuery.q(userId))/Policy", p)
    }

    static func delete(_ userId: String) -> AdminRequest { AdminRequest(method: "DELETE", path: "/Users/\(AdminQuery.q(userId))") }

    static let parentalRatings = AdminRequest(method: "GET", path: "/Localization/ParentalRatings")
    static let mediaFolders = AdminRequest(method: "GET", path: "/Library/MediaFolders")

    /// [{Name, Value}] → one option per value (names with the same value joined: "PG-13 / TV-14").
    static func decodeRatings(_ data: Data) -> [(value: Int, name: String)] {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var order: [Int] = [], names: [Int: [String]] = [:]
        for r in a {
            guard let n = r["Name"] as? String, let v = (r["Value"] as? NSNumber)?.intValue else { continue }
            if names[v] == nil { order.append(v); names[v] = [] }
            if !names[v]!.contains(n), names[v]!.count < 3 { names[v]!.append(n) }
        }
        return order.sorted().map { ($0, names[$0]!.joined(separator: " / ")) }
    }

    /// {Items:[{Id, Name}]} → (id, name).
    static func decodeFolders(_ data: Data) -> [(id: String, name: String)] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let a = o["Items"] as? [[String: Any]] else { return [] }
        return a.compactMap { d in (d["Id"] as? String).map { ($0, (d["Name"] as? String) ?? $0) } }
    }

    /// Folder ids compare without dashes / case (Jellyfin's policy and item ids can differ in Guid format).
    static func sameId(_ a: String, _ b: String) -> Bool {
        a.lowercased().replacingOccurrences(of: "-", with: "") == b.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

/// Plain sentences for admin errors.
enum AdminMessage {
    static func text(status: Int, action: String) -> String? {
        switch status {
        case 200..<300: return nil
        case 0: return "Couldn't reach the server to \(action). Check the connection and try again."
        case 400: return "The server refused to \(action). Check what you typed and try again."
        case 401: return "Your sign-in has expired. Sign in again and retry."
        case 403: return "The server says you're not allowed to \(action). An administrator account is needed."
        case 404: return "The server couldn't find it (it may have been removed already)."
        case 409: return "That name is already taken."
        case 500..<600: return "The server ran into a problem while trying to \(action) (error \(status)). Try again in a moment."
        default: return "Couldn't \(action) (error \(status))."
        }
    }
}
