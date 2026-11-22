import Foundation

// Playback Stats, phase 1 (Playback Reporting plugin: Emby faush01/playback_reporting, Jellyfin
// jellyfin-plugin-playbackreporting). Pure data rules here (tested in StatsTests); the server calls are in
// StatsService.swift, the views in StatsViews.swift / StatsOverview.swift / StatsHistory.swift.

/// One play as the plugin logged it (a row of `user_usage_stats/{userId}/{date}/GetItems`).
struct StatsPlay: Identifiable, Hashable, Sendable {
    let id: String
    let start: Date
    let day: String            // yyyy-MM-dd the row was asked for
    let itemId: String
    let name: String
    let type: String           // Movie, Episode, Audio, …
    let client: String
    let device: String
    let method: String
    let seconds: Int
    var remoteAddress: String = ""   // Emby logs it; Jellyfin's GetItems doesn't send it
    var userId: String = ""          // Insights / Year in review: whose play it is (set by the loader)
    var userName: String = ""

    var isMovie: Bool { type.lowercased() == "movie" }
    var isEpisode: Bool { type.lowercased() == "episode" }
    /// "Series - s1e2 - Title" (how both plugins name episodes) split apart; nil for anything else.
    var episode: StatsEpisodeName? { isEpisode ? StatsEpisodeName.parse(name) : nil }
    var displayTitle: String { episode?.series ?? name }
    var displaySubtitle: String? {
        guard let e = episode else { return nil }
        return "S\(e.season):E\(e.number)" + (e.title.isEmpty ? "" : " · \(e.title)")
    }
}

struct StatsEpisodeName: Equatable, Sendable {
    let series: String, season: Int, number: Int, title: String
    static func parse(_ s: String) -> StatsEpisodeName? {
        guard let r = s.range(of: #" - s(\d+)e(\d+)( - |$)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let series = String(s[..<r.lowerBound])
        let mid = String(s[r]).lowercased()
        let nums = mid.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2, !series.isEmpty else { return nil }
        return StatsEpisodeName(series: series, season: nums[0], number: nums[1], title: String(s[r.upperBound...]))
    }
}

/// The date-range pill.
enum StatsRange: Int, CaseIterable, Identifiable, Sendable {
    case week, month, year, all
    var id: Int { rawValue }
    var label: String { ["7 days", "30 days", "12 months", "All"][rawValue] }
    /// Days asked from the server. "All" is capped (the plugin keeps 3 months by default).
    var days: Int { [7, 30, 365, 1095][rawValue] }
    /// Bars per day for short ranges, per month for long ones.
    var monthlyBars: Bool { self == .year || self == .all }
}

// MARK: - Decoding (tolerant: missing fields, numbers sent as strings)

enum StatsDecode {
    static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
    static func int(_ v: Any?) -> Int {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        default: return 0
        }
    }

    /// "21:05" (Emby) or "9:05 PM" (Jellyfin) on that day; midnight when unreadable.
    static func time(_ s: String, day: String, calendar: Calendar = .current) -> Date? {
        guard let d = dayFormat.date(from: day) else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        let pm = t.hasSuffix("PM"), am = t.hasSuffix("AM")
        let core = t.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = core.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return d }
        var h = parts[0]
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        return calendar.date(bySettingHour: min(h, 23), minute: min(parts[1], 59), second: 0, of: d) ?? d
    }

    /// One day's rows from `GetItems`.
    static func dayPlays(_ data: Data, day: String) -> [StatsPlay] {
        // Jellyfin: a list; Emby: { user_name, user_id, activity: [...] }
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let arr = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["activity"] as? [[String: Any]]) else { return [] }
        return arr.enumerated().compactMap { i, r in
            let itemId = string(r["Id"]), name = string(r["Name"])
            guard !itemId.isEmpty || !name.isEmpty else { return nil }
            let row = string(r["RowId"])
            return StatsPlay(id: row.isEmpty ? "\(day)-\(i)-\(itemId)" : "\(day)-\(row)",
                             start: time(string(r["Time"]), day: day) ?? Date.distantPast, day: day,
                             itemId: itemId, name: name.isEmpty ? "Unknown" : name, type: string(r["Type"]),
                             client: string(r["Client"]), device: string(r["Device"]), method: string(r["Method"]),
                             seconds: int(r["Duration"]), remoteAddress: string(r["RemoteAddress"]))
        }
    }

    /// `PlayActivity`: this user's value per day (count or seconds). Other users and `labels_user` are ignored.
    static func activity(_ data: Data, userId: String) -> [String: Int] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        let want = norm(userId)
        guard let row = arr.first(where: { norm(string($0["user_id"])) == want }),
              let usage = row["user_usage"] as? [String: Any] else { return [:] }
        return usage.mapValues { int($0) }
    }
    /// Ids compared without dashes and case (Jellyfin "N" format vs the dashed form).
    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").lowercased() }

    /// `/Plugins`: whether Playback Reporting is listed (by name, case-insensitive).
    static func pluginListed(_ data: Data) -> Bool {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        return pluginListed(names: arr.map { string($0["Name"]) })
    }
    static func pluginListed(names: [String]) -> Bool {
        names.contains { $0.lowercased().contains("playback reporting") }
    }

    /// `/Users/{id}` (or the signed-in user): Policy.IsAdministrator; nil when the answer doesn't say.
    static func isAdministrator(_ data: Data) -> Bool? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = o["Policy"] as? [String: Any] else { return nil }
        return (p["IsAdministrator"] as? Bool) ?? (p["IsAdministrator"] as? NSNumber)?.boolValue
    }
}

