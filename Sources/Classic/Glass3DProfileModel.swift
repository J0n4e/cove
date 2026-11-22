import AppKit
import SwiftUI

// The Glass3D profile circle and its menu: pure logic and shared state (no views). Every menu section is one
// `ProfileSection` case, built by its own function, so a section can be dropped by removing it from
// `ProfileMenuSpec.shown` without touching the others.

// MARK: - Initials

enum ProfileInitials {
    /// "Jonas Example" → "JE", "jonas" → "J", "" → "?". Two letters at most, upper-cased.
    nonisolated static func of(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }

    /// Tooltip on the circle: "<user> on <server>".
    nonisolated static func tooltip(user: String, server: String) -> String {
        user.isEmpty ? server : "\(user) on \(server)"
    }
}

// MARK: - Menu content

enum ProfileSection: String, CaseIterable, Equatable {
    case you, servers, users, shortcuts, app, signOut
}

enum ProfileRow: Equatable, Identifiable {
    case changePicture, removePicture
    case server(id: String, name: String, current: Bool, online: Bool?)
    case addServer
    case switchUser
    case otherUser(key: String, name: String)
    case search, myActivity, favorites
    case notifications(unread: Int)
    case settings, checkUpdates, about, help
    case manageServer   // admins only (App section)
    case signOut

    var id: String {
        switch self {
        case .server(let id, _, _, _): return "server:" + id
        case .otherUser(let key, _): return "user:" + key
        case .notifications: return "notifications"
        default: return String(describing: self)
        }
    }
}

/// Everything the menu shows, derived from plain values so it can be tested without a server.
struct ProfileMenuInput: Equatable {
    struct Server: Equatable { let id: String; let name: String }
    struct OtherUser: Equatable { let key: String; let name: String }
    var name: String
    var jellyfin: Bool
    var admin: Bool?
    var hasPicture: Bool
    var servers: [Server]
    var currentServer: String
    var online: [String: Bool] = [:]
    var otherUsers: [OtherUser] = []
    var unread: Int = 0
}

enum ProfileMenuSpec {
    /// The sections in the menu, top to bottom. The owner will decide later which stay: drop a case here to hide it.
    static var shown: [ProfileSection] = ProfileSection.allCases

    /// "Emby · Admin", "Jellyfin · User"; just the server kind while the role is unknown.
    nonisolated static func subtitle(jellyfin: Bool, admin: Bool?) -> String {
        let kind = jellyfin ? "Jellyfin" : "Emby"
        guard let admin else { return kind }
        return kind + " · " + (admin ? "Admin" : "User")
    }

    nonisolated static func rows(_ s: ProfileSection, _ i: ProfileMenuInput) -> [ProfileRow] {
        switch s {
        case .you: return i.hasPicture ? [.changePicture, .removePicture] : [.changePicture]
        case .servers:
            return i.servers.map { .server(id: $0.id, name: $0.name, current: $0.id == i.currentServer.lowercased(), online: i.online[$0.id]) }
                + [.addServer]
        case .users: return [.switchUser] + i.otherUsers.map { .otherUser(key: $0.key, name: $0.name) }
        case .shortcuts: return [.search, .myActivity, .favorites, .notifications(unread: i.unread)]
        case .app: return (i.admin == true ? [.manageServer] : []) + [.settings, .checkUpdates, .about, .help]
        case .signOut: return [.signOut]
        }
    }

    nonisolated static func sections(_ i: ProfileMenuInput, shown: [ProfileSection] = ProfileSection.allCases) -> [(ProfileSection, [ProfileRow])] {
        shown.map { ($0, rows($0, i)) }
    }

    /// The label of a row (the views add icons, dots and ✓).
    nonisolated static func title(_ r: ProfileRow) -> String {
        switch r {
        case .changePicture: return "Change picture…"
        case .removePicture: return "Remove picture"
        case .server(_, let name, _, _): return name
        case .addServer: return "Add server…"
        case .switchUser: return "Switch user…"
        case .otherUser(_, let name): return name
        case .search: return "Search"
        case .myActivity: return "My activity"
        case .favorites: return "Favorites"
        case .notifications(let n): return n > 0 ? "Notifications (\(n))" : "Notifications"
        case .settings: return "Settings…"
        case .checkUpdates: return "Check for updates"
        case .about: return "About Cove"
        case .help: return "Cove Help"
        case .manageServer: return "Manage server…"
        case .signOut: return "Sign out"
        }
    }
}

