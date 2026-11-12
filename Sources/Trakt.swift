import AppKit
import Foundation

/// Your own ratings (1–10), kept on Trakt (trakt.tv). Sign-in uses Trakt's device code: Cove shows a short code,
/// you enter it on trakt.tv/activate, and no password passes through Cove. Ratings are matched by the IMDb,
/// TMDB or TVDB ids the media server has for the movie or episode.
///
/// Each user registers their own Trakt app (a public one, no secret) and enters its Client ID in Settings →
/// Connect. The Client ID and the sign-in tokens are kept encrypted in the preferences file (SealedPrefs).
@MainActor
final class Trakt: ObservableObject {
    static let shared = Trakt()

    /// Signed-in Trakt user name; nil when not connected.
    @Published private(set) var user: String?
    /// Your ratings by item key ("movie:imdb:tt0133093", "episode:tvdb:349232", …).
    @Published private(set) var ratings: [String: Int] = [:]
    /// Ratings waiting to reach Trakt (offline, Trakt down); they're sent again on the next change or refresh.
    @Published private(set) var pending: [Pending] = []
    /// Device sign-in in progress: the code to enter and where.
    @Published private(set) var signIn: SignIn?
    @Published private(set) var lastError: String?

    struct SignIn: Equatable { let userCode: String; let url: String }

    struct Pending: Codable, Equatable {
        let kind: String            // "movie" or "episode"
        let ids: [String: String]   // "imdb": "tt…", "tmdb": "603", "tvdb": "…"
        let rating: Int             // 0 = remove the rating
    }

    private let d = UserDefaults.standard
    private var lastFetch: Date?
    private var signInTask: Task<Void, Never>?

    /// The Client ID of the user's Trakt app, from Settings → Connect.
    @Published private(set) var clientId: String
    var isConfigured: Bool { !clientId.isEmpty }
    var isConnected: Bool { user != nil && accessToken != nil }

    /// A new Client ID belongs to another Trakt app, so the old sign-in goes.
    func setClientId(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != clientId else { return }
        if isConnected || accessToken != nil { disconnect() }
        clientId = id
        SealedPrefs.set(id, for: "traktClientId")
    }

    private func withClient(_ body: [String: String]) -> [String: String] {
        var b = body
        b["client_id"] = clientId
        return b
    }

    private var accessToken: String? {
        get { SealedPrefs.get("traktAccess") }
        set { SealedPrefs.set(newValue, for: "traktAccess") }
    }
    private var refreshToken: String? {
        get { SealedPrefs.get("traktRefresh") }
        set { SealedPrefs.set(newValue, for: "traktRefresh") }
    }
    private var expiresAt: Date? {
        get { d.object(forKey: "traktExpires") as? Date }
        set { d.set(newValue, forKey: "traktExpires") }
    }

    private init() {
        clientId = SealedPrefs.get("traktClientId") ?? ""
        user = d.string(forKey: "traktUser")
        if let data = d.data(forKey: "traktRatings"), let r = try? JSONDecoder().decode([String: Int].self, from: data) { ratings = r }
        if let data = d.data(forKey: "traktPending"), let p = try? JSONDecoder().decode([Pending].self, from: data) { pending = p }
    }

    // MARK: - Item ids

    /// The ids Trakt can match, from the server's provider ids (keys differ in case between servers).
    static func ids(_ providerIds: [String: String]?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in providerIds ?? [:] {
            let v = v.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            switch k.lowercased() {
            case "imdb" where v.hasPrefix("tt"): out["imdb"] = v
            case "tmdb" where Int(v) != nil: out["tmdb"] = v
            case "tvdb" where Int(v) != nil: out["tvdb"] = v
            default: break
            }
        }
        return out
    }

    /// Lookup keys for an item, most reliable first.
    static func keys(kind: String, ids: [String: String]) -> [String] {
        ["imdb", "tmdb", "tvdb"].compactMap { p in ids[p].map { "\(kind):\(p):\($0)" } }
    }

