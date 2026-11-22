import Foundation

// Nexview requests in Activity → Cleanup (only there, not on detail pages): who requested a title, when it was
// approved and ready, and whether the requester ever watched it.
//
// Source of truth: Nexview's backend (github.com/DerKezorm/nexview):
//  - GET /api/admin/requests (routers/admin_requests.py `list_all`): every request of every user, newest first,
//    no paging (the whole list in one answer). Needs an admin or approver account (`require_approver`); a
//    read-only API key works because the call is a GET.
//  - Response list[RequestWithUser] (schemas_requests.py); media_type "movie" | "tv"; datetimes are written by
//    SQLAlchemy `DateTime` without a time zone (UTC, `utcnow`), so pydantic sends "2026-11-12T21:14:00.123456"
//    with no zone; a zone or "Z" is honoured when present.
//  - Auth (deps.py): `Authorization: Bearer nxv_…` (API keys start with "nxv_"), made in Nexview under
//    Profile → Account → Security → API tokens.
//  - GET /api/v1/me (routers/v1.py `Selbstauskunft`): {version, konto{id, username, name, role, betreiber}, schluessel, darf}.
// Pure rules here, tested in Tests/NexviewRequestsTests.swift; connection in Admin/NexviewService.swift.

struct NexviewRequest: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let mediaType: String
    let tmdbId: Int
    let title: String
    let status: String
    let season: Int?
    let episodes: [Int]?
    let requestedAt: Date?
    let approvedAt: Date?
    let completedAt: Date?
    let approvedByName: String?
    let rating: Int?
    let feedback: String?
    let userId: Int
    let username: String
    let displayName: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, season, episodes, rating, feedback, username
        case mediaType = "media_type", tmdbId = "tmdb_id", requestedAt = "requested_at", approvedAt = "approved_at"
        case completedAt = "completed_at", approvedByName = "approved_by_name", userId = "user_id"
        case displayName = "display_name", avatarUrl = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        tmdbId = try c.decode(Int.self, forKey: .tmdbId)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        season = try? c.decodeIfPresent(Int.self, forKey: .season)
        episodes = try? c.decodeIfPresent([Int].self, forKey: .episodes)
        func date(_ k: CodingKeys) -> Date? { (try? c.decodeIfPresent(String.self, forKey: k)).flatMap(Nexview.date) }
        requestedAt = date(.requestedAt)
        approvedAt = date(.approvedAt)
        completedAt = date(.completedAt)
        approvedByName = try? c.decodeIfPresent(String.self, forKey: .approvedByName)
        rating = try? c.decodeIfPresent(Int.self, forKey: .rating)
        feedback = try? c.decodeIfPresent(String.self, forKey: .feedback)
        userId = (try? c.decodeIfPresent(Int.self, forKey: .userId)) ?? 0
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
    }

    /// display_name, else username
    var requesterName: String {
        if let d = displayName?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        return username
    }
}