// MARK: - Detection

enum StatsAvailability: Equatable, Sendable {
    case available, notAdmin, pluginMissing, failed
}

enum StatsDetection {
    /// isAdmin: from the user's Policy (nil = unknown). pluginListed: from /Plugins (nil = couldn't read).
    /// probe: HTTP status of `user_usage_stats/type_filter_list` (nil = no answer).
    static func decide(isAdmin: Bool?, pluginListed: Bool?, probe: Int?) -> StatsAvailability {
        if isAdmin == false { return .notAdmin }
        if let p = probe {
            if (200..<300).contains(p) { return .available }
            if p == 401 || p == 403 { return .notAdmin }
            if p == 404 { return .pluginMissing }
        }
        if pluginListed == false { return .pluginMissing }
        return .failed
    }
}

// MARK: - Aggregation

struct StatsTop: Identifiable, Hashable, Sendable {
    let id: String          // item id (movie) or series name (show)
    let title: String
    let itemId: String      // the item to open / show (a show: one of its episodes until resolved)
    let seconds: Int
    let plays: Int
}

/// A Recently watched card: a movie, or a series (its latest episode as "S2:E4").
struct StatsRecent: Identifiable, Hashable, Sendable {
    let top: StatsTop
    let show: Bool
    let caption: String
    var id: String { top.id }
}

struct StatsBar: Identifiable, Hashable, Sendable {
    let id: String, label: String, seconds: Int
}

struct StatsDayGroup: Identifiable, Hashable, Sendable {
    let id: String          // yyyy-MM-dd
    let date: Date
    let plays: [StatsPlay]
}

enum StatsAggregate {
    /// Plays shorter than this are trailers, scrubbing or false starts (Jellyfin has no filter of its own).
    static let minSeconds = 60

    static func filtered(_ plays: [StatsPlay]) -> [StatsPlay] { plays.filter { $0.seconds >= minSeconds } }