    /// "movie", "show" or "episode"; nil for things Trakt doesn't rate here (collections, seasons, people).
    static func kind(_ item: Item) -> String? {
        switch item.`Type` {
        case "Movie": return "movie"
        case "Series": return "show"
        case "Episode": return "episode"
        default: return nil
        }
    }

    /// Your rating for a poster (nil when not connected or not rated).
    func rating(_ item: Item) -> Int? {
        guard user != nil, let k = Self.kind(item) else { return nil }
        let ids = Self.ids(item.ProviderIds)
        return ids.isEmpty ? nil : rating(kind: k, ids: ids)
    }

    func rating(kind: String, ids: [String: String]) -> Int? {
        Self.keys(kind: kind, ids: ids).lazy.compactMap { self.ratings[$0] }.first
    }

    func isPending(kind: String, ids: [String: String]) -> Bool {
        pending.contains { $0.kind == kind && $0.ids == ids }
    }

    // MARK: - Rating

    /// Saves the rating here at once, then sends it to Trakt; 0 removes it.
    func rate(kind: String, ids: [String: String], _ value: Int) async {
        guard !ids.isEmpty, (0...10).contains(value) else { return }
        for k in Self.keys(kind: kind, ids: ids) { ratings[k] = value == 0 ? nil : value }
        saveRatings()
        pending.removeAll { $0.kind == kind && $0.ids == ids }
        pending.append(Pending(kind: kind, ids: ids, rating: value))
        savePending()
        await flush()
    }

    /// Sends the waiting ratings to Trakt; whatever fails stays in the queue.
    func flush() async {
        guard isConnected, !pending.isEmpty else { return }
        for p in pending {
            let entry: [String: Any] = p.rating == 0 ? ["ids": p.ids] : ["ids": p.ids, "rating": p.rating]
            let body: [String: Any] = [p.kind + "s": [entry]]
            do {
                _ = try await send(p.rating == 0 ? "/sync/ratings/remove" : "/sync/ratings", method: "POST", json: body)
                pending.removeAll { $0 == p }
                lastError = nil
            } catch {
                lastError = describe(error)
                break        // offline or Trakt down: try the rest later
            }
        }
        savePending()
    }

    /// Fetches your ratings from Trakt (also the ones made elsewhere); at most every five minutes unless forced.
    func refresh(force: Bool = false) async {
        guard isConnected else { return }
        if !force, let l = lastFetch, Date().timeIntervalSince(l) < 300 { return }
        lastFetch = Date()
        await flush()
        do {
            var fresh: [String: Int] = [:]
            for kind in ["movie", "show", "episode"] {
                let data = try await send("/sync/ratings/\(kind)s")
                let list = try JSONDecoder().decode([RatedEntry].self, from: data)
                for e in list {
                    guard let ids = (kind == "movie" ? e.movie : kind == "show" ? e.show : e.episode)?.ids.strings else { continue }
                    for k in Self.keys(kind: kind, ids: ids) { fresh[k] = e.rating }
                }
            }
            // Ratings still waiting to be sent win over what Trakt has
            for p in pending { for k in Self.keys(kind: p.kind, ids: p.ids) { fresh[k] = p.rating == 0 ? nil : p.rating } }
            ratings = fresh
            saveRatings()
            lastError = nil
        } catch {
            lastFetch = nil
            lastError = describe(error)
        }
    }

    private struct RatedEntry: Decodable {
        let rating: Int
        let movie: Media?
        let show: Media?
        let episode: Media?
        struct Media: Decodable { let ids: Ids }
        struct Ids: Decodable {
            let imdb: String?; let tmdb: Int?; let tvdb: Int?
            var strings: [String: String] {
                var o: [String: String] = [:]
                if let imdb { o["imdb"] = imdb }
                if let tmdb { o["tmdb"] = String(tmdb) }
                if let tvdb { o["tvdb"] = String(tvdb) }
                return o
            }
        }
    }