enum Nexview {
    /// Nexview's datetimes: ISO 8601, fractions optional, zone optional (none = UTC).
    nonisolated static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 19 else { return nil }
        let timePart = s.dropFirst(10)
        let hasZone = s.hasSuffix("Z") || s.hasSuffix("z")
            || timePart.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        return WatchActivity.isoDate(hasZone ? s : s + "Z")
    }

    /// The admin request list (all of it: the endpoint has no paging).
    nonisolated static let requestsPath = "/api/admin/requests"
    nonisolated static let mePath = "/api/v1/me"

    nonisolated static func decodeRequests(_ d: Data) -> [NexviewRequest]? {
        // one bad row must not hide the rest: decode row by row
        guard let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
        return rows.compactMap { o in
            (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(NexviewRequest.self, from: $0) }
        }
    }

    struct Me: Equatable { let name: String; let role: String; let readOnly: Bool }
    nonisolated static func decodeMe(_ d: Data) -> Me? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let konto = o["konto"] as? [String: Any] else { return nil }
        let name = (konto["name"] as? String) ?? (konto["username"] as? String) ?? ""
        let key = o["schluessel"] as? [String: Any]
        return Me(name: name, role: konto["role"] as? String ?? "", readOnly: key?["nur_lesen"] as? Bool ?? false)
    }

    /// FastAPI's {"detail": …} (a string, or {"code", "message"} from `meldungen.meldung`)
    nonisolated static func errorDetail(_ d: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let s = o["detail"] as? String { return s }
        if let m = o["detail"] as? [String: Any] { return (m["code"] as? String) ?? (m["message"] as? String) }
        return nil
    }

    nonisolated static func message(status: Int, detail: String?) -> String {
        switch status {
        case 0: return "Couldn't reach Nexview. Check the address."
        case 401: return "Nexview didn't accept the token. Make a new one in Nexview: Profile \u{2192} Account \u{2192} Security \u{2192} API tokens."
        case 403: return "This token's account can't see all requests: it must belong to a Nexview admin or approver."
        case 404: return "No Nexview at this address (404)."
        default: return "Nexview answered HTTP \(status)" + (detail.map { " (\($0))" } ?? "") + "."
        }
    }

    // MARK: Text

    nonisolated static func format(_ d: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = timeZone; f.dateFormat = pattern
        return f.string(from: d)
    }

    /// "Ann" / "Ann +2" / "" (no request)
    nonisolated static func columnText(_ i: CleanupItem) -> String {
        guard let first = i.requests.first else { return "" }
        return first.requesterName + (i.requests.count > 1 ? " +\(i.requests.count - 1)" : "")
    }

    /// "Requested 12 Nov 2026, 21:14 · approved by X 12 Nov · ready 12 Nov 21:40 · rated 8 “Great”"
    nonisolated static func line(_ r: NexviewRequest, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        parts.append("Requested" + (r.requestedAt.map { " " + format($0, "d MMM yyyy, HH:mm", timeZone: timeZone) } ?? ""))
        if r.approvedAt != nil || r.approvedByName != nil {
            parts.append("approved" + (r.approvedByName.map { " by \($0)" } ?? "")
                         + (r.approvedAt.map { " " + format($0, "d MMM", timeZone: timeZone) } ?? ""))
        }
        if let c = r.completedAt { parts.append("ready " + format(c, "d MMM HH:mm", timeZone: timeZone)) }
        if let s = r.season { parts.append("season \(s)" + ((r.episodes ?? []).isEmpty ? "" : ", episodes " + r.episodes!.map(String.init).joined(separator: ", "))) }
        if let rating = r.rating { parts.append("rated \(rating)") }
        if let f = r.feedback?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { parts.append("\u{201C}\(f)\u{201D}") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// One line per request, with the requester's name and whether they watched it.
    nonisolated static func tooltip(_ i: CleanupItem, timeZone: TimeZone = .current) -> String {
        i.requests.map { r in
            let w: String
            switch NexviewMatch.watched(r, in: i) {
            case .some(true): w = "watched it"
            case .some(false): w = "hasn't watched it"
            case .none: w = "no server user with this name, counted as not watched"
            }
            return "\(r.requesterName): " + line(r, timeZone: timeZone) + " (\(w))"
        }.joined(separator: "\n")
    }
}

/// Nexview requests ↔ server items (TMDB id + type) and Nexview users ↔ server users (name).
enum NexviewMatch {
    nonisolated static func key(_ mediaType: String, _ tmdbId: Int) -> String { mediaType.lowercased() + "|\(tmdbId)" }

    /// Puts every request on its title (movie ↔ Movie, tv ↔ Series), oldest first; several per title are kept.
    nonisolated static func attach(_ requests: [NexviewRequest], to items: inout [String: CleanupItem]) {
        var byKey: [String: [NexviewRequest]] = [:]
        for r in requests { byKey[key(r.mediaType, r.tmdbId), default: []].append(r) }
        for (id, i) in items {
            guard let t = i.tmdbId, let rs = byKey[key(i.nexviewMediaType, t)] else {
                if !items[id]!.requests.isEmpty { items[id]!.requests = [] }
                continue
            }
            items[id]!.requests = rs.sorted { ($0.requestedAt ?? .distantFuture, $0.id) < ($1.requestedAt ?? .distantFuture, $1.id) }
        }
    }

    nonisolated static func attach(_ requests: [NexviewRequest], to items: [CleanupItem]) -> [CleanupItem] {
        var map = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        attach(requests, to: &map)
        return items.map { map[$0.id] ?? $0 }
    }

    /// The server user with the requester's username or display name (case-insensitive), if any.
    nonisolated static func entry(_ r: NexviewRequest, in i: CleanupItem) -> WatchActivityEntry? {
        let names = Set([r.username, r.displayName ?? ""].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        return i.entries.first { names.contains($0.user.name.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    /// true = watched (all or some of it), false = not, nil = no matching server user (counts as not watched).
    nonisolated static func watched(_ r: NexviewRequest, in i: CleanupItem) -> Bool? {
        guard let e = entry(r, in: i) else { return nil }
        if e.playCount > 0 || e.lastPlayed != nil { return true }
        switch WatchActivity.state(e, folder: i.isSeries) {
        case .watched, .progress: return true
        case .notStarted: return false
        }
    }

    nonisolated static func anyRequesterWatched(_ i: CleanupItem) -> Bool { i.requests.contains { watched($0, in: i) == true } }
}
