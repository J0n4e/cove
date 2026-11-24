import Foundation

// Delete… (admins only): a movie, series, season or episode, through nexcrate when nexcrate has it (its downloads
// stop, the finished torrents leave qBittorrent, the files go to nexcrate's recycle bin for 7 days: Undo), else
// permanently through the media server (DELETE /Items/{id}). Pure shapes and decoding, tested in
// Tests/DeleteEverywhereTests.swift. The nexcrate contract is /api/v1 (routers/v1*.py of nexcrate).

enum NexcrateAPI {
    struct Request: Equatable {
        let method: String
        /// Path below `<address>/api/v1`, with query.
        let path: String
        var body: Data? = nil
        var contentType: String? { body == nil ? nil : "application/json" }
    }

    nonisolated static func p(_ s: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~:")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }

    /// "nas:8390", "http://nas:8390/", "https://x/nexcrate/api/v1" → "http://nas:8390", "https://x/nexcrate".
    /// nil when it isn't a web address.
    nonisolated static func normalizedAddress(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for tail in ["/api/v1", "/api"] where s.lowercased().hasSuffix(tail) { s.removeLast(tail.count) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              u.host?.isEmpty == false else { return nil }
        return s
    }

    nonisolated static func baseURL(_ address: String) -> String? { normalizedAddress(address).map { $0 + "/api/v1" } }

    // MARK: What gets deleted

    enum Kind: String, Codable, Equatable { case movie, series }

    /// The exact scope inside a series (nil = the whole title).
    struct Scope: Codable, Equatable {
        var seasons: [Int]? = nil
        var episodes: [Episode]? = nil
        struct Episode: Codable, Equatable, Hashable { let season: Int; let episode: Int }
        var json: [String: Any] {
            if let episodes { return ["episodes": episodes.map { ["season": $0.season, "episode": $0.episode] }] }
            return ["seasons": seasons ?? []]
        }
    }

    struct Target: Equatable {
        let kind: Kind
        let ref: String
        let scope: Scope?
        var whole: Bool { scope == nil }
    }

    /// TMDB id from ProviderIds, whatever the key's case ("Tmdb", "tmdb", "TMDB").
    nonisolated static func tmdb(_ ids: [String: String]?) -> String? {
        guard let ids else { return nil }
        for (k, v) in ids where k.lowercased() == "tmdb" {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.allSatisfy(\.isNumber) { return t }
        }
        return nil
    }

    /// The nexcrate title (and scope) for an Emby/Jellyfin item. Episodes and seasons use the SERIES' TMDB id and
    /// TMDB's numbering (= ParentIndexNumber / IndexNumber; specials are season 0). A double episode
    /// (IndexNumberEnd) names every episode the file holds. nil when the item can't be matched.
    nonisolated static func target(type: String?, providerIds: [String: String]?, seriesProviderIds: [String: String]?,
                                   index: Int?, parentIndex: Int?, indexEnd: Int? = nil) -> Target? {
        switch type {
        case "Movie":
            return tmdb(providerIds).map { Target(kind: .movie, ref: "tmdb:" + $0, scope: nil) }
        case "Series":
            return tmdb(providerIds).map { Target(kind: .series, ref: "tmdb:" + $0, scope: nil) }
        case "Season":
            guard let id = tmdb(seriesProviderIds), let n = index, n >= 0 else { return nil }
            return Target(kind: .series, ref: "tmdb:" + id, scope: Scope(seasons: [n]))
        case "Episode":
            guard let id = tmdb(seriesProviderIds), let s = parentIndex, let e = index, s >= 0, e >= 0 else { return nil }
            let last = max(e, indexEnd ?? e)
            return Target(kind: .series, ref: "tmdb:" + id,
                          scope: Scope(episodes: (e...min(last, e + 50)).map { Scope.Episode(season: s, episode: $0) }))
        default: return nil
        }
    }

    // MARK: Requests

    nonisolated static func system() -> Request { Request(method: "GET", path: "/system") }
    nonisolated static func versions() -> Request { Request(method: "GET", path: "/versions") }
    nonisolated static func lookup(_ t: Target) -> Request { Request(method: "GET", path: "/titles/\(t.kind.rawValue)/\(p(t.ref))") }

    /// Whole movie / series: stops downloads, removes the finished torrents with their files, recycles the library files.
    nonisolated static func removeTitle(_ t: Target) -> Request {
        Request(method: "DELETE", path: "/titles/\(t.kind.rawValue)/\(p(t.ref))?delete_files=true")
    }

    /// Season / episodes: the files of that scope into the recycle bin.
    nonisolated static func deleteFiles(_ t: Target) -> Request {
        Request(method: "POST", path: "/titles/\(t.kind.rawValue)/\(p(t.ref))/delete-files",
                body: json(["series": (t.scope ?? Scope()).json]))
    }

    /// Freeze (false) after deleting a scope so nexcrate doesn't load it again; thaw (true) after Undo.
    nonisolated static func monitoring(_ t: Target, monitored: Bool) -> Request {
        Request(method: "PUT", path: "/titles/\(t.kind.rawValue)/\(p(t.ref))/monitoring",
                body: json(["monitored": monitored, "series": (t.scope ?? Scope()).json]))
    }

    nonisolated static func recycleBin() -> Request { Request(method: "GET", path: "/recycle-bin") }
    nonisolated static func restore(_ entryId: Int) -> Request { Request(method: "POST", path: "/recycle-bin/\(entryId)/restore") }

    nonisolated static func pairing(app: String = "Cove") -> Request {
        Request(method: "POST", path: "/pairing", body: json(["app": app, "scopes": ["read", "request"]]))
    }
    nonisolated static func pairingState(_ id: String) -> Request { Request(method: "GET", path: "/pairing/\(p(id))") }

    nonisolated static func json(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    // MARK: Answers

    struct PairingStart: Decodable, Equatable {
        let pairing_id: String
        let secret: String
        let code: String
        let poll_seconds: Int?
    }

    struct PairingState: Decodable, Equatable {
        let state: String
        let key: String?
        let scopes: [String]?
        enum Phase: Equatable { case waiting, gotKey(String, [String]), delivered, denied, expired, unknown }
        var phase: Phase {
            switch state {
            case "pending": return .waiting
            case "confirmed": if let key, !key.isEmpty { return .gotKey(key, scopes ?? []) } else { return .delivered }
            case "delivered": return .delivered
            case "denied": return .denied
            case "expired": return .expired
            default: return .unknown
            }
        }
    }

    nonisolated static func decodePairingStart(_ d: Data) -> PairingStart? { try? JSONDecoder().decode(PairingStart.self, from: d) }
    nonisolated static func decodePairingState(_ d: Data) -> PairingState? { try? JSONDecoder().decode(PairingState.self, from: d) }

    struct SystemInfo: Equatable { let version: String?; let scopes: [String] }
    nonisolated static func decodeSystem(_ d: Data) -> SystemInfo? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["app"] != nil || o["version"] != nil else { return nil }
        return SystemInfo(version: o["version"] as? String, scopes: o["scopes"] as? [String] ?? [])
    }

    /// Version names by id from GET /versions (e.g. "1080p", "4K").
    nonisolated static func decodeVersionNames(_ d: Data) -> [String: String] {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let items = o["items"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for i in items { if let id = i["version_id"] as? String, let n = i["name"] as? String { out[id] = n } }
        return out
    }

    /// Version ids of a title (GET /titles/{kind}/{ref}): those of the whole title, or of one season.
    nonisolated static func decodeTitleVersions(_ d: Data, season: Int? = nil) -> [String] {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        if let season, let seasons = (o["series"] as? [String: Any])?["seasons"] as? [[String: Any]],
           let s = seasons.first(where: { ($0["season"] as? Int) == season }) {
            return (s["versions"] as? [[String: Any]] ?? []).compactMap { $0["version_id"] as? String }
        }
        return (o["versions"] as? [[String: Any]] ?? []).compactMap { $0["version_id"] as? String }
    }

    /// Flat error `{code, message, params}` (also inside `detail`).
    nonisolated static func errorCode(_ d: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let c = o["code"] as? String { return c }
        return (o["detail"] as? [String: Any])?["code"] as? String
    }

    /// The sentence for a failed nexcrate call (nil = OK).
    nonisolated static func message(status: Int, code: String?) -> String? {
        if (200..<300).contains(status) { return nil }
        switch code {
        case "download_finished", "download_importing":
            return "nexcrate is filing a download of this right now. Try again in a minute."
        case "title_has_source_versions":
            return "Radarr or Sonarr feeds this title in nexcrate, so nexcrate can't remove it. Delete it there (or take it out of that connection) first."
        case "title_not_found": return "nexcrate doesn't have this title."
        case "pairing_limit": return "Too many connection requests are waiting in nexcrate. Confirm or deny them there, then try again."
        case "pairing_not_found": return "nexcrate no longer knows this connection request. Start again."
        case let c? where c.hasPrefix("recycle_"):
            switch c {
            case "recycle_target_taken", "recycle_slot_taken": return "A file is already where the deleted one was, so nexcrate can't put it back."
            case "recycle_file_gone": return "The file is no longer in nexcrate's recycle bin."
            default: return "nexcrate couldn't restore the file (\(c))."
            }
        default: break
        }
        switch status {
        case 401: return "nexcrate didn't accept the key. Connect again in Settings → Connect."
        case 403: return "The nexcrate key may not do this. It needs the read and request scopes."
        case 404: return "nexcrate doesn't have this title."
        case 409: return "nexcrate refused this right now\(code.map { " (\($0))" } ?? ""). Try again in a minute."
        case 500..<600: return "nexcrate ran into a problem (error \(status)). Try again in a moment."
        default: return "nexcrate answered with error \(status)\(code.map { " (\($0))" } ?? "")."
        }
    }

    // MARK: Recycle bin

    struct RecycleEntry: Equatable {
        let entryId: Int
        let kind: String
        let ref: String?
        let season: Int?
        let episodes: [Int]
        let fileName: String
        let deletedAt: Date?
        let deletedBy: String?
        let restorable: Bool
    }

    nonisolated static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Naive timestamps (no zone): UTC
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: String(s.prefix(19)))
    }

    nonisolated static func decodeRecycleBin(_ d: Data) -> [RecycleEntry] {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let items = o["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { i in
            guard let id = (i["entry_id"] as? Int) ?? (i["entry_id"] as? NSNumber)?.intValue else { return nil }
            return RecycleEntry(entryId: id, kind: i["kind"] as? String ?? "", ref: i["ref"] as? String,
                                season: i["season"] as? Int, episodes: i["episodes"] as? [Int] ?? [],
                                fileName: i["file_name"] as? String ?? "", deletedAt: parseDate(i["deleted_at"] as? String),
                                deletedBy: i["deleted_by"] as? String, restorable: i["restorable"] as? Bool ?? false)
        }
    }

    /// The bin entries one delete made: same kind and ref, inside the scope, deleted by a key (a program), from
    /// one minute before `since` on (clocks differ a little).
    nonisolated static func matching(_ entries: [RecycleEntry], target t: Target, since: Date, slack: TimeInterval = 60) -> [RecycleEntry] {
        entries.filter { e in
            guard e.kind == t.kind.rawValue, e.ref == t.ref else { return false }
            if let by = e.deletedBy, by != "key" { return false }
            if let at = e.deletedAt, at < since.addingTimeInterval(-slack) { return false }
            guard let scope = t.scope else { return true }
            if let eps = scope.episodes {
                return eps.contains { $0.season == e.season && e.episodes.contains($0.episode) }
            }
            if let seasons = scope.seasons { return e.season.map { s in seasons.contains(s) } ?? false }
            return true
        }
    }

    // MARK: Confirm text

    struct ConfirmText: Equatable {
        let scopeLine: String
        let bullets: [String]
        let warning: String?
        let hint: String?
        let button: String
    }

    static let connectHint = "Connect nexcrate in Settings → Connect for a 7-day undo."
    static let permanentWarning = "\u{26A0} This is permanent. This title is not in nexcrate, so the files are deleted from the server's disk right away and can't be restored."

    /// "Movie", "Series with 3 seasons", "Season 2", "S2:E4", "Specials".
    nonisolated static func scopeLine(type: String?, name: String, seriesName: String?, index: Int?, parentIndex: Int?,
                                      indexEnd: Int?, childCount: Int?) -> String {
        switch type {
        case "Movie": return "The movie \u{201C}\(name)\u{201D}"
        case "Series":
            let n = childCount.map { " with \($0) season\($0 == 1 ? "" : "s")" } ?? ""
            return "The whole series \u{201C}\(name)\u{201D}\(n)"
        case "Season":
            let s = index == 0 ? "Specials" : "Season \(index ?? 0)"
            return "\(s) of \u{201C}\(seriesName ?? name)\u{201D}"
        case "Episode":
            let e = indexEnd.map { $0 > (index ?? 0) ? "-E\($0)" : "" } ?? ""
            return "S\(parentIndex ?? 0):E\(index ?? 0)\(e) \u{201C}\(name)\u{201D} of \u{201C}\(seriesName ?? "")\u{201D}"
        default: return "\u{201C}\(name)\u{201D}"
        }
    }

    /// The confirm window's lines: nexcrate path (inNexcrate) or the permanent path with its red warning.
    nonisolated static func confirmText(type: String?, scopeLine: String, inNexcrate: Bool, configured: Bool,
                                        versionNames: [String], doubleEpisode: Bool = false, season: Int? = nil) -> ConfirmText {
        guard inNexcrate else {
            return ConfirmText(scopeLine: scopeLine,
                               bullets: ["\u{2022} The files are deleted from the server's disk", "\u{2022} The item leaves the library for everyone"],
                               warning: permanentWarning, hint: configured ? nil : connectHint, button: "Delete permanently")
        }
        var b: [String] = []
        let v = versionNames.isEmpty ? "" : " (versions: \(versionNames.joined(separator: ", ")))"
        switch type {
        case "Movie", "Series":
            b.append("\u{2022} Removed from nexcrate\(v)")
            b.append("\u{2022} Torrents removed from qBittorrent (stops seeding \u{2014} may matter on private trackers)")
        case "Season":
            let s = season == 0 ? "the Specials" : "Season \(season ?? 0)"
            b.append("\u{2022} Files of \(s) removed, season frozen in nexcrate\(v)")
        default:
            b.append("\u{2022} The episode's file is removed, the episode frozen in nexcrate\(v)")
            if doubleEpisode { b.append("\u{2022} This file holds several episodes: it goes whole") }
        }
        b.append("\u{2022} Files go to nexcrate's recycle bin for 7 days \u{2014} you can Undo")
        return ConfirmText(scopeLine: scopeLine, bullets: b, warning: nil, hint: nil, button: "Delete")
    }

    /// The media server's answer to DELETE /Items/{id} (nil = OK).
    nonisolated static func serverDeleteMessage(status: Int) -> String? {
        switch status {
        case 200..<300: return nil
        case 401: return "Your sign-in has expired. Sign in again and retry."
        case 403: return "The server didn't allow deleting media. Turn on Allow media deletion for your account in Manage server → Users."
        case 404: return "The server couldn't find this item (it may be gone already)."
        default: return ItemAdminAPI.message(status: status, action: "delete this item")
        }
    }

    /// Only these kinds can be deleted (no collections, no bulk).
    nonisolated static func canDelete(type: String?, admin: Bool?) -> Bool {
        admin == true && ["Movie", "Series", "Season", "Episode"].contains(type ?? "")
    }
}

// MARK: - Recently deleted (Undo after the toast is gone)

struct DeletionRecord: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    let server: String
    let itemId: String
    let name: String
    let what: String
    let kind: NexcrateAPI.Kind
    let ref: String
    let scope: NexcrateAPI.Scope?
    let deletedAt: Date
    var entryIds: [Int]
    var libraryId: String?
    /// Poster link captured at delete time (older records don't have it; decodes as nil)
    var posterURL: String? = nil
    /// The item whose poster that is (the series for an episode)
    var posterItemId: String? = nil
    var target: NexcrateAPI.Target { .init(kind: kind, ref: ref, scope: scope) }
}