    // MARK: - Scrobbling and watched status (Settings → Connect switches, both off by default because the
    // server's Trakt plugin may already do the same, which would log every play twice)

    var scrobbleOn: Bool { isConnected && d.bool(forKey: "traktScrobble") }
    var watchedSyncOn: Bool { isConnected && d.bool(forKey: "traktSyncWatched") }

    /// What Trakt needs to know about a server item: movie or episode, its ids and its length.
    struct Media { let kind: String; let ids: [String: String]; let runtime: Double }
    private var mediaCache: [String: Media] = [:]
    /// Last pause state sent per playback, so the 10-second progress reports don't all go to Trakt.
    private var scrobblePaused: [String: Bool] = [:]

    private func media(_ itemId: String, _ emby: Emby) async -> Media? {
        if let m = mediaCache[itemId] { return m }
        guard let f = await emby.full(itemId) else { return nil }
        let kind = f.`Type` == "Episode" ? "episode" : f.`Type` == "Movie" ? "movie" : ""
        let ids = Self.ids(f.ProviderIds)
        guard !kind.isEmpty, !ids.isEmpty else { return nil }
        let m = Media(kind: kind, ids: ids, runtime: Double(f.RunTimeTicks ?? 0) / 10_000_000)
        mediaCache[itemId] = m
        return m
    }

    /// action: "start", "pause" or "stop". Trakt logs the play itself when a stop comes past 80%.
    func scrobble(_ action: String, itemId: String, session: String, at sec: Double, duration: Double = 0, emby: Emby) async {
        guard scrobbleOn, let m = await media(itemId, emby) else { return }
        if action == "stop" { scrobblePaused[session] = nil }
        else {
            let paused = action == "pause"
            if scrobblePaused[session] == paused { return }
            scrobblePaused[session] = paused
        }
        let length = duration > 0 ? duration : m.runtime
        guard length > 0 else { return }
        let progress = min(100, max(0, sec / length * 100))
        let body: [String: Any] = [m.kind: ["ids": m.ids], "progress": (progress * 100).rounded() / 100]
        _ = try? await send("/scrobble/\(action)", method: "POST", json: body)
    }

    /// A Watched click in Cove adds a play on Trakt (movies, episodes, whole shows and seasons). Unwatched
    /// leaves Trakt alone: it only resets the progress here (e.g. to watch a show again), and Trakt keeps
    /// every play, so rewatches add up there.
    func setWatched(itemId: String, _ watched: Bool, emby: Emby) async {
        guard watched, watchedSyncOn, let f = await emby.full(itemId) else { return }
        var body: [String: Any] = [:]
        switch f.`Type` {
        case "Movie", "Episode":
            let ids = Self.ids(f.ProviderIds)
            guard !ids.isEmpty else { return }
            body = [f.`Type` == "Movie" ? "movies" : "episodes": [["ids": ids]]]
        case "Series":
            let ids = Self.ids(f.ProviderIds)
            guard !ids.isEmpty else { return }
            body = ["shows": [["ids": ids]]]
        case "Season":
            guard let sid = f.SeriesId, let n = f.IndexNumber, let show = await emby.full(sid) else { return }
            let ids = Self.ids(show.ProviderIds)
            guard !ids.isEmpty else { return }
            body = ["shows": [["ids": ids, "seasons": [["number": n]]]]]
        default: return
        }
        do { _ = try await send("/sync/history", method: "POST", json: body) }
        catch { lastError = describe(error) }
    }

    @Published private(set) var lastWatchedSync: Date? = UserDefaults.standard.object(forKey: "traktWatchedSyncAt") as? Date
    private var importing = false