// MARK: - Picture upload / removal

/// Request shapes for the user's Primary image.
///
/// Both servers read the upload body as BASE64 text of the image, with the image's Content-Type:
/// - Emby: `POST /Users/{id}/Images/Primary`, `DELETE /Users/{id}/Images/Primary`.
/// - Jellyfin (checked in jellyfin/jellyfin `Jellyfin.Api/Controllers/ImageController.cs`): 10.8 reads the body with
///   `Convert.FromBase64String`, 10.9 / 10.10 / master with `GetFromBase64Stream`, so base64 on every version
///   (raw bytes are NOT accepted). 10.9 added `POST/DELETE /UserImage?userId=` and marked
///   `/Users/{id}/Images/{type}` obsolete ("kept for backwards compatibility"), so 10.9+ gets the new path and
///   older servers the old one.
enum ProfileImageAPI {
    struct Shape: Equatable {
        let method: String
        let path: String       // with query
        let contentType: String?
        let body: Data?
    }

    /// Jellyfin 10.9 or newer (unknown version: treated as newer, the current releases).
    nonisolated static func jellyfinHasUserImage(_ version: String?) -> Bool {
        guard let v = version, !v.isEmpty else { return true }
        let p = v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let major = p.first ?? 0, minor = p.count > 1 ? p[1] : 0
        return major > 10 || (major == 10 && minor >= 9)
    }

    nonisolated static func path(userId: String, jellyfin: Bool, version: String?) -> String {
        let id = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        if jellyfin && jellyfinHasUserImage(version) { return "/UserImage?userId=" + id }
        return "/Users/\(id)/Images/Primary"
    }

    nonisolated static func upload(userId: String, jpeg: Data, jellyfin: Bool, version: String?) -> Shape {
        Shape(method: "POST", path: path(userId: userId, jellyfin: jellyfin, version: version),
              contentType: "image/jpeg", body: Data(jpeg.base64EncodedString().utf8))
    }

    nonisolated static func remove(userId: String, jellyfin: Bool, version: String?) -> Shape {
        Shape(method: "DELETE", path: path(userId: userId, jellyfin: jellyfin, version: version), contentType: nil, body: nil)
    }

    /// nil = success; otherwise a plain sentence for the window.
    nonisolated static func message(status: Int, server: String) -> String? {
        switch status {
        case 200..<300: return nil
        case 401: return "Your sign-in on \(server) has expired. Sign in again and retry."
        case 403: return "The server doesn't allow you to change your picture."
        case 404: return "\(server) doesn't support changing the picture from Cove."
        case 413: return "The picture is too large for \(server)."
        default: return "\(server) couldn't save the picture (error \(status)). Try again in a moment."
        }
    }
}

// MARK: - Several users per server

/// Sign-ins of every user used on each server, so switching user keeps the previous user's sign-in. The server
/// list (ServerStore) still holds ONE user per server (the current one); this sealed store adds the others.
/// Saved as one sealed dictionary under "serverUserTokens": "<server id>|<user id>" → {user, token}.
enum ProfileUserStore {
    static let key = "serverUserTokens"

    struct Entry: Codable, Equatable { var user: String; var token: String }

    nonisolated static func entryKey(server: String, userId: String) -> String { server.lowercased() + "|" + userId }

    nonisolated static func split(_ key: String) -> (server: String, userId: String)? {
        guard let i = key.lastIndex(of: "|") else { return nil }
        return (String(key[..<i]), String(key[key.index(after: i)...]))
    }

    static func all(_ d: UserDefaults = .standard) -> [String: Entry] {
        guard let s = SealedPrefs.get(key, in: d), let data = s.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func save(_ all: [String: Entry], _ d: UserDefaults = .standard) {
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all), let json = String(data: data, encoding: .utf8)
        else { SealedPrefs.set(nil, for: key, in: d); return }
        SealedPrefs.set(json, for: key, in: d)
    }

    static func remember(server: String, userId: String, user: String, token: String, _ d: UserDefaults = .standard) {
        guard !server.isEmpty, !userId.isEmpty, !token.isEmpty else { return }
        var a = all(d)
        let e = Entry(user: user, token: token)
        let k = entryKey(server: server, userId: userId)
        guard a[k] != e else { return }
        a[k] = e; save(a, d)
    }

    static func forget(server: String, userId: String, _ d: UserDefaults = .standard) {
        var a = all(d)
        guard a.removeValue(forKey: entryKey(server: server, userId: userId)) != nil else { return }
        save(a, d)
    }

