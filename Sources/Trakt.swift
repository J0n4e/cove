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
    private let api = URL(string: "https://api.trakt.tv")!
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
            let body: [String: Any] = [p.kind == "episode" ? "episodes" : "movies": [entry]]
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
            for kind in ["movie", "episode"] {
                let data = try await send("/sync/ratings/\(kind)s")
                let list = try JSONDecoder().decode([RatedEntry].self, from: data)
                for e in list {
                    guard let ids = (kind == "movie" ? e.movie : e.episode)?.ids.strings else { continue }
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

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: api.appendingPathComponent(path))
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