    /// Plays Trakt got from elsewhere since the last sync are marked watched on the server. The first sync
    /// only sets the starting point (the history before it is left alone).
    func importWatched(_ emby: Emby) async {
        guard watchedSyncOn, emby.loggedIn, !importing else { return }
        importing = true
        defer { importing = false }
        let now = Date()
        guard let since = lastWatchedSync else { markSynced(now); return }
        let iso = ISO8601DateFormatter()
        do {
            var found = 0
            for type in ["movies", "episodes"] {
                var page = 1
                while true {
                    let data = try await send("/sync/history/\(type)?start_at=\(iso.string(from: since))&limit=100&page=\(page)")
                    let list = try JSONDecoder().decode([HistoryEntry].self, from: data)
                    for e in list {
                        guard let ids = (e.movie ?? e.episode)?.ids.strings,
                              let item = await emby.findByProviderIds(ids, episode: type == "episodes"),
                              !emby.isPlayed(item) else { continue }
                        await emby.setPlayed(item.id, true)
                        found += 1
                    }
                    if list.count < 100 { break }
                    page += 1
                }
            }
            markSynced(now)
            lastError = nil
            if found > 0 { emby.toast = Emby.Toast(text: "Marked \(found) watched from Trakt", icon: "checkmark.circle.fill") }
        } catch {
            lastError = describe(error)
        }
    }

    private func markSynced(_ t: Date) { lastWatchedSync = t; d.set(t, forKey: "traktWatchedSyncAt") }

    private struct HistoryEntry: Decodable {
        let movie: RatedEntry.Media?
        let episode: RatedEntry.Media?
    }

    // MARK: - Stats (Settings → Trakt)

    /// What Settings → Trakt shows; kept between launches so the tab opens with the last numbers at once.
    struct Stats: Codable, Equatable {
        struct Totals: Codable, Equatable { var plays = 0; var watched = 0; var minutes = 0 }
        struct Month: Codable, Equatable { var key: String; var movies = 0; var episodes = 0; var minutes = 0 }
        struct Recent: Codable, Equatable { var title: String; var subtitle: String; var date: Date; var isMovie: Bool }
        var movies = Totals()
        var shows = 0
        var episodes = Totals()
        var ratingsTotal = 0
        var distribution: [Int] = Array(repeating: 0, count: 10)   // ratings 1…10
        var months: [Month] = []          // oldest first, the last 12 (this month last)
        var topShowThisMonth: String?
        var topShowEpisodes = 0
        var recent: [Recent] = []
        var updated = Date()
    }

    @Published private(set) var stats: Stats? = {
        guard let d = UserDefaults.standard.data(forKey: "traktStats") else { return nil }
        return try? JSONDecoder().decode(Stats.self, from: d)
    }()
    @Published private(set) var loadingStats = false

