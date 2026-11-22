import Foundation

// Activity → Insights and Year in review. Pure rules over arrays of plays (tested in InsightsTests); the loading
// is in InsightsModel.swift, the views in InsightsView.swift / YearReviewView.swift. Plays come from the same
// per-user, per-day loader as the Users tab (StatsModel.cachedUserPlays), tagged with the user they belong to.

/// One slot (weekday 0 = Monday … 6 = Sunday, or hour 0…23) with its watch time.
struct InsightsSlot: Hashable, Sendable {
    let index: Int
    let seconds: Int
}

/// A labelled amount (genres, devices).
struct InsightsCount: Identifiable, Hashable, Sendable {
    let label: String
    let seconds: Int
    let plays: Int
    var id: String { label }
}

/// The most episodes of one show one user played on one day.
struct InsightsBinge: Hashable, Sendable {
    let series: String
    let user: String
    let day: String          // yyyy-MM-dd
    let episodes: Int
    let seconds: Int
    let itemId: String       // one of the episodes (opens / shows the series)
}

/// Movies and episodes in this period and the one before it.
struct InsightsTrend: Hashable, Sendable {
    let movies: Int, episodes: Int
    let prevMovies: Int, prevEpisodes: Int
    let hasPrevious: Bool
    var moviesChange: Int? { hasPrevious ? Insights.change(movies, prevMovies) : nil }
    var episodesChange: Int? { hasPrevious ? Insights.change(episodes, prevEpisodes) : nil }
}

/// Plays of items the user had played before vs first-time plays.
struct InsightsSplit: Hashable, Sendable {
    let new: Int
    let rewatch: Int
    var total: Int { new + rewatch }
    var newPercent: Int { total > 0 ? Int((Double(new) / Double(total) * 100).rounded()) : 0 }
}

/// The title the most users watched.
struct InsightsPopular: Hashable, Sendable {
    let title: String
    let itemId: String
    let show: Bool
    let plays: Int
    let users: [String]
}

/// Everything the Insights tab shows, computed once per load off the main thread.
struct InsightsData: Hashable, Sendable {
    let count: Int
    let weekdays: [Int]              // 7 values (Mon…Sun), seconds
    let hours: [Int]                 // 24 values, seconds
    let busiestDay: InsightsSlot?
    let busiestHour: InsightsSlot?
    let binge: InsightsBinge?
    let longest: StatsPlay?
    let genres: [InsightsCount]
    let trend: InsightsTrend
    let split: InsightsSplit
    let popular: InsightsPopular?
    let quiet: [String]
    let finish: InsightsFinish?
}

/// Movies watched in more than one sitting: the average first start → end of the last play.
struct InsightsFinish: Hashable, Sendable {
    let seconds: Int
    let movies: Int
}