/// What a Trash row shows: the same wording as before, plus where its small poster comes from.
struct DeletedRowModel: Equatable {
    enum Poster: Equatable { case url(URL), placeholder(String) }
    let title: String
    let line: String
    let poster: Poster

    nonisolated static func lineText(_ r: DeletionRecord) -> String {
        "Deleted \(r.deletedAt.formatted(date: .abbreviated, time: .shortened)) · Deleted permanently on \(r.deletedAt.addingTimeInterval(DeletionStore.lifetime).formatted(date: .abbreviated, time: .omitted))"
    }
    enum Urgency: Equatable { case normal, warning, danger }
    /// Time left before nexcrate empties it: ≥48 h "N days left", 24–48 h "Last day", <24 h "N h left" ("<1 h left")
    nonisolated static func countdown(_ r: DeletionRecord, now: Date = Date()) -> (text: String, urgency: Urgency) {
        countdown(seconds: r.deletedAt.addingTimeInterval(DeletionStore.lifetime).timeIntervalSince(now))
    }
    nonisolated static func countdown(seconds: TimeInterval) -> (text: String, urgency: Urgency) {
        let hours = Int((max(seconds, 0) / 3600).rounded(.down))
        if hours >= 48 { return ("\(hours / 24) days left", .normal) }
        if hours >= 24 { return ("Last day", .warning) }
        if hours < 1 { return ("<1 h left", .danger) }
        return ("\(hours) h left", .danger)
    }
    nonisolated static func placeholder(_ k: NexcrateAPI.Kind) -> String { k == .series ? "tv" : "film" }
    /// Stored poster link → the server's picture for the stored poster id / item id (may still be cached) → a placeholder
    nonisolated static func poster(_ r: DeletionRecord, server: (String) -> URL?) -> Poster {
        if let s = r.posterURL, let u = URL(string: s), u.scheme != nil { return .url(u) }
        for id in [r.posterItemId, r.itemId].compactMap({ $0 }) where !id.isEmpty {
            if let u = server(id) { return .url(u) }
        }
        return .placeholder(placeholder(r.kind))
    }
    nonisolated static func make(_ r: DeletionRecord, server: (String) -> URL?) -> DeletedRowModel {
        DeletedRowModel(title: r.what, line: lineText(r), poster: poster(r, server: server))
    }
}

enum DeletionStore {
    static let lifetime: TimeInterval = 7 * 24 * 3600

    nonisolated static func pruned(_ r: [DeletionRecord], now: Date = Date()) -> [DeletionRecord] {
        r.filter { now.timeIntervalSince($0.deletedAt) < lifetime }.sorted { $0.deletedAt > $1.deletedAt }
    }

    nonisolated static func encode(_ r: [DeletionRecord]) -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return try? e.encode(r)
    }
    nonisolated static func decode(_ d: Data) -> [DeletionRecord] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([DeletionRecord].self, from: d)) ?? []
    }

    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recently-deleted.json")
    }

    static func load(now: Date = Date()) -> [DeletionRecord] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return pruned(decode(d), now: now)
    }

    static func save(_ r: [DeletionRecord]) {
        guard let d = encode(pruned(r)) else { return }
        try? d.write(to: file, options: .atomic)
    }
}
