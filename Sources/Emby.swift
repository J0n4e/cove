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
    /// Folders (collections): how many items they hold. With UserData.UnplayedItemCount it tells whether a
    /// collection is fully watched (CollectionWatched.swift).
    var ChildCount: Int? = nil
    /// Banner "Newest" only (asked for in Fields there): when a film was added / a show last got new content.
    var DateCreated: String? = nil
    var DateLastContentAdded: String? = nil
    let UserData: UD?
    let RunTimeTicks: Int64?
    let CommunityRating: Double?
    let Genres: [String]?
    let EndDate: String?
    let Status: String?
    let PremiereDate: String?            // a person's birth date
    let ProductionLocations: [String]?   // a person's birthplace
    let ProviderIds: [String: String]?   // IMDb / TMDB / TVDB ids, for Trakt (ratings on posters, watched sync)
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
    var trailer: URL? = nil       // a YouTube trailer of the item, played with YouTube's player instead
    var startPaused = false       // SyncPlay: loaded paused, the group starts it
    /// An embedded text subtitle carried inside the HLS stream (SubtitleMethod=Hls, WebVTT segments) and read by
    /// the app from the player item. Unlike `sub` it doesn't force a conversion and isn't sent to PlaybackInfo.
    var hlsSub: Int? = nil
    /// Play collection: the collection's films and where this one is (collection mode, CollectionPlay.swift).
    /// Nil for every other way of playing a film, which then behaves as before.
    var collection: CollectionQueue? = nil
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
    let VideoRange: String?       // "SDR", "HDR 10", "Dolby Vision"… (video streams)
    let Width: Int?
    let Height: Int?
    let BitRate: Int?
    /// The track's own name, when the file gives one ("Director's commentary"); decoded when present
    var Title: String? = nil
    /// Audio: "5.1", "stereo"… (decoded when present)
    var ChannelLayout: String? = nil
    /// A separate subtitle file next to the video (decoded when present)
    var IsExternal: Bool? = nil
    /// Video facts for Cast's copy/transcode choice (decoded when present): "High", 40/4.0, 8/10, interlaced
    var Profile: String? = nil
    var Level: Double? = nil
    var BitDepth: Int? = nil
    var IsInterlaced: Bool? = nil
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
    /// The session's device (admin actions: never on Cove's own; Sign out device).
    var DeviceId: String? = nil
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
        /// The source's streams (stream details popover: the codecs going in).
        var MediaStreams: [Stream]? = nil
    }
    struct Stream: Decodable { let `Type`: String?; let Codec: String?; var IsDefault: Bool? = nil }
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

/// Audio/subtitle choices remembered per series, and per collection ("box:<id>") in collection mode.
enum SeriesLang {
    /// Where a request's choices are kept: the collection in collection mode, else the episode's series.
    static func key(_ r: PlayRequest) -> String? {
        if let c = r.collection { return "box:" + c.id }
        if r.item.isEpisode, let sid = r.item.SeriesId { return sid }
        return nil
    }
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
    /// "Imdb": "tt…", "Tmdb": "603", "Tvdb": … (for Trakt)
    let ProviderIds: [String: String]?
    // For Trakt watched sync: what the item is, and for a season its show and number
    let `Type`: String?
    let SeriesId: String?
    let IndexNumber: Int?
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
    let title: String; var items: [Item]
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

/// The Activity section (stored id stays `NavOrder.nowPlaying`, so saved order/visibility survive): its visible
/// name and its static icon in the top bar, sidebar, page title and Settings → Libraries.
enum ActivitySection {
    static let title = "Activity"
    static let icon = "chart.bar.xaxis"
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

/// A server the user has signed in to; the token is kept so switching back needs no password. In the preferences
/// file the list is saved without tokens; the tokens are sealed separately (see ServerStore).

struct SavedServer: Codable, Identifiable, Hashable {
    var url: String
    var name: String
    var user: String
    var token: String?
    var userId: String?
    var id: String { url.lowercased() }
}

/// Saves the server list: the non-secret part (name, address, user) as JSON under "servers", the tokens as one
/// sealed dictionary (server id -> token, see SealedPrefs) under "serverTokens". Before 1.18 the tokens were in
/// the "servers" JSON in plain text (and before 1.15 under "token"); `load` moves them over once.
enum ServerStore {
    static let listKey = "servers"
    static let tokensKey = "serverTokens"
    static let legacyTokenKey = "token"

    static func sealedTokens(_ d: UserDefaults) -> [String: String]? {
        guard let s = SealedPrefs.get(tokensKey, in: d), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Seals the tokens, reads them back, and only then writes the list without them. If sealing fails the
    /// plaintext list is kept (never lose a sign-in). Returns true when the tokens are sealed.
    @discardableResult
    static func save(_ servers: [SavedServer], to d: UserDefaults) -> Bool {
        var tokens: [String: String] = [:]
        for e in servers { if let t = e.token, !t.isEmpty { tokens[e.id] = t } }
        var sealed = tokens.isEmpty
        if tokens.isEmpty { SealedPrefs.set(nil, for: tokensKey, in: d) }
        else if let data = try? JSONEncoder().encode(tokens), let json = String(data: data, encoding: .utf8) {
            SealedPrefs.set(json, for: tokensKey, in: d)
            sealed = sealedTokens(d) == tokens
        }
        let list = sealed ? servers.map { var x = $0; x.token = nil; return x } : servers
        if !sealed { coveLog.error("Server sign-ins could not be sealed; kept in the preferences as before") }
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: listKey) }
        return sealed
    }

