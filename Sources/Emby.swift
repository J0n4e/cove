import Foundation
import os

/// Problems that are otherwise silent (failed server calls, unreadable saved data). See them in Console.app, filter "eu.jonae.cove".
let coveLog = Logger(subsystem: "eu.jonae.cove", category: "emby")

struct Item: Identifiable, Decodable, Hashable {
    let Id: String
    let Name: String
    let `Type`: String?
    let Overview: String?
    let ProductionYear: Int?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let SeriesId: String?
    let SeriesName: String?
    let ParentBackdropItemId: String?
    let BackdropImageTags: [String]?
    // Image version tags (they change when the artwork changes); used to cache pictures safely
    let ImageTags: [String: String]?
    let ParentBackdropImageTags: [String]?
    let ParentLogoItemId: String?
    let ParentLogoImageTag: String?
    let SeriesPrimaryImageTag: String?
    /// Jellyfin only: tiny blurred previews by kind and tag ("Primary": {tag: hash}).
    let ImageBlurHashes: [String: [String: String]]?
    let CollectionType: String?
    let UserData: UD?
    let RunTimeTicks: Int64?
    let CommunityRating: Double?
    let Genres: [String]?
    let EndDate: String?
    let Status: String?
    struct UD: Decodable, Hashable { let Played: Bool?; let IsFavorite: Bool?; let PlayedPercentage: Double?; let UnplayedItemCount: Int?; let PlaybackPositionTicks: Int64? }
    var id: String { Id }
    var backdropId: String? { (BackdropImageTags ?? []).isEmpty ? ParentBackdropItemId : Id }
    var posterId: String { `Type` == "Episode" ? (SeriesId ?? Id) : Id }
    var heroTitle: String { SeriesName ?? Name }
    var isSeries: Bool { `Type` == "Series" }
    var isBox: Bool { `Type` == "BoxSet" }
    var playable: Bool { !isSeries && !isBox }
    var isEpisode: Bool { `Type` == "Episode" }
    /// "2012" for movies; "2007 – 2019" or "2017 – Present" for shows, as Emby shows it.
    var yearText: String {
        guard let y = ProductionYear else { return " " }
        guard isSeries else { return String(y) }
        if Status == "Continuing" { return "\(y) – Present" }
        if let e = EndDate, let ey = Int(e.prefix(4)), ey != y { return "\(y) – \(ey)" }
        return String(y)
    }
}
struct ItemList: Decodable { let Items: [Item]; let TotalRecordCount: Int? }
struct PlayRequest: Identifiable {
    let item: Item
    var sourceId: String?
    var audio: Int?
    var sub: Int?
    var maxBitrate: Int?
    var start: Double? = nil      // seconds to resume from
    var noSub = false             // user chose "Off": don't auto-load the preferred language
    var burnIn = false            // subtitle couldn't be read as text: have the server burn it in
    var id: String { item.id }
    var transcode: Bool { audio != nil || sub != nil || maxBitrate != nil }
}

struct MStream: Decodable, Identifiable {
    let Index: Int
    let `Type`: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let Language: String?
    let Codec: String?
    let Width: Int?
    let Height: Int?
    let BitRate: Int?
    var id: Int { Index }
}

/// A chapter or an intro/credits marker (Emby 4.8+: MarkerType IntroStart / IntroEnd / CreditsStart).
struct Chapter: Decodable {
    let StartPositionTicks: Int64
    let Name: String?
    let MarkerType: String?
    let ImageTag: String?
    var start: Double { Double(StartPositionTicks) / 10_000_000 }
    var isMarker: Bool { (MarkerType ?? "Chapter") != "Chapter" }
}

/// A client session from /Sessions (only the bits the Now Playing page shows).
struct ActiveSession: Decodable, Identifiable {
    let Id: String
    let UserName: String?
    let Client: String?
    let ApplicationVersion: String?
    let DeviceName: String?
    let RemoteEndPoint: String?
    let NowPlayingItem: NowItem?
    let PlayState: State?
    let TranscodingInfo: Transcode?
    var id: String { Id }
    struct NowItem: Decodable {
        let Id: String
        let Name: String
        let SeriesName: String?
        let SeriesId: String?
        let ParentIndexNumber: Int?
        let IndexNumber: Int?
        let RunTimeTicks: Int64?
        let `Type`: String?
    }
    struct State: Decodable { let PositionTicks: Int64?; let IsPaused: Bool?; let PlayMethod: String? }
    struct Transcode: Decodable {
        let IsVideoDirect: Bool?
        let IsAudioDirect: Bool?
        let VideoCodec: String?
        let AudioCodec: String?
        let Bitrate: Int?
        let CompletionPercentage: Double?
        let TranscodeReasons: [String]?
    }
}

/// Audio/subtitle choices remembered per series.
enum SeriesLang {
    private static let key = "seriesLang"
    private static var all: [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }
    static func get(_ seriesId: String) -> [String: String]? { all[seriesId] }
    static func set(_ seriesId: String, _ k: String, _ v: String) {
        var a = all
        a[seriesId, default: [:]][k] = v
        UserDefaults.standard.set(a, forKey: key)
    }
}
struct MSource: Decodable, Identifiable {
    let Id: String
    let Name: String?
    let Path: String?
    let Container: String?
    let Size: Int64?
    let MediaStreams: [MStream]?
    var id: String { Id }
}
struct Full: Decodable {
    let Genres: [String]?
    let Studios: [Named]?
    let People: [Person]?
    let MediaSources: [MSource]?
    let CommunityRating: Double?
    let CriticRating: Double?
    let OfficialRating: String?
    let RunTimeTicks: Int64?
    let Taglines: [String]?
    let DateCreated: String?
    let ExternalUrls: [Link]?
    let RemoteTrailers: [Link]?
    let UserData: UD?
    let Chapters: [Chapter]?
    struct Named: Decodable { let Name: String }
    struct Person: Decodable, Identifiable {
        let Id: String
        let Name: String
        let Role: String?
        let `Type`: String?
        var id: String { Id + (Role ?? "") }
    }
    struct Link: Decodable { let Name: String?; let Url: String? }
    struct UD: Decodable { let LastPlayedDate: String? }
}

