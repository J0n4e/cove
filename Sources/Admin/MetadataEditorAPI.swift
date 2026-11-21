import Foundation

// Edit metadata (admins only): the item editor of both web dashboards, plus the "Find to edit…" search on a
// library page. Pure request shapes, decoding, edit application and the diff text; tested in
// Tests/MetadataEditorTests.swift.
//
// Saving works like both web clients: GET the full item, change only the edited keys in that JSON and POST the
// whole object back to /Items/{id}. Keys we don't know are sent back untouched.
// Server differences handled here:
//  - Tags: Jellyfin returns and accepts `Tags` (strings). Emby returns `TagItems` [{Name, Id}] (and on some
//    versions also `Tags`) and reads `TagItems` on save. We send `Tags` always and `TagItems` whenever the item
//    came with it (or the server is Emby).
//  - Genres: both send `Genres` strings; some versions add `GenreItems` [{Name, Id}], which we keep in step.
//  - Studios: [{Name, Id}] on both. People: [{Name, Id, Role, Type}] on both.

enum MetadataEditorAPI {
    typealias Request = ItemAdminAPI.Request
    nonisolated static func p(_ s: String) -> String { ItemAdminAPI.p(s) }
    nonisolated static func q(_ s: String) -> String { ItemAdminAPI.q(s) }

    // MARK: Find to edit (library search)

    /// The item kinds worth editing per library type.
    nonisolated static func searchTypes(_ kind: String?) -> String {
        switch kind ?? "" {
        case "movies": return "Movie,BoxSet"
        case "tvshows": return "Series,Season,Episode"
        case "boxsets": return "BoxSet"
        default: return "Movie,Series,BoxSet,Season,Episode"
        }
    }