enum Insights {
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]

    /// Same title: a movie by item, an episode by its series.
    static func titleKey(_ p: StatsPlay) -> String { p.isEpisode ? "s:" + p.displayTitle : "i:" + p.itemId }

    private static func known(_ plays: [StatsPlay]) -> [StatsPlay] { plays.filter { $0.start != .distantPast } }

    /// Watch time per weekday, Monday first.
    static func weekdaySeconds(_ plays: [StatsPlay], calendar: Calendar = .current) -> [Int] {
        var out = Array(repeating: 0, count: 7)
        for p in known(plays) { out[(calendar.component(.weekday, from: p.start) + 5) % 7] += p.seconds }
        return out
    }

    /// Watch time per starting hour.
    static func hourSeconds(_ plays: [StatsPlay], calendar: Calendar = .current) -> [Int] {
        var out = Array(repeating: 0, count: 24)
        for p in known(plays) { out[calendar.component(.hour, from: p.start)] += p.seconds }
        return out
    }

    /// The slot with the most watch time (ties: the earlier one); nil when everything is zero.
    static func busiest(_ values: [Int]) -> InsightsSlot? {
        guard let m = values.max(), m > 0, let i = values.firstIndex(of: m) else { return nil }
        return InsightsSlot(index: i, seconds: m)
    }

    /// Most distinct episodes of one series by one user on one day (ties: the later day, then the series name).
    static func binge(_ plays: [StatsPlay]) -> InsightsBinge? {
        let eps = plays.filter(\.isEpisode)
        let g = Dictionary(grouping: eps) { $0.userId + "|" + $0.day + "|" + $0.displayTitle }
        let best = g.values.map { ps -> InsightsBinge in
            InsightsBinge(series: ps[0].displayTitle, user: ps[0].userName, day: ps[0].day,
                          episodes: Set(ps.map(\.itemId)).count, seconds: StatsAggregate.totalSeconds(ps),
                          itemId: ps.max { $0.start < $1.start }?.itemId ?? ps[0].itemId)
        }
        .max { a, b in
            if a.episodes != b.episodes { return a.episodes < b.episodes }
            if a.day != b.day { return a.day < b.day }
            return a.series > b.series
        }
        guard let best, best.episodes >= 2 else { return nil }
        return best
    }

    /// The single longest play (ties: the later one).
    static func longestSession(_ plays: [StatsPlay]) -> StatsPlay? {
        plays.max { ($0.seconds, $0.start) < ($1.seconds, $1.start) }
    }

    /// Top genres by watch time. `genres`: item id → its genres (an episode carries its series' genres).
    static func topGenres(_ plays: [StatsPlay], genres: [String: [String]], limit: Int = 5) -> [InsightsCount] {
        var s: [String: Int] = [:], n: [String: Int] = [:]
        for p in plays {
            for g in Set(genres[p.itemId] ?? []) where !g.isEmpty { s[g, default: 0] += p.seconds; n[g, default: 0] += 1 }
        }
        return s.map { InsightsCount(label: $0.key, seconds: $0.value, plays: n[$0.key] ?? 0) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
            .prefix(limit).map { $0 }
    }

    /// +/- percent from `previous` to `current`; nil when there was nothing before.
    static func change(_ current: Int, _ previous: Int) -> Int? {
        guard previous > 0 else { return nil }
        return Int((Double(current - previous) / Double(previous) * 100).rounded())
    }

    /// "+12%", "−8%", "±0%"; "new" when there was nothing before but now there is.
    static func changeText(_ c: Int?, current: Int) -> String {
        guard let c else { return current > 0 ? "new" : "—" }
        return c > 0 ? "+\(c)%" : c < 0 ? "−\(-c)%" : "±0%"
    }

    static func trend(_ current: [StatsPlay], previous: [StatsPlay], hasPrevious: Bool) -> InsightsTrend {
        InsightsTrend(movies: current.filter(\.isMovie).count, episodes: current.filter(\.isEpisode).count,
                      prevMovies: previous.filter(\.isMovie).count, prevEpisodes: previous.filter(\.isEpisode).count,
                      hasPrevious: hasPrevious)
    }

    /// A play is a rewatch when the same user played the same item before: in `earlier`, or earlier in `plays`.
    static func newVsRewatch(_ plays: [StatsPlay], earlier: [StatsPlay]) -> InsightsSplit {
        var seen = Set(earlier.map { $0.userId + "|" + $0.itemId })
        var new = 0, again = 0
        for p in plays.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }) {
            if seen.insert(p.userId + "|" + p.itemId).inserted { new += 1 } else { again += 1 }
        }
        return InsightsSplit(new: new, rewatch: again)
    }

    /// The title the most users watched (ties: more plays, more watch time, then the title).
    static func mostPopular(_ plays: [StatsPlay]) -> InsightsPopular? {
        let g = Dictionary(grouping: plays.filter { $0.isMovie || $0.isEpisode }, by: titleKey)
        let rows = g.map { _, ps -> (InsightsPopular, Int) in
            let latest = ps.max { $0.start < $1.start } ?? ps[0]
            let users = Set(ps.map { $0.userName.isEmpty ? $0.userId : $0.userName }).filter { !$0.isEmpty }
            return (InsightsPopular(title: latest.displayTitle, itemId: latest.itemId, show: latest.isEpisode, plays: ps.count,
                                    users: users.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }),
                    StatsAggregate.totalSeconds(ps))
        }
        return rows.max { a, b in
            if a.0.users.count != b.0.users.count { return a.0.users.count < b.0.users.count }
            if a.0.plays != b.0.plays { return a.0.plays < b.0.plays }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.title > b.0.title
        }?.0
    }

    /// Users with plays in the previous period and none in this one, by name.
    static func quietUsers(current: [StatsPlay], previous: [StatsPlay]) -> [String] {
        let now = Set(current.map(\.userId))
        var names: [String: String] = [:]
        for p in previous where !now.contains(p.userId) { names[p.userId] = p.userName.isEmpty ? p.userId : p.userName }
        return names.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Movies a user watched in more than one sitting: the average time from the first start to the end of the
    /// last play, and how many such movies there were. nil when every movie was watched in one go.
    static func timeToFinish(_ plays: [StatsPlay]) -> InsightsFinish? {
        let g = Dictionary(grouping: known(plays).filter(\.isMovie)) { $0.userId + "|" + $0.itemId }
        let spans = g.values.filter { $0.count >= 2 }.map { ps -> Double in
            let s = ps.sorted { $0.start < $1.start }
            return s.last!.start.addingTimeInterval(Double(s.last!.seconds)).timeIntervalSince(s[0].start)
        }
        guard !spans.isEmpty else { return nil }
        return InsightsFinish(seconds: Int((spans.reduce(0, +) / Double(spans.count)).rounded()), movies: spans.count)
    }

    /// "45 min", "5 h", "3 days".
    static func spanText(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(max(1, seconds / 60)) min" }
        if seconds < 48 * 3600 { return "\(Int((Double(seconds) / 3600).rounded())) h" }
        return "\(Int((Double(seconds) / 86400).rounded())) days"
    }

    /// "21:00".
    static func hourText(_ h: Int) -> String { String(format: "%02d:00", h) }

    /// "Nov 3" for a yyyy-MM-dd day.
    static func dayText(_ day: String) -> String {
        guard let d = StatsDecode.dayFormat.date(from: day) else { return day }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Periods

    /// The `range.days` days right before the range (oldest first); empty for "All" (nothing to compare with).
    static func previousDays(_ range: StatsRange, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        guard range != .all else { return [] }
        let today = calendar.startOfDay(for: now)
        return (range.days..<(2 * range.days)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today).map { StatsDecode.dayFormat.string(from: $0) }
        }
    }

    /// How many days Insights asks PlayActivity for: the range and the one before it (capped at the "All" span).
    static func lookback(_ range: StatsRange) -> Int { range == .all ? range.days : min(2 * range.days, StatsRange.all.days) }

    /// All cards from every user's plays: `current` in the range, `previous` in the period before it.
    static func data(current: [StatsPlay], previous: [StatsPlay], hasPrevious: Bool, genres: [String: [String]],
                     calendar: Calendar = .current) -> InsightsData {
        let w = weekdaySeconds(current, calendar: calendar), h = hourSeconds(current, calendar: calendar)
        return InsightsData(count: current.count, weekdays: w, hours: h, busiestDay: busiest(w), busiestHour: busiest(h),
                            binge: binge(current), longest: longestSession(current),
                            genres: topGenres(current, genres: genres),
                            trend: trend(current, previous: previous, hasPrevious: hasPrevious),
                            split: newVsRewatch(current, earlier: previous), popular: mostPopular(current),
                            quiet: hasPrevious ? quietUsers(current: current, previous: previous) : [],
                            finish: timeToFinish(current))
    }
}