struct Row: Identifiable {
    /// Stable between reloads (library, feed or title), so SwiftUI updates a row in place instead of
    /// rebuilding it, which reset its scroll position every time Home refreshed.
    var id: String { libId ?? feed?.rawValue ?? title }
    let title: String; let items: [Item]
    /// What the row's "›" title opens: a feed page or a library.
    var feed: Feed? = nil
    var libId: String? = nil
}

/// Full-page lists behind the home rows and the sidebar's Recently Added.
enum Feed: String, Hashable { case resume = "Continue Watching", nextUp = "Up Next", recent = "Recently Added" }

struct LibPref: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var title: String
    var visible: Bool = true     // shown in My Media
    var onHome: Bool = true      // gets a row on the home screen
    var style: String = "latest" // latest | random | top | az
    var kind: String?
}

/// Where Favorites and Now Playing sit in the sidebar / top bar, set by moving them in Settings → Libraries.
/// Saved as one comma-separated order of library ids and the two section ids. Sections above the first
/// library stay in their usual place after Home; the others follow the library just above them.
enum NavOrder {
    static let key = "navOrder"
    static let favorites = "__favorites", nowPlaying = "__nowplaying"
    static let sections = [favorites, nowPlaying]

    /// The full order for these libraries (in their own order): sections keep the slot they were saved in.
    static func rows(_ saved: String, libIds: [String]) -> [String] {
        let list = saved.split(separator: ",").map(String.init)
        var top: [String] = [], after: [String: [String]] = [:], lastLib: String?
        for id in list {
            if sections.contains(id) {
                if let l = lastLib, libIds.contains(l) { after[l, default: []].append(id) } else { top.append(id) }
            } else if libIds.contains(id) { lastLib = id }
        }
        // Sections never saved (first run) go to their usual place
        for s in sections where !list.contains(s) { top.append(s) }
        var r = top
        for l in libIds { r.append(l); r += after[l] ?? [] }
        return r
    }

    /// Sections in their usual place (above every library).
    static func top(_ rows: [String]) -> [String] { Array(rows.prefix { sections.contains($0) }) }

    /// Sections placed right after this library.
    static func after(_ lib: String, _ rows: [String]) -> [String] {
        guard let i = rows.firstIndex(of: lib) else { return [] }
        return Array(rows[(i + 1)...].prefix { sections.contains($0) })
    }
}

/// A server the user has signed in to; the token is kept so switching back needs no password.

struct SavedServer: Codable, Identifiable, Hashable {
    var url: String
    var name: String
    var user: String
    var token: String?
    var userId: String?
    var id: String { url.lowercased() }
}

@MainActor
final class Emby: ObservableObject {
    private let d = UserDefaults.standard
    @Published var server = ""
    @Published var token = "" { didSet { updateImageAuth() } }
    @Published var userId = ""
    @Published var libs: [LibPref] = []
    @Published var playing: PlayRequest?
    /// Set by anything that wants the main window to open an item's page (e.g. clicking a hover preview card).
    @Published var openRequest: Item?
    /// Season to pre-select when the opened item is a series (Continue Watching card click).
    @Published var openSeason: Int?
    @Published var played: [String: Bool] = [:]
    @Published var faved: [String: Bool] = [:]
    @Published var servers: [SavedServer] = []
    /// The saved entry for the server we're signed in to.
    var currentServer: SavedServer? { servers.first { $0.id == server.lowercased() } }
    var currentServerName: String {
        if let n = currentServer?.name, !n.isEmpty { return n }
        return URL(string: server)?.host ?? server
    }
    /// Resume positions (seconds) saved during this session; overrides what the server sent with the item.
    @Published var positions: [String: Double] = [:]
    var loggedIn: Bool { !token.isEmpty }

    /// The signed-in server is Jellyfin (not Emby). Jellyfin speaks the same API, but takes the token in the
    /// `Authorization` header and as `ApiKey=` in links, where Emby uses `X-Emby-Token` and `api_key=`.
    @Published var isJellyfin = false
    /// Query name for the token in image / stream / subtitle links.
    var keyName: String { isJellyfin ? "ApiKey" : "api_key" }

    /// Pictures are fetched with the token in headers (not in the link), so the saved image cache holds no token.
    private func updateImageAuth() {
        ImageCache.shared.authHeaders = token.isEmpty ? [:]
            : ["X-Emby-Token": token, "Authorization": authHeader + ", Token=\"\(token)\""]
    }

    /// Adds the token to a request in every form Emby and Jellyfin accept.
    func authorize(_ r: inout URLRequest, token t: String? = nil) {
        let t = t ?? token
        r.setValue(t, forHTTPHeaderField: "X-Emby-Token")
        r.setValue(authHeader + ", Token=\"\(t)\"", forHTTPHeaderField: "Authorization")
    }