    /// Reads the list with its tokens. Moves plaintext tokens (in "servers" or the legacy "token" key) into the
    /// sealed store once; the plaintext is removed only after the sealed copy reads back the same.
    static func load(from d: UserDefaults, server: String, userId: String) -> [SavedServer] {
        let legacyToken = d.string(forKey: legacyTokenKey) ?? ""
        var list: [SavedServer] = []
        if let data = d.data(forKey: listKey) {
            do { list = try JSONDecoder().decode([SavedServer].self, from: data) }
            catch { coveLog.error("Saved servers could not be read: \(String(describing: error), privacy: .public)") }
        }
        // Remember the server from before saved servers existed.
        if list.isEmpty, !server.isEmpty, !legacyToken.isEmpty {
            list = [SavedServer(url: server, name: server, user: "", token: legacyToken, userId: userId)]
        }
        var plaintext = !legacyToken.isEmpty
        let sealed = sealedTokens(d) ?? [:]
        for i in list.indices {
            if list[i].token != nil { plaintext = true }
            if let t = sealed[list[i].id] { list[i].token = t }
            if list[i].token == nil, list[i].id == server.lowercased(), !legacyToken.isEmpty { list[i].token = legacyToken }
        }
        if plaintext, save(list, to: d) { d.removeObject(forKey: legacyTokenKey) }
        return list
    }
}

enum LoginError: LocalizedError {
    case wrongPassword
    var errorDescription: String? { "Wrong username or password." }
}

@MainActor
final class Emby: ObservableObject {
    private let d = UserDefaults.standard
    @Published var server = "" { didSet { updateImageAuth() } }
    @Published var token = "" { didSet { updateImageAuth() } }
    @Published var userId = ""
    @Published var libs: [LibPref] = []
    @Published var playing: PlayRequest? {
        didSet {
            // Playback started from Home has ended (stopped or finished): show that movie or show, not Home
            guard playing == nil, oldValue != nil, let it = returnAfterPlay else { return }
            returnAfterPlay = nil
            DispatchQueue.main.async { self.openPage(it) }
        }
    }
    /// Set when playback starts from Home (Continue Watching, the banner): the page to open when it ends
    var returnAfterPlay: Item?
    /// Set by anything that wants the main window to open an item's page (e.g. clicking a hover preview card).
    @Published var openRequest: Item?
    /// Season to pre-select when the opened item is a series (Continue Watching card click).
    @Published var openSeason: Int?
    @Published var played: [String: Bool] = [:] {
        // A collection's ✓ follows its films: any change recomputes the collections whose films are known
        didSet { if !boxFilms.isEmpty { syncCollections() } }
    }
    /// Collections whose films are known (collection id → film ids), from the collection page or the badges.
    /// Their ✓ is derived from the films' (CollectionWatched.swift).
    var boxFilms: [String: [String]] = [:]
    /// Collections whose films are being fetched (one fetch each)
    var boxLoading: Set<String> = []
    @Published var faved: [String: Bool] = [:]
    /// Favorite people from the last `favoritePeople()` call (cast tiles have no favorite flag of their own)
    @Published var favPeopleIds: Set<String> = []
    /// Goes up once the server has taken a favorite change, so the Favorites page can reload what it shows
    @Published var favRevision = 0
    /// Short confirmation shown at the bottom of the window ("Added … to Favorites")
    struct Toast: Equatable { let id = UUID(); let text: String; let icon: String }
    @Published var toast: Toast?
    func isPersonFav(_ id: String) -> Bool { faved[id] ?? favPeopleIds.contains(id) }
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

    /// Why the last server request failed, shown on Home with Retry (nil again after one succeeds).
    @Published var lastFailure: String?
    /// The server no longer accepts our sign-in (confirmed with /Users/{id}): the app asks to sign in again.
    @Published var sessionExpired = false
    private var checkingSession = false

