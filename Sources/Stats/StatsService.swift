import Foundation

/// One HTTP GET against the signed-in server: (body, status), nil when there was no answer (offline, timeout).
typealias StatsFetch = @Sendable (_ path: String, _ query: [String: String]) async -> (data: Data, status: Int)?

enum StatsError: Error { case noAnswer, status(Int) }

/// The Playback Reporting endpoints phase 1 uses, with the Emby / Jellyfin parameter differences hidden
/// (Emby: snake_case `end_date`, `data_type`; Jellyfin: camelCase `endDate`, `dataType`, plus `timezoneOffset`).
/// Read-only routes only; never the plugin's custom SQL or user_manage / backup routes.
protocol StatsService: Sendable {
    var fetch: StatsFetch { get }
    /// Query for `user_usage_stats/PlayActivity`.
    func activityQuery(days: Int, end: String, dataType: String) -> [String: String]
    /// Query for `user_usage_stats/{userId}/{date}/GetItems`.
    func dayQuery() -> [String: String]
}

extension StatsService {
    static var base: String { "/user_usage_stats" }

    /// Seconds (or counts) per day for this user, `days` days ending `end`.
    func activity(userId: String, days: Int, end: Date = Date(), dataType: String = "time") async throws -> [String: Int] {
        let q = activityQuery(days: days, end: StatsDecode.dayFormat.string(from: end), dataType: dataType)
        let d = try await get("\(Self.base)/PlayActivity", q)
        return StatsDecode.activity(d, userId: userId)
    }

    /// That day's plays for this user, plays under 60 s dropped.
    func dayPlays(userId: String, day: String) async throws -> [StatsPlay] {
        let d = try await get("\(Self.base)/\(userId)/\(day)/GetItems", dayQuery())
        return StatsAggregate.filtered(StatsDecode.dayPlays(d, day: day))
    }

    /// Many days, at most 4 requests at a time; a day that fails is skipped.
    func plays(userId: String, days: [String]) async -> [StatsPlay] {
        var out: [StatsPlay] = []
        var i = 0
        while i < days.count {
            let chunk = Array(days[i..<min(i + 4, days.count)])
            await withTaskGroup(of: [StatsPlay].self) { g in
                for d in chunk { g.addTask { (try? await self.dayPlays(userId: userId, day: d)) ?? [] } }
                for await r in g { out += r }
            }
            i += 4
            if Task.isCancelled { break }
        }
        return out
    }

    private func get(_ path: String, _ q: [String: String]) async throws -> Data {
        guard let r = await fetch(path, q) else { throw StatsError.noAnswer }
        guard (200..<300).contains(r.status) else { throw StatsError.status(r.status) }
        return r.data
    }
}

struct EmbyStatsService: StatsService {
    let fetch: StatsFetch
    func activityQuery(days: Int, end: String, dataType: String) -> [String: String] {
        ["days": String(days), "end_date": end, "data_type": dataType]
    }
    func dayQuery() -> [String: String] { [:] }
}

struct JellyfinStatsService: StatsService {
    let fetch: StatsFetch
    /// Hours east of UTC (what jellyfin-web sends), so days and times are local.
    var timezoneOffset: Double = Double(TimeZone.current.secondsFromGMT()) / 3600
    var tz: String { String(format: "%g", timezoneOffset) }
    func activityQuery(days: Int, end: String, dataType: String) -> [String: String] {
        ["days": String(days), "endDate": end, "dataType": dataType, "timezoneOffset": tz]
    }
    func dayQuery() -> [String: String] { ["timezoneOffset": tz] }
}

enum StatsServices {
    static func make(isJellyfin: Bool, fetch: @escaping StatsFetch) -> any StatsService {
        isJellyfin ? JellyfinStatsService(fetch: fetch) : EmbyStatsService(fetch: fetch)
    }

    /// Admin check + plugin detection (plugin list name match, then a cheap probe).
    static func detect(userId: String, fetch: StatsFetch) async -> StatsAvailability {
        var isAdmin: Bool?
        if let r = await fetch("/Users/\(userId)", [:]), (200..<300).contains(r.status) {
            isAdmin = StatsDecode.isAdministrator(r.data)
        }
        if isAdmin == false { return .notAdmin }
        var listed: Bool?
        if let r = await fetch("/Plugins", [:]), (200..<300).contains(r.status) { listed = StatsDecode.pluginListed(r.data) }
        let probe = await fetch("/user_usage_stats/type_filter_list", [:])?.status
        return StatsDetection.decide(isAdmin: isAdmin, pluginListed: listed, probe: probe)
    }
}

extension Emby {
    /// A GET for the Stats page: the signed-in token in the headers, a 15 s timeout, (body, status).
    func statsFetcher() -> StatsFetch {
        let server = self.server
        var auth = URLRequest(url: URL(string: "http://localhost")!)
        authorize(&auth)
        let headers = auth.allHTTPHeaderFields ?? [:]
        return { path, q in
            guard var c = URLComponents(string: server + path) else { return nil }
            if !q.isEmpty { c.queryItems = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
            guard let u = c.url else { return nil }
            var r = URLRequest(url: u, timeoutInterval: 15)
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            do {
                let (d, resp) = try await Net.session.data(for: r)
                return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                if !(error is CancellationError) { coveLog.error("Stats GET \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
                return nil
            }
        }
    }

    /// Non-admin fallback: recently played movies and episodes from the normal API (no plugin needed).
    func recentlyPlayed(limit: Int = 60) async -> [Item] {
        let r: ItemList? = try? await get("/Users/\(userId)/Items", ["Filters": "IsPlayed", "Recursive": "true",
            "IncludeItemTypes": "Movie,Episode", "SortBy": "DatePlayed", "SortOrder": "Descending",
            "Limit": String(limit), "Fields": "RunTimeTicks,UserData"])
        return r?.Items ?? []
    }
}

/// Detection results per server + user for this app session (re-probed after a switch: a new key).
@MainActor
enum StatsAvailabilityCache {
    static var results: [String: StatsAvailability] = [:]
    static func key(server: String, userId: String) -> String { server.lowercased() + "|" + userId }
}