    /// Asks the server what it is ("Jellyfin Server" in ProductName) and remembers the answer per server.
    static func detectJellyfin(_ s: String) async -> Bool? {
        guard let u = URL(string: s + "/System/Info/Public"),
              let (data, _) = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 10)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((j["ProductName"] as? String) ?? "").localizedCaseInsensitiveContains("jellyfin")
    }

    func refreshServerKind() async {
        let key = "jellyfin-" + server.lowercased()
        isJellyfin = d.bool(forKey: key)
        if let j = await Self.detectJellyfin(server) { isJellyfin = j; d.set(j, forKey: key) }
    }

    /// The list, sign-in tokens included, goes to the preferences file (as before 1.15). Keychain storage is
    /// paused until Cove is signed with an Apple Developer ID: with our self-signed certificate macOS ties each
    /// Keychain item to one exact build, so every update would ask for Keychain access.
    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) { d.set(data, forKey: "servers") }
    }

    private func upsert(_ e: SavedServer) {
        if let i = servers.firstIndex(where: { $0.id == e.id }) { servers[i] = e } else { servers.append(e) }
        saveServers()
    }

    /// Picks https when the user typed no scheme and the server answers on it; otherwise http, as before.
    static func resolveAddress(_ raw: String) async -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.lowercased().hasPrefix("http") else { return normalize(t) }
        let secure = normalize("https://" + t)
        if let u = URL(string: secure + "/System/Info/Public"),
           let (_, r) = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 5)),
           (r as? HTTPURLResponse)?.statusCode == 200 { return secure }
        return normalize(t)
    }

    /// Renames a saved server (empty keeps the old name).
    func renameServer(_ e: SavedServer, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = servers.firstIndex(where: { $0.id == e.id }) else { return }
        servers[i].name = n; saveServers()
    }

    /// "Jellyfin" or "Emby", as last detected for that server.
    func kindLabel(_ e: SavedServer) -> String { d.bool(forKey: "jellyfin-" + e.id) ? "Jellyfin" : "Emby" }

    func removeServer(_ e: SavedServer) {
        // Removing the server we're signed in to (Classic settings allow it) signs out first: its token is revoked
        if e.id == server.lowercased(), loggedIn { logout() }
        else if let t = e.token { revoke(server: e.url, token: t) }
        servers.removeAll { $0.id == e.id }
        saveServers()
        ImageCache.shared.clear()
    }

    /// Ends the session on the server too, so the token stops working there (and leaves its Devices list).
    /// Best effort and in the background: signing out must still work when the server can't be reached.
    private func revoke(server s: String, token t: String) {
        guard !t.isEmpty, let url = URL(string: s + "/Sessions/Logout") else { return }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "POST"
        authorize(&r, token: t)
        let req = r
        Task.detached { _ = try? await Net.session.data(for: req) }
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    enum ResumeResult: Equatable { case ok, expired, unreachable }

    /// Signs in with a remembered token. The token is forgotten only when the server rejects it (401/403).
    /// When the server can't be reached (offline, timeout, server error) it is kept, so the next try still works.
    func resume(_ e: SavedServer) async -> ResumeResult {
        guard let t = e.token, let u = e.userId,
              let url = URL(string: "\(e.url)/Users/\(u)") else { return .expired }
        var r = URLRequest(url: url)
        authorize(&r, token: t)
        r.timeoutInterval = 10
        guard let (_, resp) = try? await Net.session.data(for: r) else { return .unreachable }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403:
            var x = e; x.token = nil; x.userId = nil; upsert(x)
            return .expired
        default: return .unreachable
        }
        resetSession()
        server = e.url; token = t; userId = u
        d.set(server, forKey: "server"); d.set(u, forKey: "uid")
        await refreshServerKind()
        return .ok
    }

    private func serverName(_ s: String) async -> String? {
        guard let u = URL(string: s + "/System/Info/Public"),
              let (data, _) = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 10)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j["ServerName"] as? String
    }

    private func resetSession() {
        playing = nil; libs = []; played = [:]; faved = [:]
        // Resume points and image tags/previews are keyed by item id only, so they must not carry over to
        // another server or user
        positions = [:]
        Self.tagLock.withLock { Self.imageTags = [:] }
        BlurHash.lock.withLock { BlurHash.hashes = [:] }
    }

    /// Back to the server list, staying signed in on this server.
    func switchServer() {
        resetSession()
        token = ""; userId = ""
        d.removeObject(forKey: "token"); d.removeObject(forKey: "uid")
    }

    let deviceId: String = {
        if let x = UserDefaults.standard.string(forKey: "did") { return x }
        let x = UUID().uuidString
        UserDefaults.standard.set(x, forKey: "did")
        return x
    }()

    init() {
        server = d.string(forKey: "server") ?? ""
        userId = d.string(forKey: "uid") ?? ""
        let legacyToken = d.string(forKey: "token") ?? ""      // versions before 1.15 kept it in preferences
        var list: [SavedServer] = []
        if let data = d.data(forKey: "servers") {
            do { list = try JSONDecoder().decode([SavedServer].self, from: data) }
            catch { coveLog.error("Saved servers could not be read: \(String(describing: error), privacy: .public)") }
        }
        // Remember the server from before saved servers existed.
        if list.isEmpty, !server.isEmpty, !legacyToken.isEmpty {
            list = [SavedServer(url: server, name: server, user: "", token: legacyToken, userId: userId)]
        }
        // Test builds of the Keychain change put tokens in the Keychain: move any such token back once and delete
        // the item (Macs that never ran those builds have none, so nothing is asked)
        var moved = false
        for i in list.indices where list[i].token == nil {
            if let t = TokenStore.get(list[i].id) { list[i].token = t; moved = true }
            if list[i].token == nil, list[i].id == server.lowercased(), !legacyToken.isEmpty {
                list[i].token = legacyToken; moved = true
            }
        }
        servers = list
        if moved {
            saveServers()
            for e in list { TokenStore.set(nil, for: e.id) }
        }
        // Signed in = a user id for the current server and its token
        token = userId.isEmpty ? "" : (servers.first { $0.id == server.lowercased() }?.token ?? "")
        if token.isEmpty { userId = "" }
        isJellyfin = d.bool(forKey: "jellyfin-" + server.lowercased())
        if !server.isEmpty { Task { await refreshServerKind() } }
        updateImageAuth()      // didSet doesn't run inside init
    }

    var authHeader: String {
        "MediaBrowser Client=\"Cove\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
    }

    /// `name`: what to call the server in the list; empty uses the name the server reports.
    func login(server raw: String, user: String, pw: String, name label: String = "") async throws {
        let s = Self.normalize(raw)
        guard let authURL = URL(string: s + "/Users/AuthenticateByName"), authURL.host != nil else { throw URLError(.badURL) }
        var r = URLRequest(url: authURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Jellyfin only reads `Authorization`; Emby reads either
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        r.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": pw])
        let (data, _) = try await Net.session.data(for: r)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = j["AccessToken"] as? String,
              let u = (j["User"] as? [String: Any])?["Id"] as? String
        else { throw URLError(.userAuthenticationRequired) }
        resetSession()
        server = s; token = t; userId = u
        d.set(s, forKey: "server"); d.set(u, forKey: "uid")
        await refreshServerKind()
        let typed = label.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? (await serverName(s) ?? servers.first { $0.id == s.lowercased() }?.name ?? s) : typed
        upsert(SavedServer(url: s, name: name, user: user, token: t, userId: u))
    }

    /// Signs out of this server: forgets its token but keeps it (and the username) in the list.
    func logout() {
        revoke(server: server, token: token)
        ImageCache.shared.clear()
        if let i = servers.firstIndex(where: { $0.id == server.lowercased() }) {
            servers[i].token = nil; servers[i].userId = nil; saveServers()
        }
        resetSession()
        token = ""; userId = ""
        d.removeObject(forKey: "token"); d.removeObject(forKey: "uid")
    }

    func get<T: Decodable>(_ path: String, _ q: [String: String] = [:]) async throws -> T {
        var q = q
        // The server leaves the year out unless asked; posters show it under the title
        if let f = q["Fields"] { if !f.contains("ProductionYear") { q["Fields"] = f + ",ProductionYear" } }
        else { q["Fields"] = "ProductionYear" }
        guard var c = URLComponents(string: server + path) else { throw URLError(.badURL) }
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" as is, and servers read it as a space ("C++", "Love + Death" would fail)
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let u = c.url else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        authorize(&r)
        let v: T
        do {
            let (data, _) = try await Net.session.data(for: r)
            v = try JSONDecoder().decode(T.self, from: data)
        } catch {
            if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                coveLog.error("GET \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
        if let l = v as? ItemList { Self.remember(l.Items) }
        else if let l = v as? [Item] { Self.remember(l) }
        else if let i = v as? Item { Self.remember([i]) }
        return v
    }

    /// This device's session as the server sees it (play state + transcode info).
    func sessionInfo() async -> [String: Any]? {
        guard let u = URL(string: "\(server)/Sessions?DeviceId=\(deviceId)") else { return nil }
        var r = URLRequest(url: u)
        authorize(&r)
        guard let (d, _) = try? await Net.session.data(for: r),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        return arr.first
    }

    /// All sessions currently playing something (all users for admins, otherwise just yours).
    func nowPlaying() async -> [ActiveSession] {
        let all: [ActiveSession]? = try? await get("/Sessions", ["ActiveWithinSeconds": "960"])
        return (all ?? []).filter { $0.NowPlayingItem != nil }
            .sorted { ($0.UserName ?? "", $0.Id) < ($1.UserName ?? "", $1.Id) }
    }

    /// Thumbnail strip for scrubbing previews (Roku BIF format), if the server has generated one.
    func bifData(_ id: String, _ sourceId: String?) async -> Data? {
        var s = "\(server)/Videos/\(id)/index.bif?Width=320"
        if let sourceId { s += "&MediaSourceId=\(sourceId)" }
        guard let u = URL(string: s) else { return nil }
        var req = URLRequest(url: u)
        authorize(&req)
        guard let (d, r) = try? await Net.session.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200, d.count > 64 else { return nil }
        return d
    }

    func chapterImage(_ id: String, _ index: Int, _ tag: String) -> URL? {
        URL(string: "\(server)/Items/\(id)/Images/Chapter/\(index)?maxWidth=320&tag=\(tag)")
    }

    /// Debug: this device's session as the server sees it (play state + transcode info), as raw JSON.
    func mySessionJSON() async -> String {
        guard let s = await sessionInfo() else { return "no session" }
        var out: [String: Any] = [:]
        if let ps = s["PlayState"] as? [String: Any] {
            out["pos"] = (ps["PositionTicks"] as? Double ?? 0) / 10_000_000
            out["paused"] = ps["IsPaused"]; out["method"] = ps["PlayMethod"]
        }
        if let t = s["TranscodingInfo"] as? [String: Any] {
            for k in ["IsPaused", "CompletionPercentage", "TranscodingPositionTicks", "TranscodingStartPositionTicks", "Framerate", "CurrentThrottle"] { out[k] = t[k] }
        } else { out["transcode"] = "none" }
        let j = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        return j.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// `plain`: skip the server's image enhancers (e.g. the TV-set frame some plugins draw on episode stills).
    /// Remembers each item's image tags (from any list the server sends), keyed "id|Kind".
    nonisolated(unsafe) static var imageTags: [String: String] = [:]
    static let tagLock = NSLock()

    nonisolated static func remember(_ items: [Item]) {
        tagLock.withLock {
            for it in items {
                for (k, v) in it.ImageTags ?? [:] { imageTags[it.Id + "|" + k] = v }
                if let b = it.BackdropImageTags?.first { imageTags[it.Id + "|Backdrop"] = b }
                if let p = it.ParentBackdropItemId, let b = it.ParentBackdropImageTags?.first { imageTags[p + "|Backdrop"] = b }
                if let p = it.ParentLogoItemId, let t = it.ParentLogoImageTag { imageTags[p + "|Logo"] = t }
                if let p = it.SeriesId, let t = it.SeriesPrimaryImageTag { imageTags[p + "|Primary"] = t }
                // Blurred previews: match each hash to the item that owns that image (by its tag)
                for (kind, byTag) in it.ImageBlurHashes ?? [:] {
                    for (tag, hash) in byTag {
                        if it.ImageTags?[kind] == tag || (kind == "Backdrop" && it.BackdropImageTags?.first == tag) {
                            BlurHash.remember(it.Id, kind, hash)
                        } else if kind == "Backdrop", let p = it.ParentBackdropItemId, it.ParentBackdropImageTags?.first == tag {
                            BlurHash.remember(p, kind, hash)
                        } else if kind == "Primary", let p = it.SeriesId, it.SeriesPrimaryImageTag == tag {
                            BlurHash.remember(p, kind, hash)
                        } else if kind == "Logo", let p = it.ParentLogoItemId, it.ParentLogoImageTag == tag {
                            BlurHash.remember(p, kind, hash)
                        }
                    }
                }
            }
        }
    }

    func image(_ id: String, _ kind: String = "Primary", width: Int = 400, plain: Bool = false) -> URL? {
        let tag = Self.tagLock.withLock { Self.imageTags[id + "|" + kind] }
        // quality=80: noticeably smaller files, no visible difference. The tag makes the link change when the
        // artwork changes, so the saved copy can be trusted until then.
        // No token in the link: ImageCache sends it in headers, so the saved copies on disk don't contain it
        return URL(string: "\(server)/Items/\(id)/Images/\(kind)?maxWidth=\(width)&quality=80"
            + (tag.map { "&tag=\($0)" } ?? "")
            + (plain ? "&EnableImageEnhancers=false" : ""))
    }

    // MARK: Libraries

    func loadLibs() async {
        guard let v: ItemList = try? await get("/Users/\(userId)/Views") else { return }
        var saved: [LibPref] = []
        if let data = d.data(forKey: "libs-\(userId)") {
            do { saved = try JSONDecoder().decode([LibPref].self, from: data) }
            catch { coveLog.error("Saved library order could not be read: \(String(describing: error), privacy: .public)") }
        }
        var out = saved.filter { s in v.Items.contains { $0.Id == s.id } }
        for l in v.Items where !out.contains(where: { $0.id == l.Id }) {
            out.append(LibPref(id: l.Id, name: l.Name, title: l.Name, kind: l.CollectionType))
        }
        for i in out.indices { out[i].kind = v.Items.first(where: { $0.Id == out[i].id })?.CollectionType }
        libs = out
    }

    func saveLibs() {
        d.set(try? JSONEncoder().encode(libs), forKey: "libs-\(userId)")
    }

    func libraryItems(_ lib: LibPref, limit: Int, start: Int = 0, sort: String? = nil, desc: Bool? = nil,
                      watch: String = "all", genre: String = "", letter: String = "", favorites: Bool = false,
                      types: String = "Movie,Series,BoxSet,Video,MusicVideo", groupCollections: Bool = false) async -> ItemList {
        var q = ["ParentId": lib.id, "Fields": "Overview,Genres,EndDate,Status", "Limit": String(limit), "StartIndex": String(start),
                 "Recursive": "true", "IncludeItemTypes": types]
        var by = "DateCreated", down = true
        switch sort ?? lib.style {
        case "name", "az": by = "SortName"; down = false
        case "release": by = "PremiereDate,SortName"
        case "top": by = "CommunityRating"
        case "random": by = "Random"
        default: break
        }
        q["SortBy"] = by
        q["SortOrder"] = (desc ?? down) ? "Descending" : "Ascending"
        var f: [String] = []
        if watch == "unwatched" { f.append("IsUnplayed") }
        if watch == "watched" { f.append("IsPlayed") }
        if favorites { f.append("IsFavorite") }
        if !f.isEmpty { q["Filters"] = f.joined(separator: ",") }
        if !genre.isEmpty { q["Genres"] = genre }
        if letter == "#" { q["NameLessThan"] = "A" } else if !letter.isEmpty { q["NameStartsWith"] = letter }
        // Movies that belong to a collection are replaced by that collection (Emby does the grouping)
        if groupCollections {
            q["GroupItemsIntoCollections"] = "true"
            if !types.contains("BoxSet") { q["IncludeItemTypes"] = types + ",BoxSet" }
        }
        let r: ItemList? = try? await get("/Users/\(userId)/Items", q)
        return r ?? ItemList(Items: [], TotalRecordCount: 0)
    }

    /// Emby's "Latest" list for a library (what the Emby apps show in their Latest rows).
    func latest(_ lib: LibPref, limit: Int) async -> [Item] {
        let r: [Item]? = try? await get("/Users/\(userId)/Items/Latest",
            ["ParentId": lib.id, "Limit": String(limit), "Fields": "Overview,Genres,EndDate,Status",
             // videos only: music libraries would otherwise put albums on Home (and in the banner)
             "IncludeItemTypes": "Movie,Series,Episode,BoxSet,Video,MusicVideo"])
        // Jellyfin ignores the type filter here, so drop albums, songs, books and photos ourselves
        let video: Set<String> = ["Movie", "Series", "Episode", "BoxSet", "Video", "MusicVideo"]
        return (r ?? []).filter { video.contains($0.`Type` ?? "") }
    }

    func genres(_ lib: LibPref) async -> [String] {
        let r: ItemList? = try? await get("/Genres", ["ParentId": lib.id, "UserId": userId, "SortBy": "SortName", "Recursive": "true"])
        return r?.Items.map { $0.Name } ?? []
    }

    func loadHome() async -> [Row] {
        if libs.isEmpty { await loadLibs() }
        var rows: [Row] = []
        if let r: ItemList = try? await get("/Users/\(userId)/Items/Resume",
            ["Fields": "Overview,Genres", "Limit": "20", "MediaTypes": "Video", "Recursive": "true"]),
           !r.Items.isEmpty { rows.append(Row(title: "Continue Watching", items: r.Items, feed: .resume)) }
        // Up Next (Apple TV): the next episode of each show you're watching, minus ones already in Continue Watching
        let started = Set(rows.first?.items.map { $0.id } ?? [])
        // Settings → Libraries → Sections → Up Next row (on by default)
        let showUp = UserDefaults.standard.object(forKey: "showUpNextRow") as? Bool ?? true
        let up = showUp ? await feed(.nextUp, limit: 20).filter { !started.contains($0.id) } : []
        if !up.isEmpty { rows.append(Row(title: "Up Next", items: up, feed: .nextUp)) }
        for lib in libs where lib.visible && lib.onHome {
            // "Latest" rows use Emby's own Latest list, like the Emby apps (newest titles, no collections,
            // new episodes grouped under their show)
            let items = lib.style == "latest" ? await latest(lib, limit: 20) : await libraryItems(lib, limit: 20).Items
            if !items.isEmpty { rows.append(Row(title: lib.title, items: items, libId: lib.id)) }
        }
        return rows
    }

    /// Items for a feed page (Continue Watching, Up Next, Recently Added).
    func feed(_ f: Feed, limit: Int = 100) async -> [Item] {
        let fields = "Overview,Genres"
        switch f {
        case .resume:
            let r: ItemList? = try? await get("/Users/\(userId)/Items/Resume",
                ["Fields": fields, "Limit": "\(limit)", "MediaTypes": "Video", "Recursive": "true"])
            return r?.Items ?? []
        case .nextUp:
            let r: ItemList? = try? await get("/Shows/NextUp", ["UserId": userId, "Fields": fields, "Limit": "\(limit)", "Legacynextup": "true"])
            return r?.Items ?? []
        case .recent:
            let r: ItemList? = try? await get("/Users/\(userId)/Items",
                ["SortBy": "DateCreated", "SortOrder": "Descending", "IncludeItemTypes": "Movie,Series",
                 "Recursive": "true", "Fields": fields, "Limit": "\(limit)"])
            return r?.Items ?? []
        }
    }

    func episodes(_ seriesId: String) async -> [Item] {
        let r: ItemList? = try? await get("/Shows/\(seriesId)/Episodes", ["UserId": userId, "Fields": "Overview"])
        return r?.Items ?? []
    }

    func seasons(_ seriesId: String) async -> [Item] {
        let r: ItemList? = try? await get("/Shows/\(seriesId)/Seasons", ["UserId": userId])
        return r?.Items ?? []
    }

    func children(_ parentId: String) async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["ParentId": parentId, "Fields": "Overview", "SortBy": "SortName"])
        return r?.Items ?? []
    }

    // MARK: Watched / favorites / play

    func isPlayed(_ it: Item) -> Bool { played[it.id] ?? it.UserData?.Played ?? false }
    /// Where to resume an item from, in seconds (0 = start). Ignores the first 30 s.
    /// A saved position wins even if the item is marked watched (e.g. re-watching a movie);
    /// finishing an item or marking it watched in the app clears the position.
    func resumeAt(_ it: Item) -> Double {
        let t = positions[it.id] ?? Double(it.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000
        return t > 30 ? t : 0
    }

    /// Next episode to watch for a series (in progress or first unwatched), as the server sees it.
    func nextUp(_ seriesId: String) async -> Item? {
        let r: ItemList? = try? await get("/Shows/NextUp", ["SeriesId": seriesId, "UserId": userId, "Fields": "Overview", "Limit": "1"])
        return r?.Items.first
    }

    // MARK: Playback progress (lets the server remember where you stopped)

    private func postJSON(_ path: String, _ body: [String: Any]) async {
        guard let url = URL(string: server + path) else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&r)
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await Net.session.data(for: r)
    }

    /// One playback as the server tracks it. Emby rejects reports without a PlaySessionId (HTTP 400).
    struct PlaySession {
        let itemId: String
        let sourceId: String?
        let method: String          // DirectPlay | DirectStream | Transcode
        /// Must be the server's PlaySessionId (from the stream URL), or the server can't
        /// match our stop report to its transcode and leaves the ffmpeg job + temp files running.
        var id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        init(itemId: String, sourceId: String?, method: String, url: URL) {
            self.itemId = itemId; self.sourceId = sourceId; self.method = method
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let v = q.first(where: { $0.name.lowercased() == "playsessionid" })?.value, !v.isEmpty { id = v }
        }
    }

    /// Kills the server-side transcode (ffmpeg) and its temp segments for this playback.
    func stopEncoding(_ s: PlaySession) async {
        guard s.method != "DirectPlay" else { return }
        await send("DELETE", "/Videos/ActiveEncodings?DeviceId=\(deviceId)&PlaySessionId=\(s.id)")
    }

    private func progressBody(_ s: PlaySession, _ sec: Double, paused: Bool = false) -> [String: Any] {
        var b: [String: Any] = ["ItemId": s.itemId, "PositionTicks": Int64(max(0, sec) * 10_000_000),
                                "IsPaused": paused, "CanSeek": true,
                                "PlaySessionId": s.id, "PlayMethod": s.method]
        if let sourceId = s.sourceId { b["MediaSourceId"] = sourceId }
        return b
    }

    func reportStart(_ s: PlaySession, _ sec: Double) async {
        await postJSON("/Sessions/Playing", progressBody(s, sec))
    }

    func reportProgress(_ s: PlaySession, _ sec: Double, paused: Bool) async {
        await postJSON("/Sessions/Playing/Progress", progressBody(s, sec, paused: paused))
    }

    /// Tells the server this playback is still alive (used while paused, so it keeps the transcode running).
    func ping(_ s: PlaySession) async {
        await send("POST", "/Sessions/Playing/Ping?PlaySessionId=\(s.id)")
    }

    /// Sessions stopped recently, whose transcode may still (or again) be running on the server.
    private var recentStopped: [PlaySession] = []

    /// `quick`: the app is quitting, so skip the delayed second and third kill (they would never run).
    func reportStopped(_ s: PlaySession, _ sec: Double, duration: Double, quick: Bool = false) async {
        let finished = duration > 0 && sec / duration > 0.9
        positions[s.itemId] = finished ? 0 : sec
        if finished { played[s.itemId] = true }
        recentStopped.append(s)
        if recentStopped.count > 6 { recentStopped.removeFirst() }
        await postJSON("/Sessions/Playing/Stopped", progressBody(s, sec))
        await stopEncoding(s)
        if quick { return }
        // A segment request that was still in flight when playback stopped can make the server start a NEW
        // transcode right after we killed the old one. That leftover job has a shifted timeline and gets
        // reused the next time the same title is played, which puts the subtitles out of sync (this only
        // happened when you left while the video was playing, not after pausing first). Kill again shortly after.
        for delay in [2.0, 6.0] {
            try? await Task.sleep(for: .seconds(delay))
            await stopEncoding(s)
        }
    }

    /// Called before a new playback asks for its stream: make sure nothing left over from earlier playbacks is running.
    func killStaleEncodings() async {
        let list = recentStopped
        recentStopped = []
        for s in list { await stopEncoding(s) }
    }

    func isFav(_ it: Item) -> Bool { faved[it.id] ?? it.UserData?.IsFavorite ?? false }

    private func send(_ method: String, _ path: String) async {
        guard let url = URL(string: server + path) else { return }
        var r = URLRequest(url: url)
        r.httpMethod = method
        authorize(&r)
        _ = try? await Net.session.data(for: r)
    }
    func setPlayed(_ id: String, _ v: Bool) async {
        played[id] = v
        positions[id] = 0
        await send(v ? "POST" : "DELETE", "/Users/\(userId)/PlayedItems/\(id)")
    }
    func setFav(_ id: String, _ v: Bool) async {
        faved[id] = v
        await send(v ? "POST" : "DELETE", "/Users/\(userId)/FavoriteItems/\(id)")
    }
    func play(_ it: Item) async {
        if it.isSeries {
            let eps = await episodes(it.id)
            let next = await nextUp(it.id)
            if let e = next ?? eps.first(where: { !isPlayed($0) }) ?? eps.first {
                playing = PlayRequest(item: e, start: resumeAt(e))
            }
        } else if it.isBox {
            if let f = await children(it.id).first { playing = PlayRequest(item: f) }
        } else { playing = PlayRequest(item: it, start: resumeAt(it)) }
    }

    func full(_ id: String) async -> Full? {
        try? await get("/Users/\(userId)/Items/\(id)", ["Fields": "Overview,People,Genres,Studios,MediaSources,MediaStreams,Taglines,DateCreated,ExternalUrls,RemoteTrailers,Chapters"])
    }

    /// Collections (box sets) this movie or show belongs to, for "Included In". Jellyfin has its own call for
    /// it (newer servers; older ones answer with an error, so nothing shows) and ignores Emby's ListItemIds,
    /// which would return every collection. A long answer means the filter wasn't applied, so show nothing.
    func collections(containing id: String) async -> [Item] {
        let r: ItemList? = isJellyfin
            ? try? await get("/Items/\(id)/Collections", ["userId": userId])
            : try? await get("/Users/\(userId)/Items", ["Recursive": "true", "IncludeItemTypes": "BoxSet",
                                                        "ListItemIds": id, "Fields": "Overview"])
        let list = r?.Items ?? []
        return list.count > 10 ? [] : list
    }

    func similar(_ id: String) async -> [Item] {
        let r: ItemList? = try? await get("/Items/\(id)/Similar", ["UserId": userId, "Limit": "12", "Fields": "Overview"])
        return r?.Items ?? []
    }

    /// Movies and series the user marked as favorite, across all libraries.
    /// Movies and shows in the user's libraries featuring this person, newest first.
    func itemsWithPerson(_ personId: String) async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["PersonIds": personId, "Recursive": "true",
            "IncludeItemTypes": "Movie,Series", "SortBy": "ProductionYear,SortName", "SortOrder": "Descending",
            "Fields": "Overview,Genres"])
        return r?.Items ?? []
    }

    /// A person's own record (name, biography).
    func person(_ id: String) async -> Item? {
        try? await get("/Users/\(userId)/Items/\(id)", ["Fields": "Overview"])
    }

    /// Any item's record by id (used to find the series behind an episode).
    func itemRecord(_ id: String) async -> Item? {
        try? await get("/Users/\(userId)/Items/\(id)", ["Fields": "Overview"])
    }

    func favorites() async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["Filters": "IsFavorite", "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,BoxSet", "SortBy": "SortName", "SortOrder": "Ascending",
            "Fields": "Overview,Genres,EndDate,Status"])
        return r?.Items ?? []
    }

    func search(_ term: String) async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["SearchTerm": term, "Recursive": "true", "Limit": "60",
            "IncludeItemTypes": "Movie,Series,BoxSet,Video,MusicVideo,Episode", "Fields": "Overview"])
        return r?.Items ?? []
    }

    /// Actors, directors etc. matching the search, limited to people in the user's libraries.
    func searchPeople(_ term: String) async -> [Item] {
        let r: ItemList? = try? await get("/Persons", ["SearchTerm": term, "UserId": userId, "Limit": "24",
            "Recursive": "true", "Fields": "PrimaryImageAspectRatio"])
        return r?.Items ?? []
    }

    // MARK: Playback

    private func absolute(_ path: String, noCopy: Bool = false) -> URL? {
        var s = path.hasPrefix("http") ? path : server + (path.hasPrefix("/") ? path : "/" + path)
        // The token goes only to the server we signed in to, never to another host named in a server reply
        let ours = URL(string: s).flatMap { u in URL(string: server).map { Net.sameOrigin(u, $0) } } ?? false
        if ours, !s.contains("api_key=") && !s.contains("ApiKey=") { s += (s.contains("?") ? "&" : "?") + keyName + "=" + token }
        if noCopy { s = Self.withoutVideoCopy(s) }
        return URL(string: s)
    }

    /// Asks the server to re-encode the video instead of copying it. A copied video can only start at a
    /// keyframe, so a stream that starts part-way through the file (resume) begins a few seconds before the
    /// position the player thinks it has, which puts the subtitles ahead of the picture.
    static func withoutVideoCopy(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var q = (c.queryItems ?? []).filter { $0.name.lowercased() != "allowvideostreamcopy" }
        q.append(URLQueryItem(name: "AllowVideoStreamCopy", value: "false"))
        c.queryItems = q
        return c.string ?? url
    }

    /// The server ignores the requested subtitle and burns in the user's default track,
    /// so force the chosen track into the transcode URL (or strip subtitles when "Off").
    static func fixSubtitle(_ url: String, _ sub: Int?) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var q = (c.queryItems ?? []).filter { $0.name != "SubtitleStreamIndex" && $0.name != "SubtitleMethod" }
        if let sub {
            q.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(sub)))
            q.append(URLQueryItem(name: "SubtitleMethod", value: "Encode"))
        }
        c.queryItems = q
        return c.string ?? url
    }

    /// Downloads a subtitle track as SRT (the server converts embedded text subs too).
    /// Returns nil for image subtitles (PGS etc.) that can't be converted.
    func subtitleCues(_ itemId: String, _ sourceId: String?, _ index: Int) async -> [Cue]? {
        var sid = sourceId
        if sid == nil { sid = await full(itemId)?.MediaSources?.first?.Id }
        guard let sid, let u = URL(string: "\(server)/Videos/\(itemId)/\(sid)/Subtitles/\(index)/Stream.srt") else { return nil }
        // Embedded subtitles are extracted from the whole video file the first time, which can take minutes.
        var r = URLRequest(url: u)
        authorize(&r)
        r.timeoutInterval = 600
        guard let (data, resp) = try? await Net.session.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let cues = Cue.parseSRT(text)
        return cues.isEmpty ? nil : cues
    }

    /// Asks the server how to play the item for AVPlayer: direct play for MP4/MOV, otherwise HLS transcode
    /// (also used whenever a subtitle, a different audio track or a lower quality is chosen).
    func resolveStream(_ req: PlayRequest, direct: Bool = true, reencode: Bool = false) async -> URL? {
        let id = req.item.id
        let canDirect = direct && !req.transcode
        let profile: [String: Any] = [
            "Name": "Cove Mac",
            "MaxStreamingBitrate": req.maxBitrate ?? 120_000_000,
            "DirectPlayProfiles": canDirect
                ? [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3"]]
                : [[String: Any]](),
            "TranscodingProfiles": [["Container": "ts", "Type": "Video", "AudioCodec": "aac", "VideoCodec": "h264",
                                     "Context": "Streaming", "Protocol": "hls", "MaxAudioChannels": "2",
                                     "MinSegments": "1", "BreakOnNonKeyFrames": true]],
            "SubtitleProfiles": ["srt", "subrip", "ass", "ssa", "vtt", "pgs", "pgssub", "dvdsub"].map { ["Format": $0, "Method": "Encode"] }
        ]
        var qi = [URLQueryItem(name: "UserId", value: userId),
                  URLQueryItem(name: "IsPlayback", value: "true"),
                  URLQueryItem(name: "AutoOpenLiveStream", value: "true")]
        if let v = req.sourceId { qi.append(URLQueryItem(name: "MediaSourceId", value: v)) }
        if let v = req.audio { qi.append(URLQueryItem(name: "AudioStreamIndex", value: String(v))) }
        if let v = req.sub { qi.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(v))) }
        if let v = req.maxBitrate { qi.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(v))) }
        guard var c = URLComponents(string: "\(server)/Items/\(id)/PlaybackInfo") else { return nil }
        c.queryItems = qi
        guard let pu = c.url else { return nil }
        var r = URLRequest(url: pu)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&r)
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["DeviceProfile": profile])
        if let (data, _) = try? await Net.session.data(for: r),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = j["MediaSources"] as? [[String: Any]],
           let src = list.first(where: { ($0["Id"] as? String) == req.sourceId }) ?? list.first {
            let sid = src["Id"] as? String ?? id
            let cont = (src["Container"] as? String ?? "").lowercased().split(separator: ",").map(String.init)
            if canDirect, src["SupportsDirectPlay"] as? Bool == true,
               cont.contains(where: { ["mp4", "m4v", "mov"].contains($0) }) {
                return URL(string: "\(server)/Videos/\(id)/stream.mp4?Static=true&MediaSourceId=\(sid)&\(keyName)=\(token)")
            }
            if let t = src["TranscodingUrl"] as? String { return absolute(Self.fixSubtitle(t, req.sub), noCopy: reencode) }
            if let t = src["DirectStreamUrl"] as? String { return absolute(t, noCopy: reencode) }
        }
        let fallback = "\(server)/Videos/\(id)/master.m3u8?MediaSourceId=\(req.sourceId ?? id)&DeviceId=\(deviceId)&PlaySessionId=\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))&VideoCodec=h264&AudioCodec=aac&\(keyName)=\(token)"
        return URL(string: reencode ? Self.withoutVideoCopy(fallback) : fallback)
    }
}