    /// A short explanation of a failed request, for the screen.
    static func describe(_ error: Error, server name: String = "the server") -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "You're offline. Check your network connection."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
                return "\(name) has a certificate Cove can't trust, so the connection was refused."
            case .userAuthenticationRequired: return "\(name) didn't accept the sign-in."
            case .badServerResponse: return "\(name) answered with an error. Try again in a moment."
            case .cancelled: return ""
            default: return "Can't reach \(name). Check that it's running and that you're on the right network."
            }
        }
        if error is DecodingError { return "\(name) sent an answer Cove couldn't read." }
        return "Something went wrong talking to \(name)."
    }

    private func noteFailure(_ error: Error) {
        let m = Self.describe(error, server: currentServerName)
        if !m.isEmpty, lastFailure != m { lastFailure = m }
    }

    /// A 401 can come from one endpoint the user isn't allowed to use, so check the sign-in itself before
    /// telling the user it expired.
    private func checkSession() {
        guard !checkingSession, !sessionExpired, loggedIn, let u = URL(string: "\(server)/Users/\(userId)") else { return }
        checkingSession = true
        let t = token
        var r = URLRequest(url: u, timeoutInterval: 10)
        authorize(&r, token: t)
        Task {
            let status = ((try? await Net.session.data(for: r))?.1 as? HTTPURLResponse)?.statusCode
            checkingSession = false
            if status == 401, t == token { sessionExpired = true }
        }
    }

    /// "Sign in again" after the session expired: forget the token for this server and go back to the list.
    func expireSession() {
        sessionExpired = false
        if let i = servers.firstIndex(where: { $0.id == server.lowercased() }) {
            servers[i].token = nil; servers[i].userId = nil; saveServers()
        }
        switchServer()
    }

    /// The signed-in server is Jellyfin (not Emby). Jellyfin speaks the same API, but takes the token in the
    /// `Authorization` header and as `ApiKey=` in links, where Emby uses `X-Emby-Token` and `api_key=`.
    @Published var isJellyfin = false
    /// SyncPlay phase 1 (Jellyfin only): socket, time sync, capabilities. Follows this object's sign-in state itself.
    let syncPlay = SyncPlayService()
    /// Query name for the token in image / stream / subtitle links.
    var keyName: String { isJellyfin ? "ApiKey" : "api_key" }

    /// Pictures are fetched with the token in headers (not in the link), so the saved image cache holds no token.
    private func updateImageAuth() {
        ImageCache.shared.setAuth(server: server, headers: token.isEmpty ? [:]
            : ["X-Emby-Token": token, "Authorization": authHeader + ", Token=\"\(token)\""])
    }

    /// Adds the token to a request in every form Emby and Jellyfin accept.
    func authorize(_ r: inout URLRequest, token t: String? = nil) {
        let t = t ?? token
        r.setValue(t, forHTTPHeaderField: "X-Emby-Token")
        r.setValue(authHeader + ", Token=\"\(t)\"", forHTTPHeaderField: "Authorization")
        Net.setLanguage(&r)
    }

    /// Asks the server what it is ("Jellyfin Server" in ProductName) and remembers the answer per server.
    static func detectJellyfin(_ s: String) async -> Bool? {
        guard let u = URL(string: s + "/System/Info/Public"),
              let (data, _) = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 10)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((j["ProductName"] as? String) ?? "").localizedCaseInsensitiveContains("jellyfin")
    }

    func refreshServerKind() async {
        let s = server
        let key = "jellyfin-" + s.lowercased()
        isJellyfin = d.bool(forKey: key)
        ReportIssue.note(server: s, jellyfin: isJellyfin, version: d.string(forKey: "serverVersion-" + s.lowercased()))
        guard let j = await Self.detectJellyfin(s) else { return }
        d.set(j, forKey: key)
        if server == s { isJellyfin = j }       // the user may have switched server meanwhile
        // Server version for the bug report (Report an issue…), cached per server
        if let u = URL(string: s + "/System/Info/Public"),
           let (data, _) = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 10)),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = o["Version"] as? String {
            d.set(v, forKey: "serverVersion-" + s.lowercased())
        }
        if server == s {
            ReportIssue.note(server: s, jellyfin: j, version: d.string(forKey: "serverVersion-" + s.lowercased()))
        }
    }

    /// The list goes to the preferences file, its sign-in tokens sealed (ServerStore). Keychain storage is
    /// paused until Cove is signed with an Apple Developer ID: with our self-signed certificate macOS ties each
    /// Keychain item to one exact build, so every update would ask for Keychain access.
    private func saveServers() { ServerStore.save(servers, to: d) }

    private func upsert(_ e: SavedServer) {
        if let i = servers.firstIndex(where: { $0.id == e.id }) { servers[i] = e } else { servers.append(e) }
        saveServers()
    }

    /// Picks https when the user typed no scheme and the server answers on it; otherwise http, as before.
    static func resolveAddress(_ raw: String) async -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasScheme(t) else { return normalize(t) }
        let secure = normalize("https://" + t)
        // Ports that only speak https (Emby/Jellyfin's 8920, 443): never fall back to plain http there
        if let p = URL(string: secure)?.port, p == 8920 || p == 443 { return secure }
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
        SubtitleCache.shared.removeServer(e.url)
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

    static func hasScheme(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://")
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)   // pasted addresses often end in a newline
        if !hasScheme(s) { s = "http://" + s }                          // (a host named "httpnas" is a host)
        // An address copied from the browser: drop "#!/home", "?query" and the web app's path ("/web/index.html")
        if let i = s.firstIndex(where: { $0 == "#" || $0 == "?" }) { s = String(s[..<i]) }
        if let r = s.range(of: "/web/", options: .caseInsensitive) { s = String(s[..<r.lowerBound]) }
        else if s.lowercased().hasSuffix("/web") { s.removeLast(4) }
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
        await ensureLibs()      // the top bar lists every library whatever page shows first
        return .ok
    }

    private func serverName(_ s: String) async -> String? {
        guard let u = URL(string: s + "/System/Info/Public"),
              let (data, _) = try? await Net.session.data(for: URLRequest(url: u, timeoutInterval: 10)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j["ServerName"] as? String
    }

    private func resetSession() {
        boxFilms = [:]; boxLoading = []
        playing = nil; libs = []; played = [:]; faved = [:]
        libsFlight = SingleFlight()   // a load still running for the previous server/user is not joined
        // Resume points and image tags/previews are keyed by item id only, so they must not carry over to
        // another server or user
        positions = [:]
        Self.tagLock.withLock { Self.imageTags.removeAll() }
        BlurHash.lock.withLock { BlurHash.hashes.removeAll() }
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
        var list = ServerStore.load(from: d, server: server, userId: userId)
        // Test builds of the Keychain change put tokens in the Keychain: move any such token back once and delete
        // the item (Macs that never ran those builds have none, so nothing is asked)
        var moved = false
        for i in list.indices where list[i].token == nil {
            if let t = TokenStore.get(list[i].id) { list[i].token = t; moved = true }
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
        syncPlay.attach(to: self)
    }

    /// The server lists Cove under Devices / Activity with this version: the installed app's own number
    /// (e.g. 1.15.12), so it is always current after an update. "1.0" only when run without an app bundle.
    var authHeader: String {
        "MediaBrowser Client=\"Cove\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"\(AppVersion.number)\""
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
        let (data, resp) = try await Net.session.data(for: r)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 200 {
        case 200..<300: break
        case 401, 403: throw LoginError.wrongPassword
        default: throw URLError(.badServerResponse)
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = j["AccessToken"] as? String,
              let u = (j["User"] as? [String: Any])?["Id"] as? String
        else { throw URLError(.userAuthenticationRequired) }
        resetSession()
        server = s; token = t; userId = u
        d.set(s, forKey: "server"); d.set(u, forKey: "uid")
        await refreshServerKind()
        await ensureLibs()      // the top bar lists every library whatever page shows first
        let typed = label.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? (await serverName(s) ?? servers.first { $0.id == s.lowercased() }?.name ?? s) : typed
        upsert(SavedServer(url: s, name: name, user: user, token: t, userId: u))
    }

    /// Signs out of this server: forgets its token but keeps it (and the username) in the list.
    func logout() {
        revoke(server: server, token: token)
        ImageCache.shared.clear()
        SubtitleCache.shared.removeServer(server)
        if let i = servers.firstIndex(where: { $0.id == server.lowercased() }) {
            servers[i].token = nil; servers[i].userId = nil; saveServers()
        }
        resetSession()
        token = ""; userId = ""
        d.removeObject(forKey: "token"); d.removeObject(forKey: "uid")
    }

    /// Turns a server answer into Cove's data away from the main thread: a big answer (a library page,
    /// every episode of a long series) used to freeze the window for a moment while it was read.
    nonisolated static func decodeOffMain<T: Decodable>(_ type: T.Type, _ data: Data) async throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func get<T: Decodable>(_ path: String, _ q: [String: String] = [:]) async throws -> T {
        var q = q
        // The server leaves the year out unless asked; posters show it under the title
        // ProviderIds: posters show your Trakt rating, matched by IMDb / TMDB / TVDB id
        var fields = q["Fields"].map { $0.split(separator: ",").map(String.init) } ?? []
        for extra in ["ProductionYear", "ProviderIds", "ChildCount"] where !fields.contains(extra) { fields.append(extra) }
        q["Fields"] = fields.joined(separator: ",")
        guard var c = URLComponents(string: server + path) else { throw URLError(.badURL) }
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" as is, and servers read it as a space ("C++", "Love + Death" would fail)
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let u = c.url else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        authorize(&r)
        let v: T
        do {
            let (data, resp) = try await Net.session.data(for: r)
            // Errors used to be decoded as if they were answers, so screens just stayed empty
            switch (resp as? HTTPURLResponse)?.statusCode ?? 200 {
            case 200..<300: break
            case 401: checkSession(); throw URLError(.userAuthenticationRequired)
            default: throw URLError(.badServerResponse)
            }
            v = try await Self.decodeOffMain(T.self, data)
            if lastFailure != nil { lastFailure = nil }
        } catch {
            if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                coveLog.error("GET \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if (error as? URLError)?.code != .userAuthenticationRequired { noteFailure(error) }
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
        return Self.playingSessions(all ?? [])
    }
    /// The sessions that are playing something, in a stable order (polling and the live socket's Sessions messages).
    nonisolated static func playingSessions(_ all: [ActiveSession]) -> [ActiveSession] {
        all.filter { $0.NowPlayingItem != nil }
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
    /// Capped: a long session browsing a big server would otherwise keep every tag it ever saw.
    nonisolated(unsafe) static var imageTags = BoundedMap<String>(cap: 50_000)
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

    private var libsFlight = SingleFlight<Void>()

    /// Loads the libraries once per session: callers while a load runs (sign-in, Home, the root view) wait for
    /// that one instead of asking the server again. Does nothing when they are already loaded.
    func ensureLibs() async {
        guard libs.isEmpty else { return }
        try? await libsFlight.run { await self.loadLibs() }
    }

    func loadLibs() async {
        let s = server, u = userId
        guard let v: ItemList = try? await get("/Users/\(u)/Views"), server == s, userId == u else { return }
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
                      types: String = "Movie,Series,BoxSet,Video,MusicVideo", groupCollections: Bool = false) async -> ItemList? {
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
        // nil when the request failed: the caller keeps what it has (an empty list would end paging for good)
        return try? await get("/Users/\(userId)/Items", q)
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
        lastFailure = nil
        await ensureLibs()
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
            let items = lib.style == "latest" ? await latest(lib, limit: 20) : (await libraryItems(lib, limit: 20))?.Items ?? []
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

    /// A collection's titles in release order, oldest first, so a series of films reads in the order they came out.
    func children(_ parentId: String) async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["ParentId": parentId, "Fields": "Overview",
                                                                    "SortBy": "PremiereDate,ProductionYear,SortName", "SortOrder": "Ascending"])
        return r?.Items ?? []
    }

    // MARK: Watched / favorites / play

    func isPlayed(_ it: Item) -> Bool {
        if let p = played[it.id] { return p }
        // Collections: the server often doesn't keep a BoxSet's own Played; its unwatched count tells
        if it.isBox, let d = CollectionWatched.fromUserData(it) { return d }
        return it.UserData?.Played ?? false
    }
    /// Where to resume an item from, in seconds (0 = start). Ignores the first 30 s.
    /// A saved position wins even if the item is marked watched (e.g. re-watching a movie);
    /// finishing an item or marking it watched in the app clears the position.
    func resumeAt(_ it: Item) -> Double {
        let t = positions[it.id] ?? Double(it.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000
        return t > 30 ? t : 0
    }

    /// How far into an item you got (0...1) for the progress line and Resume ring: a position saved in this
    /// session (a playback just stopped) wins over the item's own UserData, which is only as new as its last load.
    func progressFraction(_ it: Item) -> Double {
        Self.progressFraction(position: positions[it.id], runtimeTicks: it.RunTimeTicks,
                              playedPercentage: it.UserData?.PlayedPercentage)
    }

    /// Where you stopped, in ticks (for “42m left”), with the same session-first rule.
    func positionTicks(_ it: Item) -> Int64 {
        if let p = positions[it.id] { return Int64(max(0, p) * 10_000_000) }
        return it.UserData?.PlaybackPositionTicks ?? 0
    }

    nonisolated static func progressFraction(position: Double?, runtimeTicks: Int64?, playedPercentage: Double?) -> Double {
        if let position {
            guard position > 0, let rt = runtimeTicks, rt > 0 else { return 0 }
            return min(1, max(0, position * 10_000_000 / Double(rt)))
        }
        return min(1, max(0, (playedPercentage ?? 0) / 100))
    }

    /// Next episode to watch for a series (in progress or first unwatched), as the server sees it.
    func nextUp(_ seriesId: String) async -> Item? {
        let r: ItemList? = try? await get("/Shows/NextUp", ["SeriesId": seriesId, "UserId": userId, "Fields": "Overview", "Limit": "1"])
        return r?.Items.first
    }

    // MARK: Playback progress (lets the server remember where you stopped)

    /// `on`: a playback's own server and token (see PlaySession); otherwise the current ones.
    private func postJSON(_ path: String, _ body: [String: Any], on s: PlaySession? = nil) async {
        guard let url = URL(string: (s?.server ?? server) + path) else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&r, token: s?.token)
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await Net.session.data(for: r)
    }

    /// One playback as the server tracks it. Emby rejects reports without a PlaySessionId (HTTP 400).
    struct PlaySession {
        let itemId: String
        let sourceId: String?
        /// DirectPlay | DirectStream | Transcode. Starts as a guess from the URL (PlayMethod.guess) and is
        /// corrected from the server's TranscodingInfo a few seconds after the start (PlayMethod.classify).
        var method: String
        /// Served through the server's HLS pipeline (anything but a static file): the server runs ffmpeg even for a
        /// pure remux (Direct Stream), so its job must be stopped whatever the label says.
        let hls: Bool
        /// The stream URL (holds the token: never logged)
        let url: URL
        /// Must be the server's PlaySessionId (from the stream URL), or the server can't
        /// match our stop report to its transcode and leaves the ffmpeg job + temp files running.
        var id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        /// The server and sign-in this playback runs on. Reports and transcode kills go there, even when the
        /// user has switched to another server since (they used to go to whichever server was current).
        let server: String
        let token: String

        init(itemId: String, sourceId: String?, method: String, url: URL, server: String, token: String) {
            self.itemId = itemId; self.sourceId = sourceId; self.method = method
            self.url = url
            self.hls = method != "DirectPlay"   // fixed at the start: only the label is corrected later
            self.server = server; self.token = token
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let v = q.first(where: { $0.name.lowercased() == "playsessionid" })?.value, !v.isEmpty { id = v }
        }
    }

    /// Kills the server-side transcode (ffmpeg) and its temp segments for this playback.
    func stopEncoding(_ s: PlaySession) async {
        guard s.hls else { return }
        await send("DELETE", "/Videos/ActiveEncodings?DeviceId=\(deviceId)&PlaySessionId=\(s.id)", on: s)
    }

    private func progressBody(_ s: PlaySession, _ sec: Double, paused: Bool = false) -> [String: Any] {
        var b: [String: Any] = ["ItemId": s.itemId, "PositionTicks": Int64(max(0, sec) * 10_000_000),
                                "IsPaused": paused, "CanSeek": true,
                                "PlaySessionId": s.id, "PlayMethod": s.method]
        if let sourceId = s.sourceId { b["MediaSourceId"] = sourceId }
        return b
    }

    func reportStart(_ s: PlaySession, _ sec: Double) async {
        await postJSON("/Sessions/Playing", progressBody(s, sec), on: s)
        if s.server == server { await Trakt.shared.scrobble("start", itemId: s.itemId, session: s.id, at: sec, emby: self) }
    }

    func reportProgress(_ s: PlaySession, _ sec: Double, paused: Bool) async {
        await postJSON("/Sessions/Playing/Progress", progressBody(s, sec, paused: paused), on: s)
        if s.server == server {
            await Trakt.shared.scrobble(paused ? "pause" : "start", itemId: s.itemId, session: s.id, at: sec, emby: self)
        }
    }

    /// Tells the server this playback is still alive (used while paused, so it keeps the transcode running).
    func ping(_ s: PlaySession) async {
        await send("POST", "/Sessions/Playing/Ping?PlaySessionId=\(s.id)", on: s)
    }

    /// Sessions stopped recently, whose transcode may still (or again) be running on the server.
    private var recentStopped: [PlaySession] = []

    /// `quick`: the app is quitting, so skip the delayed second and third kill (they would never run).
    func reportStopped(_ s: PlaySession, _ sec: Double, duration: Double, quick: Bool = false) async {
        let finished = duration > 0 && sec / duration > 0.9
        if s.server == server {                     // not after a switch: item ids belong to that server
            positions[s.itemId] = finished ? 0 : sec
            if finished { played[s.itemId] = true }
            // Detail pages, Home's Continue Watching / Next Up and series pages refresh what they show
            NotificationCenter.default.post(name: .covePlaybackStopped, object: nil,
                                            userInfo: ["id": s.itemId, "finished": finished])
        }
        recentStopped.append(s)
        if recentStopped.count > 6 { recentStopped.removeFirst() }
        await postJSON("/Sessions/Playing/Stopped", progressBody(s, sec), on: s)
        if s.server == server && !quick {
            await Trakt.shared.scrobble("stop", itemId: s.itemId, session: s.id, at: sec, duration: duration, emby: self)
        } else {
            Trakt.shared.endScrobble(session: s.id)
        }
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

    private func send(_ method: String, _ path: String, on s: PlaySession? = nil) async {
        await sendChecked(method, path, on: s)
    }
    /// As `send`, but reports whether the server accepted it (HTTP 2xx). v1.19.0: the poster badges roll back on false.
    @discardableResult
    func sendChecked(_ method: String, _ path: String, on s: PlaySession? = nil) async -> Bool {
        guard let url = URL(string: (s?.server ?? server) + path) else { return false }
        var r = URLRequest(url: url)
        r.httpMethod = method
        authorize(&r, token: s?.token)
        guard let res = try? await Net.session.data(for: r) else { return false }
        return BadgeRollback.accepted((res.1 as? HTTPURLResponse)?.statusCode)
    }
    /// `children`: episodes shown under this season or show. The server marks them itself; this updates their
    /// ticks and the unwatched count on screen right away.
    /// `name`: when given (a click, not the player finishing), a toast confirms the change.
    func setPlayed(_ id: String, _ v: Bool, children: [Item] = [], name: String? = nil) async {
        await setPlayedChecked(id, v, children: children, name: name, rollback: false)
    }
    /// setPlayed that reports the server's answer. With `rollback` (the badges), a refusal or no answer puts the
    /// ticks back as they were and shows "Couldn't update — try again".
    @discardableResult
    func setPlayedChecked(_ id: String, _ v: Bool, children: [Item] = [], name: String? = nil, rollback: Bool = true) async -> Bool {
        if let name { toast = Toast(text: "Marked \u{201C}\(name)\u{201D} as \(v ? "watched" : "unwatched")", icon: v ? "checkmark.circle.fill" : "circle") }
        let ids = [id] + children.map { $0.id }
        let before = ids.map { (played[$0], positions[$0]) }
        played[id] = v
        positions[id] = 0
        for c in children { played[c.id] = v; positions[c.id] = 0 }
        let ok = await sendChecked(v ? "POST" : "DELETE", "/Users/\(userId)/PlayedItems/\(id)")
        if !ok && rollback {
            for (i, k) in ids.enumerated() { played[k] = before[i].0; positions[k] = before[i].1 }
            toast = BadgeRollback.failureToast
            return false
        }
        if name != nil { await Trakt.shared.setWatched(itemId: id, v, emby: self) }   // a click, not the player or a sync
        return ok
    }

    /// The movie or episode with one of these Trakt ids (imdb / tmdb / tvdb) in this library, for watched sync.
    func findByProviderIds(_ ids: [String: String], episode: Bool) async -> Item? {
        for (p, v) in ids.sorted(by: { $0.key < $1.key }) {
            let r: ItemList? = try? await get("/Users/\(userId)/Items", [
                "Recursive": "true", "IncludeItemTypes": episode ? "Episode" : "Movie",
                "AnyProviderIdEquals": "\(p).\(v)", "Fields": "ProviderIds", "Limit": "5"])
            // Servers that don't know the filter answer with everything: only take an item that really has the id
            if let it = r?.Items.first(where: { Trakt.ids($0.ProviderIds)[p] == v }) { return it }
        }
        return nil
    }
    /// `children`: a season's episodes. Favorites don't carry down on the server, so each episode is sent too.
    func setFav(_ id: String, _ v: Bool, children: [Item] = [], name: String? = nil) async {
        await setFavChecked(id, v, children: children, name: name, rollback: false)
    }
    /// setFav that reports the server's answer (for the item itself). With `rollback` (the badges), a refusal or no
    /// answer puts the hearts back as they were and shows "Couldn't update — try again".
    @discardableResult
    func setFavChecked(_ id: String, _ v: Bool, children: [Item] = [], name: String? = nil, rollback: Bool = true) async -> Bool {
        if let name { toast = Toast(text: v ? "Added \u{201C}\(name)\u{201D} to Favorites" : "Removed \u{201C}\(name)\u{201D} from Favorites", icon: v ? "heart.fill" : "heart.slash") }
        let ids = [id] + children.map { $0.id }
        let before = ids.map { faved[$0] }
        faved[id] = v
        for c in children { faved[c.id] = v }
        let ok = await sendChecked(v ? "POST" : "DELETE", "/Users/\(userId)/FavoriteItems/\(id)")
        if !ok && rollback {
            for (i, k) in ids.enumerated() { faved[k] = before[i] }
            toast = BadgeRollback.failureToast
            favRevision += 1
            return false
        }
        for c in children { await send(v ? "POST" : "DELETE", "/Users/\(userId)/FavoriteItems/\(c.id)") }
        favRevision += 1
        return ok
    }
    /// Plays from Home; when playback ends, the item's page opens (see returnAfterPlay).
    /// `from`: start there (seconds) instead of the saved position (0 = from the beginning).
    func playFromHome(_ it: Item, from: Double? = nil) async {
        returnAfterPlay = it
        if let from, !it.isSeries, !it.isBox { playing = PlayRequest(item: it, start: from) } else { await play(it) }
        if playing == nil { returnAfterPlay = nil }   // nothing started
    }

    /// Opens an item's page: an episode opens its series on that episode's season, anything else its own page.
    func openPage(_ item: Item) {
        guard item.isEpisode, let sid = item.SeriesId else { openRequest = item; return }
        Task {
            if let series = await itemRecord(sid) {
                openSeason = item.ParentIndexNumber
                openRequest = series
            }
        }
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
        try? await get("/Users/\(userId)/Items/\(id)", ["Fields": "Overview,People,Genres,Studios,MediaSources,MediaStreams,Taglines,DateCreated,ExternalUrls,RemoteTrailers,Chapters,ProviderIds"])
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
        try? await get("/Users/\(userId)/Items/\(id)", ["Fields": "Overview,ProductionLocations"])
    }

    /// Any item's record by id (used to find the series behind an episode).
    func itemRecord(_ id: String) async -> Item? {
        try? await get("/Users/\(userId)/Items/\(id)", ["Fields": "Overview"])
    }

    func favorites() async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["Filters": "IsFavorite", "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,BoxSet,Episode", "SortBy": "SortName", "SortOrder": "Ascending",
            "Fields": "Overview,Genres,EndDate,Status"])
        return r?.Items ?? []
    }

    /// People (actors, directors) marked as favorite. `/Persons` takes IsFavorite on Emby and Jellyfin.
    func favoritePeople() async -> [Item] {
        let r: ItemList? = try? await get("/Persons", ["UserId": userId, "IsFavorite": "true", "SortBy": "SortName",
                                                        "SortOrder": "Ascending", "Recursive": "true"])
        if let r { favPeopleIds = Set(r.Items.map(\.Id)) }
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

    /// Without a quality chosen by the user, a converted video is limited to this. A 4K source would otherwise
    /// be converted at up to ~100 Mbit/s, more than most networks carry and far more than the picture needs.
    static let defaultConversionBitrate = 40_000_000

    /// Whether a stream URL gets the width/bitrate caps. Servers refuse to copy the video when the requested
    /// VideoBitrate is below the source's or MaxWidth below its width, so the caps go on only when converting is
    /// wanted anyway: a quality chosen by the user (1080p/720p/480p), or a conversion that is forced (burned-in
    /// subtitle, HDR tone mapping, retry after an error). With "Original"
    /// (nil/0) nothing is added and the server may copy the video.
    static func shouldCap(maxBitrate: Int?, forcedConversion: Bool) -> Bool {
        (maxBitrate ?? 0) > 0 || forcedConversion
    }

    /// Applies the caps when `shouldCap` says so: the user's bitrate, else `defaultConversionBitrate`.
    static func capIfWanted(_ url: String, maxWidth: Int?, maxBitrate: Int?, forcedConversion: Bool) -> String {
        guard shouldCap(maxBitrate: maxBitrate, forcedConversion: forcedConversion) else { return url }
        let b = (maxBitrate ?? 0) > 0 ? maxBitrate! : defaultConversionBitrate
        return capConversion(url, maxWidth: maxWidth, maxBitrate: b)
    }

    /// Limits what the server encodes when it converts the video: no wider than the screen, no more than
    /// `maxBitrate`. Only used through `capIfWanted` (the caps can stop the server from copying the video).
    static func capConversion(_ url: String, maxWidth: Int?, maxBitrate: Int) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var q = c.queryItems ?? []
        if let w = maxWidth, w > 0 {
            let cur = q.first { $0.name.lowercased() == "maxwidth" }.flatMap { Int($0.value ?? "") }
            q.removeAll { $0.name.lowercased() == "maxwidth" }
            q.append(URLQueryItem(name: "MaxWidth", value: String(min(w, cur ?? w))))
        }
        let vb = q.first { $0.name.lowercased() == "videobitrate" }.flatMap { Int($0.value ?? "") }
        q.removeAll { $0.name.lowercased() == "videobitrate" }
        q.append(URLQueryItem(name: "VideoBitrate", value: String(min(maxBitrate, vb ?? maxBitrate))))
        c.queryItems = q
        return encodePlus(c) ?? url
    }

    /// URLComponents.queryItems leaves '+' as is, which servers read as a space; a value the server sent
    /// as %2B would come back changed. Re-encode it, the same way `get()` does.
    static func encodePlus(_ c: URLComponents) -> String? {
        var c = c
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.string
    }

    /// Asks the server to re-encode the video instead of copying it. Only for the retry after a playback error;
    /// a resume keeps the copy (see ResumeStrategy).
    static func withoutVideoCopy(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        var q = (c.queryItems ?? []).filter { $0.name.lowercased() != "allowvideostreamcopy" }
        q.append(URLQueryItem(name: "AllowVideoStreamCopy", value: "false"))
        c.queryItems = q
        return encodePlus(c) ?? url
    }

    /// A burned-in subtitle needs the video re-encoded: with stream copy allowed, Emby copies an h264 source and
    /// silently drops SubtitleMethod=Encode (owner: Cast/AirPlay burn-in played with no subtitles). Emby and
    /// Jellyfin (DynamicHls) both read AllowVideoStreamCopy / EnableAutoStreamCopy on master.m3u8.
    nonisolated static func forBurnIn(_ url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        let drop: Set<String> = ["allowvideostreamcopy", "enableautostreamcopy"]
        var q = (c.queryItems ?? []).filter { !drop.contains($0.name.lowercased()) }
        q.append(URLQueryItem(name: "AllowVideoStreamCopy", value: "false"))
        q.append(URLQueryItem(name: "EnableAutoStreamCopy", value: "false"))
        if !q.contains(where: { $0.name.lowercased() == "videocodec" }) { q.append(URLQueryItem(name: "VideoCodec", value: "h264")) }
        c.queryItems = q
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.string ?? url
    }

    /// The subtitle/copy parameters of a stream URL, for the log (never the token).
    nonisolated static func burnInLog(_ url: String) -> String {
        let keep: Set<String> = ["subtitlestreamindex", "subtitlemethod", "allowvideostreamcopy", "enableautostreamcopy", "videocodec"]
        let q = URLComponents(string: url)?.queryItems ?? []
        return q.filter { keep.contains($0.name.lowercased()) }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    /// The server ignores the requested subtitle and burns in the user's default track,
    /// so force the chosen track into the transcode URL (or strip subtitles when "Off").
    /// `method`: "Encode" burns the track in; "Hls" adds it to the master playlist as WebVTT segments.
    static func fixSubtitle(_ url: String, _ sub: Int?, method: String = "Encode") -> String {
        guard var c = URLComponents(string: url) else { return url }
        var q = (c.queryItems ?? []).filter { $0.name != "SubtitleStreamIndex" && $0.name != "SubtitleMethod" }
        if let sub {
            q.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(sub)))
            q.append(URLQueryItem(name: "SubtitleMethod", value: method))
        }
        c.queryItems = q
        return encodePlus(c) ?? url
    }

    /// Downloads a subtitle track as SRT (the server converts embedded text subs too).
    /// Returns nil for image subtitles (PGS etc.) that can't be converted.
    /// `upTo`: only the cues up to this many seconds. The server reads an embedded track from the start of the
    /// file up to there and stops (about a second per minute of film), so the first minutes come back quickly; the
    /// start position it takes is ignored. Whole tracks are kept on disk, so a film opened again has them at once.
    /// The subtitle a stream URL asks for: a burned-in track (`sub`) wins, else an in-stream one (`hlsSub`).
    static func streamSubtitle(_ req: PlayRequest) -> (index: Int?, method: String) {
        if let s = req.sub { return (s, "Encode") }
        if let s = req.hlsSub { return (s, "Hls") }
        return (nil, "Encode")
    }

    /// A request whose subtitle is burned in (`sub`) gets the forced video conversion; logged without the token.
    static func burnInIfNeeded(_ url: String, _ req: PlayRequest) -> String {
        guard req.sub != nil else { return url }
        let u = forBurnIn(url)
        DebugLog.write("subs: burn-in params \(burnInLog(u))")
        return u
    }

    /// Applies `streamSubtitle` to a stream URL the server gave.
    static func subtitleURL(_ url: String, _ req: PlayRequest) -> String {
        let s = streamSubtitle(req)
        return fixSubtitle(url, s.index, method: s.method)
    }

    func subtitleCues(_ itemId: String, _ sourceId: String?, _ index: Int, upTo: Double? = nil) async -> [Cue]? {
        var sid = sourceId
        if sid == nil { sid = await full(itemId)?.MediaSources?.first?.Id }
        guard let sid else { return nil }
        if let c = cachedCues(itemId, sid, index) { return c }
        let path = upTo.map { "\(server)/Videos/\(itemId)/\(sid)/Subtitles/\(index)/0/Stream.srt?EndPositionTicks=\(Int64($0 * 10_000_000))" }
            ?? "\(server)/Videos/\(itemId)/\(sid)/Subtitles/\(index)/Stream.srt"
        guard let u = URL(string: path) else { return nil }
        // Embedded subtitles are extracted from the whole video file the first time, which can take minutes.
        var r = URLRequest(url: u)
        authorize(&r)
        r.timeoutInterval = 600
        guard let (data, resp) = try? await Net.session.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let cues = Cue.parseSRT(text)
        if cues.isEmpty { return nil }
        // Whole track (a server that ignores the end returns it all too)
        if upTo == nil || (cues.last?.end ?? 0) > (upTo ?? 0) + 120 { saveCues(itemId, sid, index, text) }
        return cues
    }

    private func cueFile(_ itemId: String, _ sourceId: String, _ index: Int) -> URL? {
        SubtitleCache.shared.file("\(server)|\(itemId)|\(sourceId)|\(index)")
    }

    /// A whole track downloaded before.
    func cachedCues(_ itemId: String, _ sourceId: String?, _ index: Int) -> [Cue]? {
        guard let sourceId, let f = cueFile(itemId, sourceId, index), let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let c = Cue.parseSRT(text)
        if !c.isEmpty { SubtitleCache.shared.touch(f) }
        return c.isEmpty ? nil : c
    }

    private func saveCues(_ itemId: String, _ sourceId: String, _ index: Int, _ text: String) {
        if let f = cueFile(itemId, sourceId, index) { try? text.write(to: f, atomically: true, encoding: .utf8) }
        Task.detached(priority: .utility) { SubtitleCache.shared.prune() }
    }

    /// The HLS profile for the server. HEVC (4K, HDR) must come in fMP4 segments: AVPlayer rejects HEVC inside
    /// MPEG-TS (CoreMedia -12927 on the first segment). With fMP4 the server can pass a 4K HDR video through
    /// unchanged, and Apple Silicon decodes it in hardware. Everything else keeps the proven TS + H.264 profile.
    /// The codec order matters: the server copies the video when its codec is listed, and when it has to convert
    /// it uses the first one (H.264, which every server can encode quickly).
    ///
    /// Audio: every codec AVPlayer plays in that container is copied unchanged (surround and Atmos kept). AC3/EAC3
    /// play in TS and fMP4; FLAC/ALAC only in fMP4. DTS and TrueHD aren't listed, so only they are converted, to
    /// the first codec listed (EAC3, up to 5.1). `safeAudio` (the retry after AVPlayer failed) goes back to the
    /// old, proven stereo AAC.
    static let fmp4AudioCodecs = "eac3,ac3,aac,flac,alac,mp3"
    static let tsAudioCodecs = "eac3,ac3,aac,mp3"
    static let maxAudioChannels = "8"

    static func transcodingProfile(hevc: Bool, safeAudio: Bool = false) -> [String: Any] {
        [
            "Container": hevc ? "mp4" : "ts", "Type": "Video",
            "AudioCodec": safeAudio ? "aac" : (hevc ? fmp4AudioCodecs : tsAudioCodecs),
            "VideoCodec": hevc ? "h264,hevc" : "h264",
            "Context": "Streaming", "Protocol": "hls", "MaxAudioChannels": safeAudio ? "2" : maxAudioChannels,
            "MinSegments": "1", "BreakOnNonKeyFrames": true,
        ]
    }

    /// Codec conditions. macOS can't decode 10-bit H.264 (Hi10P): the server converts it. AC3/EAC3 carry at most
    /// 5.1 (the ffmpeg encoders can't write more), so a converted 7.1 DTS/TrueHD track comes out as 5.1 EAC3.
    static func codecProfiles() -> [[String: Any]] {
        [["Type": "Video", "Codec": "h264", "Conditions": [
            ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": false]]],
         ["Type": "VideoAudio", "Codec": "ac3,eac3", "Conditions": [
            ["Condition": "LessThanEqual", "Property": "AudioChannels", "Value": "6", "IsRequired": false]]]]
    }

    /// Asks the server how to play the item for AVPlayer: direct play for MP4/MOV, otherwise HLS transcode
    /// (also used whenever a subtitle, a different audio track or a lower quality is chosen).
    /// `hevc`: the source video is HEVC, so ask for fMP4 segments that may carry it unchanged.
    /// `maxWidth`: the screen's width in pixels; a video the server converts is scaled down to it.
    enum PlaybackInfoStatus: Equatable { case ok, sessionEnded, serverError(Int) }

    /// How to treat the PlaybackInfo reply's HTTP status. No status (network error): carry on with the fallback.
    nonisolated static func playbackInfoStatus(_ code: Int?) -> PlaybackInfoStatus {
        guard let code, !(200..<300).contains(code) else { return .ok }
        return code == 401 ? .sessionEnded : .serverError(code)
    }

    /// Why the last resolveStream returned nil, when the server said so (shown by the player).
    var lastStreamError: String?
    /// The chosen media source's container ("mkv"…), for the Playback info overlay.
    var lastStreamContainer: String?

    /// `convert`: the server has to convert the video anyway (HDR tone mapping, retry after an error), so the
    /// width/bitrate caps apply (see `shouldCap`). `safeAudio`: stereo AAC only (retry after AVPlayer failed).
    func resolveStream(_ req: PlayRequest, direct: Bool = true, reencode: Bool = false, hevc: Bool = false,
                       maxWidth: Int? = nil, convert: Bool = false, safeAudio: Bool = false) async -> URL? {
        let id = req.item.id
        let canDirect = direct && !req.transcode
        // A burned-in subtitle (`sub`): Encode-only subtitle profiles and no direct play/stream, or Emby copies
        // the video and drops the subtitle (see BurnInPlaybackInfo.swift).
        let burning = req.sub != nil
        var profile: [String: Any] = [
            "Name": "Cove Mac",
            "MaxStreamingBitrate": req.maxBitrate ?? 120_000_000,
            "DirectPlayProfiles": canDirect
                ? [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3"]]
                : [[String: Any]](),
            "TranscodingProfiles": [Self.transcodingProfile(hevc: hevc, safeAudio: safeAudio)],
            "CodecProfiles": Self.codecProfiles(),
            // vtt/Hls: embedded text tracks can come inside the HLS stream (see PlayRequest.hlsSub)
            "SubtitleProfiles": [["Format": "vtt", "Method": "Hls"]]
                + ["srt", "subrip", "ass", "ssa", "vtt", "pgs", "pgssub", "dvdsub"].map { ["Format": $0, "Method": "Encode"] }
        ]
        var qi = [URLQueryItem(name: "UserId", value: userId),
                  URLQueryItem(name: "IsPlayback", value: "true"),
                  URLQueryItem(name: "AutoOpenLiveStream", value: "true")]
        if let v = req.sourceId { qi.append(URLQueryItem(name: "MediaSourceId", value: v)) }
        if let v = req.audio { qi.append(URLQueryItem(name: "AudioStreamIndex", value: String(v))) }
        if let s = req.sub {
            profile["DirectPlayProfiles"] = [[String: Any]]()
            profile["SubtitleProfiles"] = Self.burnInSubtitleProfiles()
            let b = Self.burnInQuery(userId: userId, sourceId: nil, sub: s, audio: nil, start: nil,
                                     maxBitrate: req.maxBitrate ?? 120_000_000)
            qi += b.filter { !["UserId", "IsPlayback", "AutoOpenLiveStream"].contains($0.name) }
        } else if let v = req.maxBitrate { qi.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(v))) }
        guard var c = URLComponents(string: "\(server)/Items/\(id)/PlaybackInfo") else { return nil }
        c.queryItems = qi
        guard let pu = c.url else { return nil }
        var r = URLRequest(url: pu)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&r)
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["DeviceProfile": profile])
        lastStreamError = nil
        lastStreamContainer = nil
        let got = try? await Net.session.data(for: r)
        switch Self.playbackInfoStatus((got?.1 as? HTTPURLResponse)?.statusCode) {
        case .ok: break
        case .sessionEnded:
            checkSession()
            lastStreamError = "Your session on the server has ended. Sign in again."
            return nil
        case .serverError(let code):
            lastStreamError = "The server couldn't prepare this video (HTTP \(code))."
            return nil
        }
        if let (data, _) = got,
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = j["MediaSources"] as? [[String: Any]],
           let src = list.first(where: { ($0["Id"] as? String) == req.sourceId }) ?? list.first {
            let sid = src["Id"] as? String ?? id
            lastStreamContainer = src["Container"] as? String
            let cont = (src["Container"] as? String ?? "").lowercased().split(separator: ",").map(String.init)
            if canDirect, src["SupportsDirectPlay"] as? Bool == true,
               cont.contains(where: { ["mp4", "m4v", "mov"].contains($0) }) {
                return URL(string: "\(server)/Videos/\(id)/stream.mp4?Static=true&MediaSourceId=\(sid)&\(keyName)=\(token)")
            }
            if let t = src["TranscodingUrl"] as? String {
                if burning { DebugLog.write(Self.burnInInfoLog(t)) }
                // Caps only when converting is wanted (a lower quality, burn-in, forced conversion), never
                // with "Original": they would stop the server from copying the video. No width cap when a 4K HEVC
                // video may pass through unchanged.
                let forced = convert || reencode || req.sub != nil || req.burnIn
                let capped = Self.capIfWanted(Self.subtitleURL(t, req), maxWidth: hevc ? nil : maxWidth,
                                              maxBitrate: req.maxBitrate, forcedConversion: forced)
                return absolute(Self.burnInIfNeeded(capped, req), noCopy: reencode)
            }
            if let t = src["DirectStreamUrl"] as? String {
                let withSub = req.hlsSub != nil || req.sub != nil ? Self.subtitleURL(t, req) : t
                return absolute(Self.burnInIfNeeded(withSub, req), noCopy: reencode)
            }
        }
        let fallback0 = "\(server)/Videos/\(id)/master.m3u8?MediaSourceId=\(req.sourceId ?? id)&DeviceId=\(deviceId)&PlaySessionId=\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))&VideoCodec=h264&AudioCodec=aac&\(keyName)=\(token)"
        let fallback = Self.burnInIfNeeded(req.hlsSub != nil || req.sub != nil ? Self.subtitleURL(fallback0, req) : fallback0, req)
        return URL(string: reencode ? Self.withoutVideoCopy(fallback) : fallback)
    }
}


/// Subtitle formats the server can only burn into the video (pictures, not text).
let imageSubCodecs: Set<String> = ["pgs", "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "xsub"]

/// Preferred-language subtitle track: text formats first, then any.
func preferredSub(_ streams: [MStream], lang: String) -> Int? {
    let subs = streams.filter { $0.`Type` == "Subtitle" && subLangName($0).lowercased() == lang.lowercased() }
    return bestTextSub(subs)?.Index
}

/// Among subtitle tracks of one language: an external text file first (an .srt next to the film: loads at once
/// and is drawn in sync), then an embedded text track (SUBRIP inside the MKV), then any (picture subs) (owner).
func bestTextSub(_ subs: [MStream]) -> MStream? {
    let text = subs.filter { !imageSubCodecs.contains(($0.Codec ?? "").lowercased()) }
    return text.first { $0.IsExternal == true } ?? text.first ?? subs.first
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