    /// GET /Users/{u}/Items?ParentId=<lib>&Recursive=true&SearchTerm=…&IncludeItemTypes=…&Limit=20.
    /// nil for an empty term (nothing to search).
    nonisolated static func search(userId: String, libraryId: String, kind: String?, term: String, limit: Int = 20) -> Request? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Request(method: "GET", path: "/Users/\(p(userId))/Items?ParentId=\(q(libraryId))&Recursive=true"
            + "&SearchTerm=\(q(t))&IncludeItemTypes=\(searchTypes(kind))&Limit=\(limit)"
            + "&Fields=ProductionYear,Path&EnableUserData=false&EnableImageTypes=Primary")
    }

    struct Hit: Identifiable, Equatable {
        let id: String
        let name: String
        let type: String?
        let year: Int?
        let series: String?
        let primaryTag: String?
        /// "S1 · E3" style context for episodes / seasons.
        var detail: String {
            var parts: [String] = []
            if let series, !series.isEmpty, type == "Episode" || type == "Season" { parts.append(series) }
            parts.append(typeTitle(type))
            if let year { parts.append(String(year)) }
            return parts.joined(separator: " · ")
        }
    }

    nonisolated static func typeTitle(_ t: String?) -> String {
        switch t ?? "" {
        case "Movie": return "Movie"
        case "Series": return "Show"
        case "Season": return "Season"
        case "Episode": return "Episode"
        case "BoxSet": return "Collection"
        default: return t ?? "Item"
        }
    }

    nonisolated static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
    nonisolated static func dbl(_ v: Any?) -> Double? { (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0) } }

    nonisolated static func decodeHits(_ data: Data) -> [Hit] {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (d["Items"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["Id"] as? String else { return nil }
            return Hit(id: id, name: m["Name"] as? String ?? "Untitled", type: m["Type"] as? String,
                       year: int(m["ProductionYear"]), series: m["SeriesName"] as? String,
                       primaryTag: (m["ImageTags"] as? [String: Any])?["Primary"] as? String)
        }
    }

    /// Arrow keys in the result list: wraps nowhere, stays inside 0..<count (nil when empty).
    nonisolated static func moveSelection(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return min(max(current + delta, 0), count - 1)
    }

    // MARK: Load

    static let fields = ["Overview", "Genres", "Tags", "Studios", "People", "ProviderIds", "SortName",
        "OriginalTitle", "Taglines", "OfficialRating", "CustomRating", "CommunityRating", "CriticRating",
        "PremiereDate", "EndDate", "ProductionYear", "Status", "AirDays", "AirTime", "LockedFields", "LockData",
        "DisplayOrder", "PreferredMetadataLanguage", "PreferredMetadataCountryCode", "ProductionLocations", "Path",
        "DateCreated", "ExternalUrls"]

    /// GET /Users/{u}/Items/{id} with every editable field.
    nonisolated static func load(userId: String, itemId: String) -> Request {
        Request(method: "GET", path: "/Users/\(p(userId))/Items/\(p(itemId))?Fields=\(fields.joined(separator: ","))")
    }

    /// POST /Items/{id} with the full item JSON.
    nonisolated static func save(itemId: String, item: [String: Any]) -> Request? {
        guard let d = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { return nil }
        return Request(method: "POST", path: "/Items/\(p(itemId))", contentType: "application/json", body: d)
    }

    nonisolated static func parentalRatings() -> Request { Request(method: "GET", path: "/Localization/ParentalRatings") }

    /// /Genres, /Tags, /Studios (suggestions), scoped to the library when known.
    nonisolated static func suggestions(_ kind: String, userId: String, parentId: String?) -> Request {
        var path = "/\(kind)?UserId=\(q(userId))&Recursive=true&SortBy=SortName&Limit=500&EnableImages=false"
        if let parentId, !parentId.isEmpty { path += "&ParentId=\(q(parentId))" }
        return Request(method: "GET", path: path)
    }

    nonisolated static func persons(term: String, userId: String) -> Request? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Request(method: "GET", path: "/Persons?SearchTerm=\(q(t))&UserId=\(q(userId))&Limit=10&EnableImages=false")
    }

    /// Names out of a {Items:[{Name}]} answer (or a plain array), deduped, in order.
    nonisolated static func decodeNames(_ data: Data) -> [String] {
        let o = try? JSONSerialization.jsonObject(with: data)
        let arr = (o as? [String: Any])?["Items"] as? [[String: Any]] ?? (o as? [[String: Any]] ?? [])
        var seen = Set<String>()
        return arr.compactMap { $0["Name"] as? String }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// /Localization/ParentalRatings → [{Name, Value}] → names, deduped.
    nonisolated static func decodeRatings(_ data: Data) -> [String] { decodeNames(data) }

    // MARK: The editable copy

    struct Person: Equatable, Identifiable {
        var id = UUID()
        var name: String
        var role: String = ""
        var type: String = "Actor"
        var serverId: String? = nil
        static func == (a: Person, b: Person) -> Bool { a.name == b.name && a.role == b.role && a.type == b.type && a.serverId == b.serverId }
    }

    static let personTypes = ["Actor", "Director", "Writer", "Producer", "GuestStar", "Composer"]

    /// Per-field locks both servers know (names as the server stores them in LockedFields).
    static let lockableFields: [(key: String, title: String)] = [
        ("Name", "Title"), ("OriginalTitle", "Original title"), ("SortName", "Sort title"), ("Overview", "Overview"),
        ("Genres", "Genres"), ("Tags", "Tags"), ("Studios", "Studios"), ("Cast", "People"),
        ("OfficialRating", "Parental rating"), ("ProductionLocations", "Production locations"), ("Runtime", "Runtime"),
    ]

    /// Provider id fields shown for each kind (plus whatever else the item has).
    nonisolated static func providerKeys(_ type: String?, existing: [String: String]) -> [String] {
        var base: [String]
        switch type ?? "" {
        case "Series", "Season", "Episode": base = ["Imdb", "Tmdb", "Tvdb"]
        case "BoxSet": base = ["Tmdb"]
        default: base = ["Imdb", "Tmdb"]
        }
        for k in existing.keys.sorted() where !base.contains(k) { base.append(k) }
        return base
    }

    nonisolated static func providerTitle(_ k: String) -> String {
        ["Imdb": "IMDb", "Tmdb": "TMDb", "Tvdb": "TheTVDB", "TmdbCollection": "TMDb collection", "Zap2It": "Zap2It"][k] ?? k
    }

    /// Link to the provider's page for an id (nil when unknown or empty).
    nonisolated static func providerURL(_ k: String, id: String, type: String?) -> URL? {
        let v = id.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        let tv = type == "Series" || type == "Season" || type == "Episode"
        switch k {
        case "Imdb": return URL(string: "https://www.imdb.com/title/\(q(v))")
        case "Tmdb": return URL(string: "https://www.themoviedb.org/\(type == "BoxSet" ? "collection" : tv ? "tv" : "movie")/\(q(v))")
        case "TmdbCollection": return URL(string: "https://www.themoviedb.org/collection/\(q(v))")
        case "Tvdb": return URL(string: "https://thetvdb.com/dereferrer/\(type == "Episode" ? "episode" : "series")/\(q(v))")
        default: return nil
        }
    }

    struct Draft: Equatable {
        var name = ""
        var originalTitle = ""
        var sortName = ""
        var tagline = ""
        var overview = ""
        var year = ""
        var premiereDate = ""   // yyyy-MM-dd
        var endDate = ""
        var status = ""         // "", Continuing, Ended
        var officialRating = ""
        var customRating = ""
        var communityRating = ""
        var criticRating = ""
        var genres: [String] = []
        var tags: [String] = []
        var studios: [String] = []
        var people: [Person] = []
        var providerIds: [String: String] = [:]
        var lockData = false
        var lockedFields: [String] = []
        var language = ""
        var country = ""
        var displayOrder = ""
    }

    nonisolated static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// "2010-07-16T00:00:00.0000000Z" → "2010-07-16".
    nonisolated static func day(_ v: Any?) -> String { String(str(v).prefix(10)) }

    nonisolated static func number(_ v: Any?) -> String {
        guard let d = dbl(v) else { return "" }
        return d == d.rounded() ? String(Int(d)) : String(d)
    }

    /// Names from a [String] or [{Name}] field.
    nonisolated static func names(_ v: Any?) -> [String] {
        if let s = v as? [String] { return s }
        return (v as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String }
    }

    /// Emby's TagItems first (that's what Emby saves), else Tags.
    nonisolated static func tagNames(_ item: [String: Any]) -> [String] {
        let ti = names(item["TagItems"])
        return ti.isEmpty ? names(item["Tags"]) : ti
    }

    nonisolated static func draft(_ item: [String: Any]) -> Draft {
        var d = Draft()
        d.name = str(item["Name"])
        d.originalTitle = str(item["OriginalTitle"])
        d.sortName = str(item["ForcedSortName"]).isEmpty ? str(item["SortName"]) : str(item["ForcedSortName"])
        d.tagline = (item["Taglines"] as? [String])?.first ?? ""
        d.overview = str(item["Overview"])
        d.year = str(item["ProductionYear"])
        d.premiereDate = day(item["PremiereDate"])
        d.endDate = day(item["EndDate"])
        d.status = str(item["Status"])
        d.officialRating = str(item["OfficialRating"])
        d.customRating = str(item["CustomRating"])
        d.communityRating = number(item["CommunityRating"])
        d.criticRating = number(item["CriticRating"])
        d.genres = names(item["Genres"]).isEmpty ? names(item["GenreItems"]) : names(item["Genres"])
        d.tags = tagNames(item)
        d.studios = names(item["Studios"])
        d.people = (item["People"] as? [[String: Any]] ?? []).compactMap { m in
            guard let n = m["Name"] as? String else { return nil }
            return Person(name: n, role: str(m["Role"]), type: str(m["Type"]).isEmpty ? "Actor" : str(m["Type"]),
                          serverId: m["Id"] as? String)
        }
        for (k, v) in item["ProviderIds"] as? [String: Any] ?? [:] { let s = str(v); if !s.isEmpty { d.providerIds[k] = s } }
        d.lockData = (item["LockData"] as? Bool) ?? false
        d.lockedFields = item["LockedFields"] as? [String] ?? []
        d.language = str(item["PreferredMetadataLanguage"])
        d.country = str(item["PreferredMetadataCountryCode"])
        d.displayOrder = str(item["DisplayOrder"])
        return d
    }

    // MARK: Apply

    nonisolated static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Chip list cleanup: trimmed, no empties, no case-insensitive duplicates, order kept.
    nonisolated static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map(trimmed).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// [{Name, Id}] keeping the server's own entry (and its Id) for names that were already there.
    nonisolated static func nameItems(_ names: [String], old: Any?) -> [[String: Any]] {
        var byName: [String: [String: Any]] = [:]
        for m in old as? [[String: Any]] ?? [] { if let n = m["Name"] as? String { byName[n.lowercased()] = m } }
        return names.map { byName[$0.lowercased()] ?? ["Name": $0] }
    }

    nonisolated static func isoDay(_ s: String) -> Any {
        let t = trimmed(s)
        guard t.count == 10, t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return NSNull() }
        return t + "T00:00:00.000Z"
    }

    nonisolated static func optString(_ s: String) -> Any { let t = trimmed(s); return t.isEmpty ? NSNull() : t }
    nonisolated static func optNumber(_ s: String) -> Any {
        Double(trimmed(s).replacingOccurrences(of: ",", with: ".")).map { $0 as Any } ?? NSNull()
    }

    /// The item to POST: the server's JSON with only the keys that differ between `original` and `edited`.
    /// `emby` = the server is Emby (TagItems is then always written).
    nonisolated static func apply(_ edited: Draft, original: Draft, to item: [String: Any], emby: Bool) -> [String: Any] {
        var o = item
        let e = edited
        if e.name != original.name { o["Name"] = trimmed(e.name) }
        if e.originalTitle != original.originalTitle { o["OriginalTitle"] = optString(e.originalTitle) }
        if e.sortName != original.sortName {
            o["ForcedSortName"] = optString(e.sortName)
            o["SortName"] = optString(e.sortName)
        }
        if e.tagline != original.tagline {
            var t = item["Taglines"] as? [String] ?? []
            let v = trimmed(e.tagline)
            if v.isEmpty { t = Array(t.dropFirst()) } else if t.isEmpty { t = [v] } else { t[0] = v }
            o["Taglines"] = t
        }
        if e.overview != original.overview { o["Overview"] = optString(e.overview) }
        if e.year != original.year { o["ProductionYear"] = Int(trimmed(e.year)).map { $0 as Any } ?? NSNull() }
        if e.premiereDate != original.premiereDate { o["PremiereDate"] = isoDay(e.premiereDate) }
        if e.endDate != original.endDate { o["EndDate"] = isoDay(e.endDate) }
        if e.status != original.status { o["Status"] = optString(e.status) }
        if e.officialRating != original.officialRating { o["OfficialRating"] = optString(e.officialRating) }
        if e.customRating != original.customRating { o["CustomRating"] = optString(e.customRating) }
        if e.communityRating != original.communityRating { o["CommunityRating"] = optNumber(e.communityRating) }
        if e.criticRating != original.criticRating { o["CriticRating"] = optNumber(e.criticRating) }
        if e.genres != original.genres {
            let g = clean(e.genres)
            o["Genres"] = g
            if item["GenreItems"] != nil { o["GenreItems"] = nameItems(g, old: item["GenreItems"]) }
        }
        if e.tags != original.tags {
            let t = clean(e.tags)
            o["Tags"] = t
            if emby || item["TagItems"] != nil { o["TagItems"] = nameItems(t, old: item["TagItems"]) }
        }
        if e.studios != original.studios { o["Studios"] = nameItems(clean(e.studios), old: item["Studios"]) }
        if e.people != original.people {
            let old = item["People"] as? [[String: Any]] ?? []
            o["People"] = e.people.filter { !trimmed($0.name).isEmpty }.map { p -> [String: Any] in
                // Keep the server's own entry (Id, PrimaryImageTag, …) for a person that was there
                var m = old.first { ($0["Id"] as? String) != nil && ($0["Id"] as? String) == p.serverId
                    && ($0["Name"] as? String) == p.name } ?? [:]
                m["Name"] = trimmed(p.name)
                m["Type"] = p.type
                m["Role"] = trimmed(p.role)
                if m["Id"] == nil, let id = p.serverId { m["Id"] = id }
                return m
            }
        }
        if e.providerIds != original.providerIds {
            var ids = item["ProviderIds"] as? [String: Any] ?? [:]
            for k in Set(e.providerIds.keys).union(original.providerIds.keys) {
                let v = trimmed(e.providerIds[k] ?? "")
                if v.isEmpty { ids.removeValue(forKey: k) } else { ids[k] = v }
            }
            o["ProviderIds"] = ids
        }
        if e.lockData != original.lockData { o["LockData"] = e.lockData }
        if Set(e.lockedFields) != Set(original.lockedFields) { o["LockedFields"] = e.lockedFields }
        if e.language != original.language { o["PreferredMetadataLanguage"] = optString(e.language) }
        if e.country != original.country { o["PreferredMetadataCountryCode"] = optString(e.country) }
        if e.displayOrder != original.displayOrder { o["DisplayOrder"] = optString(e.displayOrder) }
        return o
    }

    // MARK: Diff summary

    nonisolated static func listDiff(_ title: String, _ a: [String], _ b: [String]) -> String? {
        let al = Set(a.map { $0.lowercased() }), bl = Set(b.map { $0.lowercased() })
        let added = b.filter { !al.contains($0.lowercased()) }, removed = a.filter { !bl.contains($0.lowercased()) }
        if added.isEmpty && removed.isEmpty { return a == b ? nil : "\(title) reordered" }
        return title + " " + (added.map { "+" + $0 } + removed.map { "\u{2212}" + $0 }).joined(separator: " ")
    }

    /// "Changed: Genres +Thriller −Drama, Tags +4K" (empty when nothing changed).
    nonisolated static func summary(_ e: Draft, original o: Draft) -> String {
        var parts: [String] = []
        let fields: [(String, String, String)] = [
            ("Title", o.name, e.name), ("Original title", o.originalTitle, e.originalTitle), ("Sort title", o.sortName, e.sortName),
            ("Tagline", o.tagline, e.tagline), ("Overview", o.overview, e.overview), ("Year", o.year, e.year),
            ("Premiere date", o.premiereDate, e.premiereDate), ("End date", o.endDate, e.endDate), ("Status", o.status, e.status),
            ("Parental rating", o.officialRating, e.officialRating), ("Custom rating", o.customRating, e.customRating),
            ("Community rating", o.communityRating, e.communityRating), ("Critic rating", o.criticRating, e.criticRating),
            ("Language", o.language, e.language), ("Country", o.country, e.country), ("Display order", o.displayOrder, e.displayOrder),
        ]
        for (t, a, b) in fields where a != b {
            if t == "Overview" { parts.append("Overview"); continue }
            let bt = trimmed(b)
            parts.append(bt.isEmpty ? "\(t) cleared" : "\(t) \u{2192} \(bt)")
        }
        if let s = listDiff("Genres", o.genres, clean(e.genres)) { parts.append(s) }
        if let s = listDiff("Tags", o.tags, clean(e.tags)) { parts.append(s) }
        if let s = listDiff("Studios", o.studios, clean(e.studios)) { parts.append(s) }
        if e.people != o.people {
            let a = o.people.map(\.name), b = e.people.map(\.name)
            parts.append(listDiff("People", a, b) ?? "People edited")
        }
        for k in Set(e.providerIds.keys).union(o.providerIds.keys).sorted()
            where trimmed(e.providerIds[k] ?? "") != (o.providerIds[k] ?? "") {
            let v = trimmed(e.providerIds[k] ?? "")
            parts.append(v.isEmpty ? "\(providerTitle(k)) id removed" : "\(providerTitle(k)) id \u{2192} \(v)")
        }
        if e.lockData != o.lockData { parts.append(e.lockData ? "Metadata locked" : "Metadata unlocked") }
        if Set(e.lockedFields) != Set(o.lockedFields) {
            let t = Dictionary(uniqueKeysWithValues: lockableFields.map { ($0.key, $0.title) })
            let add = e.lockedFields.filter { !o.lockedFields.contains($0) }.map { "+" + (t[$0] ?? $0) }
            let rem = o.lockedFields.filter { !e.lockedFields.contains($0) }.map { "\u{2212}" + (t[$0] ?? $0) }
            parts.append("Locks " + (add + rem).joined(separator: " "))
        }
        return parts.isEmpty ? "" : "Changed: " + parts.joined(separator: ", ")
    }

    /// Show "Lock Genres/Tags so a refresh keeps your changes" when they were edited and aren't locked.
    nonisolated static func needsLockHint(_ e: Draft, original o: Draft) -> [String] {
        guard !e.lockData else { return [] }
        var out: [String] = []
        if e.genres != o.genres && !e.lockedFields.contains("Genres") { out.append("Genres") }
        if e.tags != o.tags && !e.lockedFields.contains("Tags") { out.append("Tags") }
        if e.studios != o.studios && !e.lockedFields.contains("Studios") { out.append("Studios") }
        return out
    }

    /// Chip suggestions: matching names not already chosen, prefix matches first.
    nonisolated static func suggest(_ term: String, from all: [String], excluding chosen: [String], limit: Int = 8) -> [String] {
        let t = trimmed(term).lowercased()
        guard !t.isEmpty else { return [] }
        let have = Set(chosen.map { $0.lowercased() })
        let m = all.filter { !have.contains($0.lowercased()) && $0.lowercased().contains(t) }
        return Array((m.filter { $0.lowercased().hasPrefix(t) } + m.filter { !$0.lowercased().hasPrefix(t) }).prefix(limit))
    }
}
