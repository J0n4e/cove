import Foundation

// Server management, phase 2: Libraries. GET /Library/VirtualFolders and the dashboard's library actions.
// Emby and Jellyfin share the endpoints; the differences (marked below) are handled per `ServerAdminKind`.
// Gaps: no "last scan" date (neither server reports one per library; only RefreshStatus / RefreshProgress while
// a scan runs), and library options (metadata language, realtime monitoring) are not edited here.

struct AdminLibrary: Identifiable, Equatable {
    var id: String { itemId.isEmpty ? name : itemId }
    let name: String
    let itemId: String
    /// movies, tvshows, music, homevideos, boxsets, … ; nil = mixed.
    let collectionType: String?
    let paths: [String]
    let metadataLanguage: String?
    let countryCode: String?
    /// "Active" while scanning (Jellyfin RefreshStatus; Emby sends it too on recent versions).
    let refreshing: Bool
    let refreshProgress: Double?

    var typeTitle: String { LibraryAdminAPI.typeTitle(collectionType) }
    var icon: String { LibraryAdminAPI.icon(collectionType) }

    static func decodeList(_ data: Data) -> [AdminLibrary]? {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return a.compactMap { o in
            guard let name = o["Name"] as? String else { return nil }
            let opts = o["LibraryOptions"] as? [String: Any] ?? [:]
            var paths = (o["Locations"] as? [String]) ?? []
            if paths.isEmpty {   // older Emby: only LibraryOptions.PathInfos
                paths = ((opts["PathInfos"] as? [[String: Any]]) ?? []).compactMap { $0["Path"] as? String }
            }
            let ct = (o["CollectionType"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            let status = ((o["RefreshStatus"] as? String) ?? "").lowercased()
            return AdminLibrary(name: name, itemId: (o["ItemId"] as? String) ?? (o["Id"] as? String) ?? "",
                                collectionType: ct, paths: paths,
                                metadataLanguage: ItemAdminAPI.nonEmpty(opts["PreferredMetadataLanguage"] as? String),
                                countryCode: ItemAdminAPI.nonEmpty(opts["MetadataCountryCode"] as? String),
                                refreshing: status == "active" || status == "running",
                                refreshProgress: (o["RefreshProgress"] as? NSNumber)?.doubleValue)
        }
    }
}

enum LibraryAdminAPI {
    /// The "Add library" choices (title, collectionType; nil = mixed, sent without collectionType).
    static let addTypes: [(title: String, type: String?)] = [
        ("Movies", "movies"), ("TV Shows", "tvshows"), ("Music", "music"), ("Mixed movies and shows", nil), ("Home videos", "homevideos"),
    ]

    static func typeTitle(_ t: String?) -> String {
        switch t {
        case "movies": return "Movies"
        case "tvshows": return "TV Shows"
        case "music": return "Music"
        case "musicvideos": return "Music videos"
        case "homevideos": return "Home videos"
        case "boxsets": return "Collections"
        case "books": return "Books"
        case "playlists": return "Playlists"
        case "livetv": return "Live TV"
        case nil: return "Mixed"
        default: return t!.capitalized
        }
    }

    static func icon(_ t: String?) -> String {
        switch t {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "musicvideos": return "music.note.tv"
        case "homevideos": return "video"
        case "boxsets": return "square.stack"
        case "books": return "book"
        default: return "folder"
        }
    }

    static let list = AdminRequest(method: "GET", path: "/Library/VirtualFolders")

    /// The count shown on a card: movies / shows / albums, else the top-level items.
    static func count(userId: String, libraryId: String, type: String?) -> AdminRequest {
        let kinds: String? = ["movies": "Movie", "tvshows": "Series", "music": "MusicAlbum", "musicvideos": "MusicVideo",
                              "boxsets": "BoxSet", "books": "Book"][type ?? ""]
        var p = "/Users/\(AdminQuery.q(userId))/Items?ParentId=\(AdminQuery.q(libraryId))&Limit=0&EnableTotalRecordCount=true"
        p += kinds.map { "&Recursive=true&IncludeItemTypes=\($0)" } ?? "&Recursive=false"
        return AdminRequest(method: "GET", path: p)
    }
    static func decodeCount(_ data: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["TotalRecordCount"].flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// Scan = the dashboards' "Scan library": POST /Items/{ItemId}/Refresh with Default modes, recursive.
    static func scan(_ lib: AdminLibrary) -> AdminRequest {
        AdminRequest(method: "POST", path: ItemAdminAPI.refresh(itemId: lib.itemId, mode: .scan, replaceImages: false).path)
    }

    /// POST /Library/VirtualFolders/Paths?refreshLibrary=true. Jellyfin's AddMediaPathDto reads {Name, PathInfo:{Path}}
    /// (Path is the legacy field); Emby reads {Name, Path} or PathInfo. Both are sent.
    static func addPath(library: String, path: String) -> AdminRequest {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return .json("POST", "/Library/VirtualFolders/Paths?refreshLibrary=true", ["Name": library, "Path": p, "PathInfo": ["Path": p]])
    }

    static func removePath(library: String, path: String) -> AdminRequest {
        AdminRequest(method: "DELETE", path: "/Library/VirtualFolders/Paths?name=\(AdminQuery.q(library))&path=\(AdminQuery.q(path))&refreshLibrary=true")
    }

    static func rename(_ name: String, to new: String) -> AdminRequest {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        return AdminRequest(method: "POST", path: "/Library/VirtualFolders/Name?name=\(AdminQuery.q(name))&newName=\(AdminQuery.q(n))&refreshLibrary=true")
    }

    /// POST /Library/VirtualFolders?name=…&collectionType=…&refreshLibrary=true&paths=… with
    /// {LibraryOptions:{PreferredMetadataLanguage, MetadataCountryCode, …}}. Mixed = no collectionType (both servers).
    /// Jellyfin needs the body (an empty one is a 400 on 10.9+), Emby reads the same LibraryOptions; Jellyfin also
    /// wants the folder in LibraryOptions.PathInfos, which Emby accepts too, and the `paths` query replaces it on both.
    static func addLibrary(name: String, type: String?, path: String, language: String = "en", country: String = "US",
                           kind: ServerAdminKind) -> AdminRequest {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var q = "/Library/VirtualFolders?name=\(AdminQuery.q(n))"
        if let type { q += "&collectionType=\(type)" }
        q += "&refreshLibrary=true"
        if !p.isEmpty { q += "&paths=\(AdminQuery.q(p))" }
        var opts: [String: Any] = ["PreferredMetadataLanguage": language, "MetadataCountryCode": country,
                                   "EnableRealtimeMonitor": true]
        if !p.isEmpty { opts["PathInfos"] = [["Path": p]] }
        if kind == .jellyfin { opts["EnableInternetProviders"] = true }
        return .json("POST", q, ["LibraryOptions": opts])
    }

    static func delete(_ name: String) -> AdminRequest {
        AdminRequest(method: "DELETE", path: "/Library/VirtualFolders?name=\(AdminQuery.q(name))&refreshLibrary=true")
    }

    /// For the refresh dialog / missing-poster list, which take Cove's own Item / LibPref.
    static func item(_ lib: AdminLibrary) -> Item? {
        let o: [String: Any] = ["Id": lib.itemId, "Name": lib.name, "Type": "CollectionFolder"]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: d)
    }
    static func libPref(_ lib: AdminLibrary) -> LibPref {
        LibPref(id: lib.itemId, name: lib.name, title: lib.name, kind: lib.collectionType)
    }
    /// The #247 poster/backdrop lists only make sense for movies / shows / collections / mixed.
    static func offersMissing(_ lib: AdminLibrary) -> Bool { !ItemAdminAPI.libraryMenu(kind: lib.collectionType, admin: true).isEmpty }

    static func validName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.contains("/") && !t.contains("\\")
    }
}
