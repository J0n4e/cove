import Foundation

// Item admin tools (admins only): Refresh metadata, Identify, Edit images, Items without poster/backdrop.
// Pure request shapes and decoding, tested in Tests/ItemAdminTests.swift. The same endpoints exist on Emby and
// Jellyfin (both web dashboards use them); where the two differ it is said next to the code.

enum ItemAdminAPI {
    /// One server call: method, path with query, optional body and its type.
    struct Request: Equatable {
        let method: String
        let path: String
        var contentType: String? = nil
        var body: Data? = nil
    }

    /// Strict query encoding: a link inside a query (ImageUrl) must keep its own ?, & and = encoded.
    nonisolated static func q(_ s: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }
    nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    nonisolated static func p(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    // MARK: Refresh metadata

    /// The three choices of the web dashboards' Refresh metadata dialog.
    enum RefreshMode: String, CaseIterable, Identifiable {
        case scan, missing, replaceAll
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scan: return "Scan for new and updated files"
            case .missing: return "Search for missing metadata"
            case .replaceAll: return "Replace all metadata"
            }
        }
        var detail: String {
            switch self {
            case .scan: return "Looks for new or changed files and reads what's already saved. Fastest."
            case .missing: return "Downloads metadata and images the item doesn't have yet. Keeps what's there."
            case .replaceAll: return "Downloads everything again and overwrites the current metadata, including your own edits."
            }
        }
        /// Replace all overwrites edits: the dialog asks first.
        var needsConfirm: Bool { self == .replaceAll }
    }

    /// POST /Items/{id}/Refresh. Scan = Default modes (what "Scan" sends in both dashboards); missing / replace all =
    /// FullRefresh; ReplaceAllMetadata only for replace all; ReplaceAllImages from the checkbox.
    nonisolated static func refresh(itemId: String, mode: RefreshMode, replaceImages: Bool) -> Request {
        let full = mode != .scan
        let m = full ? "FullRefresh" : "Default"
        // Scan never touches images, so the checkbox only applies to the two full modes
        let imgMode = full ? "FullRefresh" : "Default"
        let path = "/Items/\(p(itemId))/Refresh?Recursive=true&MetadataRefreshMode=\(m)&ImageRefreshMode=\(imgMode)"
            + "&ReplaceAllMetadata=\(mode == .replaceAll)&ReplaceAllImages=\(full && replaceImages)"
        return Request(method: "POST", path: path)
    }

    // MARK: Identify

    /// Identify exists for movies and shows only (what both dashboards offer).
    nonisolated static func searchKind(_ type: String?) -> String? {
        switch type {
        case "Movie": return "Movie"
        case "Series": return "Series"
        default: return nil
        }
    }

    /// The provider id fields the Identify form shows: IMDb + TMDb for movies, IMDb + TMDb + TVDb for shows.
    nonisolated static func providerFields(_ type: String?) -> [String] {
        type == "Series" ? ["Imdb", "Tmdb", "Tvdb"] : ["Imdb", "Tmdb"]
    }

    /// POST /Items/RemoteSearch/Movie|Series {SearchInfo:{Name,Year,ProviderIds}, ItemId, IncludeDisabledProviders}.
    /// MetadataLanguage / MetadataCountryCode: the library's own metadata language when it has one (passed in),
    /// else English / US, so results don't come back in the server's UI language.
    nonisolated static func remoteSearch(itemId: String, type: String?, name: String, year: Int?,
                                         providerIds: [String: String],
                                         metadataLanguage: String? = nil, countryCode: String? = nil) -> Request? {
        guard let kind = searchKind(type) else { return nil }
        var info: [String: Any] = [:]
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { info["Name"] = n }
        if let year { info["Year"] = year }
        let ids = providerIds.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        if !ids.isEmpty { info["ProviderIds"] = ids }
        info["MetadataLanguage"] = nonEmpty(metadataLanguage) ?? "en"
        info["MetadataCountryCode"] = nonEmpty(countryCode) ?? "US"
        let body: [String: Any] = ["SearchInfo": info, "ItemId": itemId, "IncludeDisabledProviders": true]
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return Request(method: "POST", path: "/Items/RemoteSearch/\(kind)", contentType: "application/json", body: data)
    }

    /// One Identify result. `raw` is the server's own JSON for it, sent back unchanged to Apply.
    struct SearchResult: Identifiable, Equatable {
        let id: Int
        let name: String
        let year: Int?
        let overview: String?
        let imageURL: String?
        let provider: String?
        let providerIds: [String: String]
        let raw: Data
    }

    /// Both servers answer a plain array of RemoteSearchResult (Name, ProductionYear, PremiereDate, ImageUrl,
    /// Overview, SearchProviderName, ProviderIds).
    nonisolated static func decodeSearch(_ data: Data) -> [SearchResult] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.enumerated().compactMap { i, d in
            guard let name = d["Name"] as? String else { return nil }
            var year = (d["ProductionYear"] as? Int) ?? (d["ProductionYear"] as? NSNumber)?.intValue
            if year == nil, let pd = d["PremiereDate"] as? String { year = Int(pd.prefix(4)) }
            var ids: [String: String] = [:]
            for (k, v) in d["ProviderIds"] as? [String: Any] ?? [:] {
                if let s = v as? String { ids[k] = s } else if let n = v as? NSNumber { ids[k] = n.stringValue }
            }
            let raw = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
            return SearchResult(id: i, name: name, year: year, overview: (d["Overview"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                imageURL: (d["ImageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                provider: d["SearchProviderName"] as? String, providerIds: ids, raw: raw)
        }
    }

    /// POST /Items/RemoteSearch/Apply/{id}?ReplaceAllImages=true with the picked result as the body.
    nonisolated static func apply(itemId: String, result: SearchResult, replaceImages: Bool = true) -> Request {
        Request(method: "POST", path: "/Items/RemoteSearch/Apply/\(p(itemId))?ReplaceAllImages=\(replaceImages)",
                contentType: "application/json", body: result.raw)
    }

    // MARK: Images

    /// The image kinds the editor shows per item type (the ones the dashboards offer).
    nonisolated static func imageTypes(_ type: String?) -> [String] {
        switch type {
        case "Movie": return ["Primary", "Backdrop", "Logo", "Thumb", "Banner", "Art", "Disc"]
        case "Series", "BoxSet": return ["Primary", "Backdrop", "Logo", "Thumb", "Banner", "Art"]
        case "Season": return ["Primary", "Backdrop", "Thumb", "Banner"]
        case "Episode": return ["Primary"]
        default: return ["Primary", "Backdrop"]
        }
    }

    nonisolated static func typeTitle(_ t: String) -> String {
        switch t {
        case "Primary": return "Poster"
        case "Backdrop": return "Backdrops"
        case "Thumb": return "Thumb"
        case "Art": return "Clear art"
        default: return t
        }
    }

    /// Backdrops can be several; every other kind is one picture.
    nonisolated static func isMultiple(_ t: String) -> Bool { t == "Backdrop" }

    /// What the item has now: kind → tags in index order (from ImageTags + BackdropImageTags).
    nonisolated static func currentImages(_ item: [String: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (k, v) in item["ImageTags"] as? [String: Any] ?? [:] { if let s = v as? String { out[k] = [s] } }
        if let b = item["BackdropImageTags"] as? [String], !b.isEmpty { out["Backdrop"] = b }
        return out
    }

    /// The current picture as the app shows it (with the server's enhancers, like every other poster in Cove).
    nonisolated static func imagePath(itemId: String, type: String, index: Int, tag: String, maxWidth: Int) -> String {
        "/Items/\(p(itemId))/Images/\(type)/\(index)?maxWidth=\(maxWidth)&quality=85&tag=\(q(tag))"
    }

    /// DELETE /Items/{id}/Images/{type}/{index} (both servers).
    nonisolated static func deleteImage(itemId: String, type: String, index: Int) -> Request {
        Request(method: "DELETE", path: "/Items/\(p(itemId))/Images/\(type)/\(index)")
    }

    /// GET /Items/{id}/RemoteImages?Type=…&IncludeAllLanguages=…&Language=en(&ProviderName=…). `Language` is read by
    /// Emby and ignored by Jellyfin (harmless); either way the answer is sorted English + no-language first.
    nonisolated static func remoteImages(itemId: String, type: String, allLanguages: Bool = false, provider: String? = nil,
                                         language: String = "en") -> Request {
        var path = "/Items/\(p(itemId))/RemoteImages?Type=\(type)&IncludeAllLanguages=\(allLanguages)&Language=\(q(language))"
        if let provider, !provider.isEmpty { path += "&ProviderName=\(q(provider))" }
        return Request(method: "GET", path: path)
    }

    struct RemoteImage: Identifiable, Equatable {
        var id: String { url }
        let url: String
        let thumbnailURL: String?
        let provider: String?
        let width: Int?
        let height: Int?
        let language: String?
        let rating: Double?
        let votes: Int?
        var resolution: String? { if let width, let height, width > 0, height > 0 { return "\(width) × \(height)" }; return nil }
    }

    /// {Images:[{Url, ThumbnailUrl, ProviderName, Width, Height, Language, CommunityRating, VoteCount}], Providers:[…]}
    /// (same shape on Emby and Jellyfin).
    nonisolated static func decodeRemoteImages(_ data: Data) -> (images: [RemoteImage], providers: [String]) {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], []) }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue }
        func dbl(_ v: Any?) -> Double? { (v as? Double) ?? (v as? NSNumber)?.doubleValue }
        var seen = Set<String>()
        let imgs: [RemoteImage] = (d["Images"] as? [[String: Any]] ?? []).compactMap { m in
            guard let u = m["Url"] as? String, !u.isEmpty, seen.insert(u).inserted else { return nil }
            return RemoteImage(url: u, thumbnailURL: (m["ThumbnailUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               provider: m["ProviderName"] as? String, width: int(m["Width"]), height: int(m["Height"]),
                               language: (m["Language"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               rating: dbl(m["CommunityRating"]), votes: int(m["VoteCount"]))
        }
        return (imgs, d["Providers"] as? [String] ?? [])
    }

    /// Preferred language first, then pictures without text (no language), then the rest; the server's order
    /// (rating) is kept inside each group.
    nonisolated static func sortImages(_ images: [RemoteImage], preferred: String = "en") -> [RemoteImage] {
        let pref = preferred.lowercased().split(separator: "-").first.map(String.init) ?? preferred.lowercased()
        func rank(_ i: RemoteImage) -> Int {
            guard let l = i.language?.lowercased(), !l.isEmpty else { return 1 }
            let base = l.split(separator: "-").first.map(String.init) ?? l
            return base == pref ? 0 : 2
        }
        return images.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// The metadata language of the library an item lives in: GET /Library/VirtualFolders entries are matched to
    /// the item's ancestors (GET /Items/{id}/Ancestors) by ItemId. nil = not set (the server default applies).
    nonisolated static func libraryLanguage(folders: Data, ancestors: Data) -> (language: String?, country: String?)? {
        guard let f = (try? JSONSerialization.jsonObject(with: folders)) as? [[String: Any]],
              let a = (try? JSONSerialization.jsonObject(with: ancestors)) as? [[String: Any]] else { return nil }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "-", with: "") }
        let ids = Set(a.compactMap { ($0["Id"] as? String).map(norm) })
        guard let lib = f.first(where: { ($0["ItemId"] as? String).map { ids.contains(norm($0)) } ?? false }) else { return nil }
        let o = lib["LibraryOptions"] as? [String: Any] ?? [:]
        return (nonEmpty(o["PreferredMetadataLanguage"] as? String), nonEmpty(o["MetadataCountryCode"] as? String))
    }

    /// POST /Items/{id}/RemoteImages/Download?Type=…&ImageUrl=…&ProviderName=….
    nonisolated static func download(itemId: String, type: String, image: RemoteImage) -> Request {
        var path = "/Items/\(p(itemId))/RemoteImages/Download?Type=\(type)&ImageUrl=\(q(image.url))"
        if let pr = image.provider, !pr.isEmpty { path += "&ProviderName=\(q(pr))" }
        return Request(method: "POST", path: path)
    }

    /// JPEG or PNG from the file's first bytes (nil = neither: not uploaded).
    nonisolated static func contentType(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(8))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 8, b == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "image/png" }
        return nil
    }

    /// POST /Items/{id}/Images/{type} with the picture as BASE64 text and its own Content-Type. Same path and body
    /// on Emby and Jellyfin (both decode base64, as for the profile picture; Jellyfin keeps this item path on
    /// every version, only the USER image moved to /UserImage in 10.9). A backdrop upload adds one more.
    nonisolated static func upload(itemId: String, type: String, data: Data) -> Request? {
        guard let ct = contentType(data) else { return nil }
        return Request(method: "POST", path: "/Items/\(p(itemId))/Images/\(type)", contentType: ct,
                       body: Data(data.base64EncodedString().utf8))
    }

    // MARK: Items without poster / backdrop

    enum Missing: String { case poster, backdrop
        var title: String { self == .poster ? "Items without poster" : "Items without backdrop" }
        var imageType: String { self == .poster ? "Primary" : "Backdrop" }
    }

    /// One page of the library's movies, shows and collections. Neither server can filter on a MISSING image
    /// (Emby/Jellyfin's ImageTypes only keeps items that HAVE the kind; Emby's HasPrimaryImage isn't on every
    /// version and Jellyfin ignores it), so the list pages through everything and filters here (`isMissing`).
    /// EnableImageTypes keeps the answer small but still carries the tags we check.
    nonisolated static func missingPage(userId: String, libraryId: String, start: Int, limit: Int) -> Request {
        Request(method: "GET", path: "/Users/\(p(userId))/Items?ParentId=\(q(libraryId))&Recursive=true"
            + "&IncludeItemTypes=Movie,Series,BoxSet&Fields=ProductionYear,Path&EnableImageTypes=Primary,Backdrop"
            + "&EnableUserData=false&SortBy=SortName&SortOrder=Ascending&StartIndex=\(start)&Limit=\(limit)")
    }

    struct MissingRow: Identifiable, Equatable {
        let id: String
        let name: String
        let type: String?
        let year: Int?
        let path: String?
    }

    nonisolated static func isMissing(_ item: [String: Any], _ kind: Missing) -> Bool {
        switch kind {
        case .poster: return ((item["ImageTags"] as? [String: Any])?["Primary"] as? String).map { $0.isEmpty } ?? true
        case .backdrop: return (item["BackdropImageTags"] as? [String] ?? []).isEmpty
        }
    }

    /// Rows from one page + the server's total (nil when it doesn't say).
    nonisolated static func decodeMissing(_ data: Data, _ kind: Missing) -> (rows: [MissingRow], pageCount: Int, total: Int?) {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], 0, nil) }
        let items = d["Items"] as? [[String: Any]] ?? []
        let rows = items.filter { isMissing($0, kind) }.compactMap { m -> MissingRow? in
            guard let id = m["Id"] as? String else { return nil }
            return MissingRow(id: id, name: m["Name"] as? String ?? "Untitled", type: m["Type"] as? String,
                              year: (m["ProductionYear"] as? Int) ?? (m["ProductionYear"] as? NSNumber)?.intValue,
                              path: m["Path"] as? String)
        }
        return (rows, items.count, (d["TotalRecordCount"] as? Int) ?? (d["TotalRecordCount"] as? NSNumber)?.intValue)
    }

    // MARK: Refresh progress

    /// What changes on the item when a refresh has run: its refresh date and its image tags.
    nonisolated static func snapshot(_ item: [String: Any]) -> String {
        let date = item["DateLastRefreshed"] as? String ?? ""
        let tags = currentImages(item).sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value.joined(separator: ",") }
        return date + "|" + tags.joined(separator: ";")
    }

    // MARK: Menu + messages

    enum Action: String, CaseIterable { case editMetadata, refresh, identify, images, web, missingPosters, missingBackdrops
        var title: String {
            switch self {
            case .editMetadata: return "Edit metadata…"
            case .refresh: return "Refresh metadata…"
            case .identify: return "Identify…"
            case .images: return "Edit images…"
            case .web: return "Open in web dashboard"
            case .missingPosters: return Missing.poster.title
            case .missingBackdrops: return Missing.backdrop.title
            }
        }
    }

    static let detailTypes: Set<String> = ["Movie", "Series", "Season", "Episode", "BoxSet"]

    /// The ⋯ menu on a detail page: nothing for non-admins (or unknown role) and other item kinds.
    nonisolated static func detailMenu(type: String?, admin: Bool?) -> [Action] {
        guard admin == true, let type, detailTypes.contains(type) else { return [] }
        return searchKind(type) != nil ? [.editMetadata, .refresh, .identify, .images, .web] : [.editMetadata, .refresh, .images, .web]
    }

    /// The ⋯ menu on a library page: only admins, only movie / TV / mixed libraries.
    nonisolated static func libraryMenu(kind: String?, admin: Bool?) -> [Action] {
        guard admin == true else { return [] }
        switch kind ?? "" {
        case "movies", "tvshows", "boxsets", "mixed", "": return [.missingPosters, .missingBackdrops]
        default: return []
        }
    }

    /// The item in the server's own web dashboard. Emby: index.html#!/item?id=…; Jellyfin: #/details?id=….
    nonisolated static func webURL(server: String, itemId: String, jellyfin: Bool, serverId: String? = nil) -> URL? {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        var s = jellyfin ? "\(base)/web/#/details?id=\(q(itemId))" : "\(base)/web/index.html#!/item?id=\(q(itemId))"
        if let serverId, !serverId.isEmpty { s += "&serverId=\(q(serverId))" }
        return URL(string: s)
    }

    /// nil = success; otherwise a plain sentence.
    nonisolated static func message(status: Int, action: String) -> String? {
        switch status {
        case 200..<300: return nil
        case 401: return "Your sign-in has expired. Sign in again and retry."
        case 403: return "The server says you're not allowed to \(action). An administrator account is needed."
        case 404: return "The server couldn't find this item (it may have been removed), or it doesn't support this."
        case 413: return "The picture is too large for the server."
        case 500..<600: return "The server ran into a problem while trying to \(action) (error \(status)). Try again in a moment."
        default: return "Couldn't \(action) (error \(status))."
        }
    }
}
