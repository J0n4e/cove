import Foundation

// Detail page → Watch activity (admins only, Emby and Jellyfin): which of the server's users watched an item, how
// far each got, when they last played it, play counts and favourites. Data: GET /Users, then per user
// GET /Users/{uid}/Items?Ids={id} (UserData, DateCreated, RecursiveItemCount), at most 6 at once, cached 60 s per
// item (WatchActivityStore). Pure rules here, tested in Tests/WatchActivityTests.swift; view in
// Classic/Glass3DWatchActivity.swift.

struct WatchActivityUser: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let imageTag: String?
    let disabled: Bool
}

/// One user's state for the item (from that user's /Items answer).
struct WatchActivityEntry: Identifiable, Equatable, Sendable {
    let user: WatchActivityUser
    var played = false
    var playCount = 0
    var positionTicks: Int64 = 0
    var playedPercentage: Double?
    var unplayed: Int?
    var recursive: Int?
    var lastPlayed: Date?
    var favorite = false
    var runtimeTicks: Int64?
    var id: String { user.id }
}

enum WatchActivityState: Equatable {
    case watched
    /// 0…1 and what's left ("1:12:04 left" / "6 episodes left")
    case progress(Double, String?)
    case notStarted
}

struct WatchActivitySummary: Equatable {
    let watched: Int
    let total: Int
    let favourites: Int
    let lastPlayed: Date?
    let lastPlayedBy: String?
    var text: String { "\(watched)/\(total) watched" }
    var favouritesText: String? { favourites == 0 ? nil : "♥ \(favourites) favourite" + (favourites == 1 ? "" : "s") }
}

enum WatchActivity {
    nonisolated static let maxConcurrent = 6
    nonisolated static let cacheSeconds: TimeInterval = 60
    nonisolated static let maxAvatars = 5

    /// Series, seasons, collections and other folders: watched/progress come from the unplayed count.
    nonisolated static func isFolder(_ type: String?) -> Bool {
        ["Series", "Season", "BoxSet", "Folder", "CollectionFolder", "Playlist"].contains(type ?? "")
    }

    /// "1:12:04" / "12:04".
    nonisolated static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    nonisolated static func state(_ e: WatchActivityEntry, folder: Bool) -> WatchActivityState {
        if folder {
            if e.played { return .watched }
            if let r = e.recursive, r > 0, let u = e.unplayed {
                if u == 0 { return .watched }
                let f = (e.playedPercentage.map { $0 / 100 }).flatMap { $0 > 0 ? $0 : nil } ?? (1 - Double(u) / Double(r))
                guard f > 0 else { return .notStarted }
                return .progress(min(max(f, 0), 0.999), "\(u) left")
            }
            if let p = e.playedPercentage, p > 0 { return .progress(min(p / 100, 0.999), nil) }
            return .notStarted
        }
        if e.played { return .watched }
        guard e.positionTicks > 0 else { return .notStarted }
        let rt = Double(e.runtimeTicks ?? 0)
        let f = e.playedPercentage.map { $0 / 100 } ?? (rt > 0 ? Double(e.positionTicks) / rt : 0)
        let left = rt > 0 ? clock((rt - Double(e.positionTicks)) / 10_000_000) + " left" : nil
        return .progress(min(max(f, 0.001), 0.999), left)
    }

    /// "42% · 1:12:04 left" / "Watched" / "Not started".
    nonisolated static func stateText(_ s: WatchActivityState) -> String {
        switch s {
        case .watched: return "Watched"
        case .notStarted: return "Not started"
        case .progress(let f, let left):
            let pct = "\(Int((f * 100).rounded(.down)))%"
            return left.map { pct + " · " + $0 } ?? pct
        }
    }

    /// Counts over users that are enabled (disabled ones are listed dimmed, not counted).
    nonisolated static func summary(_ entries: [WatchActivityEntry], folder: Bool) -> WatchActivitySummary {
        let counted = entries.filter { !$0.user.disabled }
        let watched = counted.filter { state($0, folder: folder) == .watched }.count
        let last = entries.filter { $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! }
        return WatchActivitySummary(watched: watched, total: counted.count, favourites: entries.filter(\.favorite).count,
                                    lastPlayed: last?.lastPlayed, lastPlayedBy: last?.user.name)
    }

    /// The list order: watched, then in progress (furthest first), then not started; enabled before disabled;
    /// then by name.
    nonisolated static func sorted(_ entries: [WatchActivityEntry], folder: Bool) -> [WatchActivityEntry] {
        func rank(_ e: WatchActivityEntry) -> (Int, Double) {
            switch state(e, folder: folder) {
            case .watched: return (0, 0)
            case .progress(let f, _): return (1, -f)
            case .notStarted: return (2, 0)
            }
        }
        return entries.sorted { a, b in
            if a.user.disabled != b.user.disabled { return !a.user.disabled }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.user.name.localizedCaseInsensitiveCompare(b.user.name) == .orderedAscending
        }
    }

    /// Avatars in the pill: who watched (or started) it first, at most 5, plus "+N".
    nonisolated static func avatars(_ entries: [WatchActivityEntry], folder: Bool) -> (shown: [WatchActivityUser], more: Int) {
        let active = sorted(entries, folder: folder).filter { state($0, folder: folder) != .notStarted && !$0.user.disabled }
        return (active.prefix(maxAvatars).map(\.user), max(0, active.count - maxAvatars))
    }

    // MARK: Decoding

    nonisolated static func bool(_ v: Any?) -> Bool? { (v as? Bool) ?? (v as? NSNumber)?.boolValue }