/// Subtitle formats the server can only burn into the video (pictures, not text).
let imageSubCodecs: Set<String> = ["pgs", "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "xsub"]

/// Preferred-language subtitle track: text formats first, then any.
func preferredSub(_ streams: [MStream], lang: String) -> Int? {
    let subs = streams.filter { $0.`Type` == "Subtitle" && subLangName($0).lowercased() == lang.lowercased() }
    let text = subs.first { !imageSubCodecs.contains(($0.Codec ?? "").lowercased()) }
    return (text ?? subs.first)?.Index
}

/// The track's language in English ("Romanian"), so tracks match the language chosen in Settings on both
/// servers: from the language code when there is one ("ron", "rum", "ro" → Romanian), otherwise from the title
/// (Emby writes "Romanian (SRT)", Jellyfin "Romanian - SUBRIP - External").
func subLangName(_ st: MStream) -> String {
    if let code = st.Language?.trimmingCharacters(in: .whitespaces), !code.isEmpty,
       let name = Locale(identifier: "en").localizedString(forLanguageCode: code),
       name.lowercased() != code.lowercased(), !name.lowercased().contains("unknown") {
        return name
    }
    let t = st.DisplayTitle ?? st.Language ?? "Unknown"
    return (t.components(separatedBy: " (").first ?? t).components(separatedBy: " - ").first ?? t
}

struct Cue {
    let start: Double
    let end: Double
    let text: String

    static func parseSRT(_ srt: String) -> [Cue] {
        func secs(_ t: String) -> Double? {
            let p = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let s = Double(p[2]) else { return nil }
            return h * 3600 + m * 60 + s
        }
        var out: [Cue] = []
        let blocks = srt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = secs(parts[0]), let e = secs(String(parts[1].prefix(13))) else { continue }
            let text = lines[(ti + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            if !text.isEmpty { out.append(Cue(start: a, end: e, text: text)) }
        }
        return out.sorted { $0.start < $1.start }
    }
}