    /// Month key ("2026-11") for a date, in the user's calendar.
    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// All-time totals from what you've watched and rated, the last 12 months from the watch history (with runtimes).
    func loadStats() async {
        guard isConnected, !loadingStats else { return }
        loadingStats = true
        defer { loadingStats = false }
        do {
            var st = Stats()
            // Trakt's /users/…/stats answers "204 No Content" (no longer served), so the totals are counted here
            struct WatchedMovie: Decodable { struct M: Decodable { let runtime: Int? }; let plays: Int; let movie: M }
            var movies: [WatchedMovie] = []
            for page in 1...100 {   // 100 a page
                let list = try JSONDecoder().decode([WatchedMovie].self,
                                                    from: try await send("/sync/watched/movies?extended=full&limit=100&page=\(page)"))
                movies += list
                if list.count < 100 { break }
            }
            st.movies = .init(plays: movies.reduce(0) { $0 + $1.plays }, watched: movies.count,
                              minutes: movies.reduce(0) { $0 + $1.plays * ($1.movie.runtime ?? 0) })
            // Per show: the episode plays and the show's episode length (Trakt no longer lists the seasons here)
            struct WatchedShow: Decodable { struct S: Decodable { let runtime: Int? }; let plays: Int; let show: S }
            let shows = try JSONDecoder().decode([WatchedShow].self, from: try await send("/sync/watched/shows?extended=full"))
            st.shows = shows.count
            for sh in shows {
                st.episodes.plays += sh.plays
                st.episodes.minutes += sh.plays * (sh.show.runtime ?? 0)
            }
            struct Rated: Decodable { let rating: Int }
            let rated = try JSONDecoder().decode([Rated].self, from: try await send("/sync/ratings"))
            st.ratingsTotal = rated.count
            for r in rated where (1...10).contains(r.rating) { st.distribution[r.rating - 1] += 1 }

            // The last 12 months, this one included
            let cal = Calendar.current
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
            let start = cal.date(byAdding: .month, value: -11, to: thisMonth)!
            var byMonth: [String: Stats.Month] = [:]
            for i in 0..<12 {
                let k = Self.monthKey(cal.date(byAdding: .month, value: i, to: start)!)
                byMonth[k] = .init(key: k)
            }
            struct Entry: Decodable {
                struct Media: Decodable { let title: String?; let runtime: Int?; let season: Int?; let number: Int? }
                let watched_at: Date; let type: String
                let movie: Media?; let episode: Media?; let show: Media?
            }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .custom { d in
                let s = try d.singleValueContainer().decode(String.self)
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date.distantPast
            }
            let iso = ISO8601DateFormatter().string(from: start)
            var showsThisMonth: [String: Int] = [:]
            let curKey = Self.monthKey(Date())
            var page = 1
            while page <= 60 {   // 6,000 plays a year at most; enough for anyone
                let data = try await send("/sync/history?start_at=\(iso)&extended=full&limit=100&page=\(page)")
                let list = try dec.decode([Entry].self, from: data)
                for e in list {
                    let k = Self.monthKey(e.watched_at)
                    let isMovie = e.type == "movie"
                    if st.recent.count < 8 {
                        let title = isMovie ? (e.movie?.title ?? "") : (e.show?.title ?? "")
                        let sub = isMovie ? "Movie" : String(format: "S%02dE%02d", e.episode?.season ?? 0, e.episode?.number ?? 0)
                            + ((e.episode?.title).map { " · " + $0 } ?? "")
                        st.recent.append(.init(title: title, subtitle: sub, date: e.watched_at, isMovie: isMovie))
                    }
                    guard var m = byMonth[k] else { continue }
                    if isMovie { m.movies += 1; m.minutes += e.movie?.runtime ?? 0 }
                    else {
                        m.episodes += 1; m.minutes += e.episode?.runtime ?? 0
                        if k == curKey, let t = e.show?.title { showsThisMonth[t, default: 0] += 1 }
                    }
                    byMonth[k] = m
                }
                if list.count < 100 { break }
                page += 1
            }
            st.months = byMonth.values.sorted { $0.key < $1.key }
            if let top = showsThisMonth.max(by: { $0.value < $1.value }) { st.topShowThisMonth = top.key; st.topShowEpisodes = top.value }
            st.updated = Date()
            stats = st
            d.set(try? JSONEncoder().encode(st), forKey: "traktStats")
            lastError = nil
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: - Sign-in (device code)

    func connect() {
        guard isConfigured, signInTask == nil else { return }
        lastError = nil
        signInTask = Task {
            defer { signInTask = nil; signIn = nil }
            do {
                let data = try await post("/oauth/device/code", ["client_id": clientId])
                let code = try JSONDecoder().decode(DeviceCode.self, from: data)
                signIn = SignIn(userCode: code.user_code, url: code.verification_url)
                if let u = SafeLink.url(code.verification_url) { NSWorkspace.shared.open(u) }
                var wait = UInt64(max(code.interval, 1))
                let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                    let (body, status) = try await postRaw("/oauth/device/token",
                        withClient(["code": code.device_code]))
                    switch status {
                    case 200:
                        try store(try JSONDecoder().decode(TokenAnswer.self, from: body))
                        await loadUser()
                        await refresh(force: true)
                        return
                    case 400: continue                          // not entered yet
                    case 429: wait += 1                         // polling too fast
                    case 418: lastError = "The code was denied on Trakt."; return
                    case 404, 409, 410: lastError = "The code expired or was already used. Try again."; return
                    default: lastError = "Trakt answered with error \(status)."; return
                    }
                }
                lastError = "The code expired. Try again."
            } catch is CancellationError {
            } catch {
                lastError = describe(error)
            }
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    func disconnect() {
        if let t = accessToken {
            let body = withClient(["token": t])
            Task { _ = try? await postRaw("/oauth/revoke", body) }
        }
        accessToken = nil; refreshToken = nil; expiresAt = nil
        user = nil; d.removeObject(forKey: "traktUser")
        ratings = [:]; saveRatings()
        pending = []; savePending()
        lastFetch = nil; lastError = nil
        lastWatchedSync = nil; d.removeObject(forKey: "traktWatchedSyncAt")
        stats = nil; d.removeObject(forKey: "traktStats")
    }

    private struct DeviceCode: Decodable {
        let device_code: String; let user_code: String; let verification_url: String
        let expires_in: Int; let interval: Int
    }
    private struct TokenAnswer: Decodable {
        let access_token: String; let refresh_token: String; let expires_in: Int; let created_at: Int?
    }

    private func store(_ t: TokenAnswer) throws {
        accessToken = t.access_token
        refreshToken = t.refresh_token
        let created = t.created_at.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        expiresAt = created.addingTimeInterval(TimeInterval(t.expires_in))
    }

    private func loadUser() async {
        struct Settings: Decodable { struct U: Decodable { let username: String }; let user: U }
        guard let data = try? await send("/users/settings"),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { user = "Trakt"; return }
        user = s.user.username
        d.set(user, forKey: "traktUser")
    }

    /// A fresh access token a day before the old one runs out.
    private func renewIfNeeded() async throws {
        guard let exp = expiresAt, exp.timeIntervalSinceNow < 86_400, let r = refreshToken else { return }
        let (body, status) = try await postRaw("/oauth/token", withClient([
            "refresh_token": r, "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]))
        guard status == 200 else {
            if status == 401 || status == 400 { signedOutByTrakt() }
            throw TraktError.status(status)
        }
        try store(try JSONDecoder().decode(TokenAnswer.self, from: body))
    }

    /// Trakt no longer accepts the sign-in (revoked on the website): forget it, keep the local ratings.
    private func signedOutByTrakt() {
        accessToken = nil; refreshToken = nil; expiresAt = nil
        user = nil; d.removeObject(forKey: "traktUser")
        lastError = "Trakt signed Cove out. Connect again on the Connect page."
    }

    // MARK: - HTTP

    enum TraktError: Error { case status(Int) }

    private func describe(_ e: Error) -> String {
        if case TraktError.status(let s) = e { return s == 401 ? "Trakt didn't accept the sign-in." : "Trakt answered with error \(s)." }
        if let u = e as? URLError, u.code == .notConnectedToInternet { return "No internet connection." }
        return "Couldn't reach Trakt."
    }

    /// The API address for a path that may carry a query ("/sync/history?start_at=…"). appendingPathComponent
    /// would escape the "?", so every request with parameters went to a path that doesn't exist.
    static func url(_ path: String) -> URL { URL(string: "https://api.trakt.tv" + path)! }

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: Self.url(path))
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("2", forHTTPHeaderField: "trakt-api-version")
        r.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        r.setValue("Cove", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// A signed-in call; returns the body of a 2xx answer.
    private func send(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        try await renewIfNeeded()
        guard let token = accessToken else { throw TraktError.status(401) }
        var r = request(path, method: method)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { signedOutByTrakt() }
        guard (200..<300).contains(status) else { throw TraktError.status(status) }
        return data
    }

    private func postRaw(_ path: String, _ body: [String: String]) async throws -> (Data, Int) {
        var r = request(path, method: "POST")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        let (data, status) = try await postRaw(path, body)
        guard (200..<300).contains(status) else { throw TraktError.status(status) }
        return data
    }

    private func saveRatings() { d.set(try? JSONEncoder().encode(ratings), forKey: "traktRatings") }
    private func savePending() { d.set(try? JSONEncoder().encode(pending), forKey: "traktPending") }
}