    /// The days of a range ending today, oldest first.
    static func days(_ range: StatsRange, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let today = calendar.startOfDay(for: now)
        return (0..<range.days).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today).map { StatsDecode.dayFormat.string(from: $0) }
        }
    }

    /// Plays inside the range (by their day).
    static func inRange(_ plays: [StatsPlay], _ range: StatsRange, now: Date = Date(), calendar: Calendar = .current) -> [StatsPlay] {
        let set = Set(days(range, now: now, calendar: calendar))
        return plays.filter { set.contains($0.day) }
    }

    static func totalSeconds(_ plays: [StatsPlay]) -> Int { plays.reduce(0) { $0 + $1.seconds } }

    /// "12.5 h", "45 min".
    static func hoursText(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(seconds / 60) min" }
        let h = Double(seconds) / 3600
        return h >= 100 ? "\(Int(h.rounded())) h" : String(format: "%.1f h", h)
    }
    /// "1:42" / "42 min" for a single play.
    static func durationText(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d h", seconds / 3600, (seconds % 3600) / 60) : "\(max(1, seconds / 60)) min"
    }

    static func topMovies(_ plays: [StatsPlay], limit: Int = 5) -> [StatsTop] {
        let g = Dictionary(grouping: plays.filter(\.isMovie), by: \.itemId)
        return g.map { id, ps in StatsTop(id: id, title: ps[0].name, itemId: id, seconds: totalSeconds(ps), plays: ps.count) }
            .sorted { ($0.seconds, $1.title) > ($1.seconds, $0.title) }.prefix(limit).map { $0 }
    }

    /// The last `limit` distinct titles, newest first: movies by item, episodes collapsed to their series.
    /// Other types (music, …) are left out, as in the Top lists.
    static func recentlyWatched(_ plays: [StatsPlay], limit: Int = 10) -> [StatsRecent] {
        var seen = Set<String>(), out: [StatsRecent] = []
        for p in plays.sorted(by: { $0.start > $1.start }) where p.isMovie || p.isEpisode {
            let key = p.isEpisode ? "s:" + p.displayTitle : "i:" + p.itemId
            guard seen.insert(key).inserted else { continue }
            let ps = plays.filter { ($0.isEpisode ? "s:" + $0.displayTitle : "i:" + $0.itemId) == key }
            let top = StatsTop(id: key, title: p.displayTitle, itemId: p.itemId, seconds: totalSeconds(ps), plays: ps.count)
            let caption: String
            if p.isEpisode, let e = p.episode { caption = "S\(e.season):E\(e.number)" }
            else { caption = durationText(p.seconds) }
            out.append(StatsRecent(top: top, show: p.isEpisode, caption: caption))
            if out.count == limit { break }
        }
        return out
    }

    static func topShows(_ plays: [StatsPlay], limit: Int = 5) -> [StatsTop] {
        let g = Dictionary(grouping: plays.filter(\.isEpisode), by: { $0.displayTitle })
        return g.map { name, ps in
            let latest = ps.max { $0.start < $1.start } ?? ps[0]
            return StatsTop(id: name, title: name, itemId: latest.itemId, seconds: totalSeconds(ps), plays: ps.count)
        }
        .sorted { ($0.seconds, $1.title) > ($1.seconds, $0.title) }.prefix(limit).map { $0 }
    }

    /// Bars: one per day (7 / 30 days) or per month (12 months / all).
    static func bars(_ plays: [StatsPlay], _ range: StatsRange, now: Date = Date(), calendar: Calendar = .current) -> [StatsBar] {
        let ds = days(range, now: now, calendar: calendar)
        let byDay = Dictionary(grouping: plays, by: \.day).mapValues(totalSeconds)
        let lf = DateFormatter(); lf.calendar = calendar
        if !range.monthlyBars {
            lf.dateFormat = range == .week ? "EEE" : "d"
            return ds.map { d in
                StatsBar(id: d, label: StatsDecode.dayFormat.date(from: d).map { lf.string(from: $0) } ?? d, seconds: byDay[d] ?? 0)
            }
        }
        lf.dateFormat = "MMM"
        var order: [String] = [], sums: [String: Int] = [:], labels: [String: String] = [:]
        for d in ds {
            let m = String(d.prefix(7))
            if sums[m] == nil { order.append(m); sums[m] = 0; labels[m] = StatsDecode.dayFormat.date(from: d).map { lf.string(from: $0) } ?? m }
            sums[m]! += byDay[d] ?? 0
        }
        // "All": start at the first month with data
        if range == .all, let first = order.firstIndex(where: { (sums[$0] ?? 0) > 0 }) { order = Array(order[first...]) }
        return order.map { StatsBar(id: $0, label: labels[$0] ?? $0, seconds: sums[$0] ?? 0) }
    }

    /// History: grouped by day, newest day first, newest play first inside a day.
    static func groupByDay(_ plays: [StatsPlay]) -> [StatsDayGroup] {
        Dictionary(grouping: plays, by: \.day).compactMap { day, ps in
            guard let d = StatsDecode.dayFormat.date(from: day) else { return nil }
            return StatsDayGroup(id: day, date: d, plays: ps.sorted { $0.start > $1.start })
        }.sorted { $0.id > $1.id }
    }

    /// Few plays in the range: the friendly "Data is collected from now on" note.
    static func isFewData(_ plays: [StatsPlay]) -> Bool { plays.count < 3 }

    /// Days with any activity, newest first (from PlayActivity), to fetch only those.
    static func activeDays(_ usage: [String: Int]) -> [String] {
        usage.filter { $0.value > 0 }.keys.sorted(by: >)
    }

    /// "DirectPlay" → "Direct play"; Jellyfin's "Transcode (v:h264 a:aac)" → "Transcode (v:h264 a:aac)".
    static func methodText(_ m: String) -> String {
        let l = m.lowercased()
        if l.hasPrefix("directplay") { return "Direct play" }
        if l.hasPrefix("directstream") { return "Direct stream" }
        return m.isEmpty ? "—" : m
    }
}