    /// Drops sign-ins of servers that are no longer in the list.
    static func prune(keeping servers: Set<String>, _ d: UserDefaults = .standard) {
        let a = all(d)
        let kept = a.filter { k, _ in split(k).map { servers.contains($0.server) } ?? false }
        if kept.count != a.count { save(kept, d) }
    }

    /// The other users signed in on this server (not the current one), by name.
    nonisolated static func others(_ all: [String: Entry], server: String, currentUserId: String) -> [(key: String, userId: String, entry: Entry)] {
        let sid = server.lowercased()
        return all.compactMap { k, e -> (String, String, Entry)? in
            guard let p = split(k), p.server == sid, p.userId != currentUserId else { return nil }
            return (k, p.userId, e)
        }
        .sorted { $0.2.user.localizedCaseInsensitiveCompare($1.2.user) == .orderedAscending }
        .map { (key: $0.0, userId: $0.1, entry: $0.2) }
    }
}

// MARK: - Shared state

/// The signed-in user's profile (name, role, picture) for the circle and the menu.
@MainActor
final class ProfileModel: ObservableObject {
    static let shared = ProfileModel()
    @Published var name = ""
    @Published var admin: Bool?
    @Published var imageTag: String?
    @Published var image: NSImage?
    /// Goes up after a picture change, so every avatar fetches the new image (part of the image link).
    @Published var revision = 0
    @Published var menuOpen = false
    @Published var online: [String: Bool] = [:]
    private var loadedFor = ""

    func avatarURL(server: String, userId: String, tag: String?, size: Int = 120) -> URL? {
        guard let tag, !server.isEmpty, !userId.isEmpty else { return nil }
        return URL(string: "\(server)/Users/\(userId)/Images/Primary?tag=\(tag)&maxHeight=\(size)&quality=90&cv=\(revision)")
    }

    /// Reads /Users/{id}: name, admin flag and the picture's tag; then the picture through the image cache.
    func load(_ emby: Emby, force: Bool = false) async {
        let key = emby.server.lowercased() + "|" + emby.userId + "|\(revision)"
        guard emby.loggedIn, force || key != loadedFor else { return }
        if key.split(separator: "|").prefix(2) != loadedFor.split(separator: "|").prefix(2) {
            name = emby.currentServer?.user ?? ""; admin = nil; imageTag = nil; image = nil
        }
        loadedFor = key
        guard let u = URL(string: "\(emby.server)/Users/\(emby.userId)") else { return }
        var r = URLRequest(url: u, timeoutInterval: 10)
        emby.authorize(&r)
        guard let (data, resp) = try? await Net.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard key == loadedFor else { return }   // switched meanwhile
        if let n = j["Name"] as? String, !n.isEmpty { name = n }
        admin = StatsDecode.isAdministrator(data)
        imageTag = (j["PrimaryImageTag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let url = avatarURL(server: emby.server, userId: emby.userId, tag: imageTag) {
            let img = await ImageCache.shared.image(url)
            if key == loadedFor { image = img }
        } else { image = nil }
    }

    /// After a picture change: new link (revision) and a fresh read of the tag.
    func pictureChanged(_ emby: Emby) async {
        revision += 1
        await load(emby, force: true)
    }

    /// Green / grey dots for the saved servers: GET /System/Info/Public, 3 s each, all at once.
    func checkOnline(_ servers: [SavedServer]) async {
        await withTaskGroup(of: (String, Bool).self) { g in
            for s in servers {
                g.addTask {
                    guard let u = URL(string: s.url + "/System/Info/Public") else { return (s.id, false) }
                    let r = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 3))
                    return (s.id, (r?.1 as? HTTPURLResponse)?.statusCode == 200)
                }
            }
            for await (id, ok) in g { online[id] = ok }
        }
    }
}

/// Requests from the menu to other screens: Activity's tab, the login form's prefill.
@MainActor
final class ProfileJump: ObservableObject {
    static let shared = ProfileJump()
    /// Activity should open Overview drilled to the current user (admins) or the normal Overview.
    @Published var myActivityTick = 0
    var myActivityPending = false
    /// The login screen opens its form with this server filled in (Switch user… / Add server…).
    struct Prefill { let url: String; let name: String }
    var prefill: Prefill?

    func takePrefill() -> Prefill? { defer { prefill = nil }; return prefill }
}