    /// GET /Users → users (both servers: a plain array).
    nonisolated static func users(_ data: Data) -> [WatchActivityUser] {
        let j = try? JSONSerialization.jsonObject(with: data)
        guard let a = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["Items"] as? [[String: Any]]) else { return [] }
        return a.compactMap { o in
            guard let id = o["Id"] as? String, !id.isEmpty else { return nil }
            let p = o["Policy"] as? [String: Any] ?? [:]
            let tag = (o["PrimaryImageTag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WatchActivityUser(id: id, name: (o["Name"] as? String) ?? "", imageTag: tag,
                                     disabled: bool(p["IsDisabled"]) ?? false)
        }
    }

    /// GET /Users/{uid}/Items?Ids=… → the user's entry; nil when the user can't see the item.
    /// Also returns the item's DateCreated.
    nonisolated static func entry(_ data: Data, user: WatchActivityUser) -> (WatchActivityEntry, Date?)? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let item = (o["Items"] as? [[String: Any]])?.first ?? (o["Id"] != nil ? o : nil)
        guard let item else { return nil }
        let ud = item["UserData"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue }
        func int64(_ v: Any?) -> Int64? { (v as? Int64) ?? (v as? NSNumber)?.int64Value }
        var e = WatchActivityEntry(user: user)
        e.played = bool(ud["Played"]) ?? false
        e.playCount = int(ud["PlayCount"]) ?? 0
        e.positionTicks = int64(ud["PlaybackPositionTicks"]) ?? 0
        e.playedPercentage = (ud["PlayedPercentage"] as? NSNumber)?.doubleValue
        e.unplayed = int(ud["UnplayedItemCount"])
        e.recursive = int(item["RecursiveItemCount"]) ?? int(item["ChildCount"])
        e.lastPlayed = (ud["LastPlayedDate"] as? String).flatMap(isoDate)
        e.favorite = bool(ud["IsFavorite"]) ?? false
        e.runtimeTicks = int64(item["RunTimeTicks"])
        return (e, (item["DateCreated"] as? String).flatMap(isoDate))
    }

    /// Emby/Jellyfin dates ("2026-11-14T00:01:02.1234567Z", with or without fractions).
    nonisolated static func isoDate(_ s: String) -> Date? {
        guard !s.isEmpty, !s.hasPrefix("0001") else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // 7-digit fractions: cut to milliseconds
        if let dot = s.firstIndex(of: ".") {
            let tail = s[s.index(after: dot)...]
            let digits = tail.prefix { $0.isNumber }
            let rest = tail.dropFirst(digits.count)
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: String(s[..<dot]) + "." + String(digits.prefix(3)) + (rest.isEmpty ? "Z" : String(rest)))
        }
        return nil
    }
}

/// The loaded activity for one item.
struct WatchActivityData: Equatable {
    var entries: [WatchActivityEntry]
    var dateAdded: Date?
    var loadedAt: Date
}

/// Loads and caches (60 s per item) the activity of every user.
@MainActor
final class WatchActivityStore: ObservableObject {
    static let shared = WatchActivityStore()
    @Published private(set) var data: [String: WatchActivityData] = [:]
    private var running: [String: Task<Void, Never>] = [:]

    func key(_ emby: Emby, _ itemId: String) -> String { emby.server.lowercased() + "|" + itemId }

    func load(_ emby: Emby, itemId: String, force: Bool = false) async {
        let k = key(emby, itemId)
        if !force, let d = data[k], Date().timeIntervalSince(d.loadedAt) < WatchActivity.cacheSeconds { return }
        if let t = running[k] { await t.value; return }
        let server = emby.server
        func request(_ path: String) -> URLRequest? {
            guard let u = URL(string: server + path) else { return nil }
            var r = URLRequest(url: u, timeoutInterval: 15)
            emby.authorize(&r)
            return r
        }
        guard let ur = request("/Users") else { return }
        let fields = "DateCreated,RecursiveItemCount,ChildCount"
        let t = Task { [weak self] in
            guard let (ud, resp) = try? await Net.session.data(for: ur), (resp as? HTTPURLResponse)?.statusCode == 200 else {
                DebugLog.write("watch activity: /Users failed"); return
            }
            let users = WatchActivity.users(ud)
            var reqs: [(WatchActivityUser, URLRequest)] = []
            for u in users {
                if let r = request("/Users/\(u.id)/Items?Ids=\(itemId)&Fields=\(fields)&EnableImages=false&EnableTotalRecordCount=false") {
                    reqs.append((u, r))
                }
            }
            var entries: [WatchActivityEntry] = []
            var added: Date?
            await withTaskGroup(of: (WatchActivityEntry, Date?)?.self) { g in
                var i = 0
                func next() {
                    guard i < reqs.count else { return }
                    let (u, r) = reqs[i]; i += 1
                    g.addTask {
                        guard let (d, resp) = try? await Net.session.data(for: r),
                              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                        return WatchActivity.entry(d, user: u)
                    }
                }
                for _ in 0..<WatchActivity.maxConcurrent { next() }
                while let r = await g.next() {
                    if let (e, d) = r { entries.append(e); if added == nil { added = d } }
                    next()
                }
            }
            guard let self else { return }
            self.data[k] = WatchActivityData(entries: entries, dateAdded: added, loadedAt: Date())
            DebugLog.write("watch activity: \(entries.count) of \(users.count) users see the item")
        }
        running[k] = t
        await t.value
        running[k] = nil
    }
}