// MARK: - Year in review

/// A show in the Year in review: its top entry and how many distinct episodes were played.
struct YearShow: Identifiable, Hashable, Sendable {
    let top: StatsTop
    let episodes: Int
    var id: String { top.id }
}

struct YearReview: Hashable, Sendable {
    let year: Int
    let seconds: Int
    let movies: Int              // distinct movies
    let episodes: Int            // distinct episodes
    let activeDays: Int
    let topMovies: [StatsTop]
    let topShows: [YearShow]
    let topGenre: String?
    let months: [Int]            // 12 values, seconds
    let busiestMonth: Int?       // 0 = January
    let binge: InsightsBinge?
    let first: StatsPlay?
    let last: StatsPlay?
    let weekday: Int?            // 0 = Monday
    let hour: Int?
    let device: String?
    var isEmpty: Bool { first == nil }
    var hoursText: String { "\(Int((Double(seconds) / 3600).rounded()))" }
}

enum YearAggregate {
    /// The year's days, January 1 up to today for the current year (oldest first).
    static func days(_ year: Int, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
        let end = min(next, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? next)
        var out: [String] = [], d = start
        while d < end {
            out.append(StatsDecode.dayFormat.string(from: d))
            guard let n = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    static func plays(_ plays: [StatsPlay], year: Int) -> [StatsPlay] {
        let p = String(format: "%04d-", year)
        return plays.filter { $0.day.hasPrefix(p) }
    }

    /// Years that have data (newest first), always with the current one.
    static func years(days: [String], now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        var set = Set(days.compactMap { Int($0.prefix(4)) })
        set.insert(calendar.component(.year, from: now))
        return set.sorted(by: >)
    }

    /// Watch time per month (January first) from each play's day.
    static func monthSeconds(_ plays: [StatsPlay]) -> [Int] {
        var out = Array(repeating: 0, count: 12)
        for p in plays {
            let parts = p.day.split(separator: "-")
            if parts.count >= 2, let m = Int(parts[1]), (1...12).contains(m) { out[m - 1] += p.seconds }
        }
        return out
    }

    /// Top shows with their distinct episode count.
    static func topShows(_ plays: [StatsPlay], limit: Int = 5) -> [YearShow] {
        let eps = Dictionary(grouping: plays.filter(\.isEpisode), by: \.displayTitle).mapValues { Set($0.map(\.itemId)).count }
        return StatsAggregate.topShows(plays, limit: limit).map { YearShow(top: $0, episodes: eps[$0.id] ?? 0) }
    }

    static func review(_ all: [StatsPlay], year: Int, genres: [String: [String]], calendar: Calendar = .current) -> YearReview {
        let ps = plays(all, year: year)
        let sorted = ps.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        let months = monthSeconds(ps)
        return YearReview(year: year, seconds: StatsAggregate.totalSeconds(ps),
                          movies: Set(ps.filter(\.isMovie).map(\.itemId)).count,
                          episodes: Set(ps.filter(\.isEpisode).map(\.itemId)).count,
                          activeDays: Set(ps.map(\.day)).count,
                          topMovies: StatsAggregate.topMovies(ps), topShows: topShows(ps),
                          topGenre: Insights.topGenres(ps, genres: genres, limit: 1).first?.label,
                          months: months, busiestMonth: Insights.busiest(months)?.index,
                          binge: Insights.binge(ps), first: sorted.first, last: sorted.last,
                          weekday: Insights.busiest(Insights.weekdaySeconds(ps, calendar: calendar))?.index,
                          hour: Insights.busiest(Insights.hourSeconds(ps, calendar: calendar))?.index,
                          device: StatsUsersAggregate.topDevice(ps))
    }
}

// MARK: - Retention + decoding

enum InsightsRetention {
    /// `MaxDataAge` (months; -1 = keep everything) from the plugin's settings (Emby's named configuration
    /// `playback_reporting` or Jellyfin's plugin configuration).
    static func maxDataAge(_ data: Data) -> Int? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let v = o["MaxDataAge"] else { return nil }
        return StatsDecode.string(v).isEmpty ? nil : StatsDecode.int(v)
    }

    /// The Playback Reporting plugin's id in `/Plugins`.
    static func pluginId(_ data: Data) -> String? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return arr.first { StatsDecode.pluginListed(names: [StatsDecode.string($0["Name"])]) }
            .map { StatsDecode.string($0["Id"]) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func hintText(_ months: Int) -> String {
        "Your server keeps \(months) month\(months == 1 ? "" : "s") of history: Settings → Playback Reporting → Max data age"
    }

    /// Insights: a hint when the server keeps less than `need` months (nil: unknown, keep-all or enough).
    static func hint(maxAge: Int?, need: Int) -> String? {
        guard let m = maxAge, m > 0, m < need else { return nil }
        return hintText(m)
    }

    /// Year in review: a hint when the oldest kept day is after January 1 of that year.
    static func yearHint(maxAge: Int?, year: Int, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let m = maxAge, m > 0, let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let oldest = calendar.date(byAdding: .month, value: -m, to: now), oldest > jan1 else { return nil }
        return hintText(m)
    }
}

enum InsightsDecode {
    /// `/Users/{id}/Items?Ids=…&Fields=Genres`: item id → (genres, series id).
    static func genres(_ data: Data) -> [String: (genres: [String], series: String?)] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = o["Items"] as? [[String: Any]] else { return [:] }
        var out: [String: (genres: [String], series: String?)] = [:]
        for i in items {
            let id = StatsDecode.string(i["Id"])
            guard !id.isEmpty else { continue }
            let s = StatsDecode.string(i["SeriesId"])
            out[id] = ((i["Genres"] as? [Any])?.compactMap { $0 as? String } ?? [], s.isEmpty ? nil : s)
        }
        return out
    }

    /// Non-admins (no plugin data): played movies and episodes from the normal API, one "play" per item on its
    /// `UserData.LastPlayedDate` with the item's full length. Returns the plays and item id → genres.
    static func playedItems(_ data: Data, calendar: Calendar = .current) -> (plays: [StatsPlay], genres: [String: [String]]) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = o["Items"] as? [[String: Any]] else { return ([], [:]) }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        day.calendar = calendar; day.timeZone = calendar.timeZone
        var plays: [StatsPlay] = [], genres: [String: [String]] = [:]
        for i in items {
            let id = StatsDecode.string(i["Id"]), type = StatsDecode.string(i["Type"])
            guard !id.isEmpty, let ud = i["UserData"] as? [String: Any],
                  let when = StatsDecode.isoDate(StatsDecode.string(ud["LastPlayedDate"])) else { continue }
            var name = StatsDecode.string(i["Name"])
            if type.lowercased() == "episode" {
                let series = StatsDecode.string(i["SeriesName"])
                if !series.isEmpty {
                    name = "\(series) - s\(StatsDecode.int(i["ParentIndexNumber"]))e\(StatsDecode.int(i["IndexNumber"])) - \(name)"
                }
            }
            let ticks = (i["RunTimeTicks"] as? NSNumber)?.int64Value ?? Int64(StatsDecode.int(i["RunTimeTicks"]))
            plays.append(StatsPlay(id: "f-" + id, start: when, day: day.string(from: when), itemId: id, name: name,
                                   type: type, client: "", device: "", method: "", seconds: Int(ticks / 10_000_000)))
            genres[id] = (i["Genres"] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        return (plays, genres)
    }
}
