import Foundation

// Activity → Graphs (admins + Playback Reporting): every user's plays in the range as charts. Pure rules here
// (tested in StatsGraphsTests); loading in StatsModel.loadGraphs, the views in StatsGraphs*.swift.

/// How plays are grouped along the time axis.
enum StatsBucketUnit: Equatable, Sendable {
    case day, week, month
    var component: Calendar.Component {
        switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month }
    }
}

extension StatsRange {
    /// Plays per day: daily bars for 7 / 30 days, weekly for 12 months, monthly for All.
    var playsUnit: StatsBucketUnit { [.day, .day, .week, .month][rawValue] }
    /// Play types over time: daily for 7 days, weekly for 30 days / 12 months, monthly for All.
    var typesUnit: StatsBucketUnit { [.day, .week, .week, .month][rawValue] }
}

/// One bar: plays and watch time from `start` (a day, a week's first day or a month's first day).
struct StatsCountBucket: Identifiable, Hashable, Sendable {
    let start: Date
    var plays: Int
    var seconds: Int
    var id: Date { start }
}

/// One cell of the weekday × hour grid: weekday 0 = Monday … 6 = Sunday, hour 0…23 (local time).
struct StatsHeatCell: Identifiable, Hashable, Sendable {
    let weekday: Int
    let hour: Int
    var seconds: Int
    var id: Int { weekday * 24 + hour }
}

/// Play type counts in one period.
struct StatsTypeBucket: Identifiable, Hashable, Sendable {
    let start: Date
    var directPlay = 0, directStream = 0, transcode = 0
    var id: Date { start }
    var total: Int { directPlay + directStream + transcode }
}

/// A device / client line: watch time and plays.
struct StatsDeviceRow: Identifiable, Hashable, Sendable {
    let name: String
    let client: String
    let seconds: Int
    let plays: Int
    var id: String { name }
}

/// Movies vs Episodes (plus anything else) by watch time and plays.
struct StatsKindSplit: Hashable, Sendable {
    var movieSeconds = 0, episodeSeconds = 0, otherSeconds = 0
    var movies = 0, episodes = 0, others = 0
    var totalSeconds: Int { movieSeconds + episodeSeconds + otherSeconds }
}

/// Everything the Graphs tab draws, computed off the main thread once per load.
struct StatsGraphsData: Hashable, Sendable {
    let plays: [StatsCountBucket]
    let playsUnit: StatsBucketUnit
    let heat: [StatsHeatCell]
    let types: [StatsTypeBucket]
    let typesUnit: StatsBucketUnit
    let devices: [StatsDeviceRow]
    let kinds: StatsKindSplit
    let count: Int
}

enum StatsGraphsAggregate {
    /// Weeks start on Monday (ISO), whatever the Mac's region says, so buckets and tests agree.
    static func calendar(_ base: Calendar = .current) -> Calendar {
        var c = base; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }

    /// The first day of the period `date` falls in.
    static func bucketStart(_ date: Date, _ unit: StatsBucketUnit, calendar: Calendar) -> Date {
        let c = Self.calendar(calendar)
        let day = c.startOfDay(for: date)
        switch unit {
        case .day: return day
        case .week: return c.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        case .month: return c.dateInterval(of: .month, for: day)?.start ?? day
        }
    }

    /// Every period of the range (oldest first, empty ones included); "All" starts at the first period with plays.
    static func periods(_ range: StatsRange, unit: StatsBucketUnit, plays: [StatsPlay], now: Date = Date(),
                        calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        for d in StatsAggregate.days(range, now: now, calendar: calendar) {
            guard let date = StatsDecode.dayFormat.date(from: d) else { continue }
            let s = bucketStart(date, unit, calendar: calendar)
            if out.last != s { out.append(s) }
        }
        if range == .all {
            let firstPlay = plays.compactMap { StatsDecode.dayFormat.date(from: $0.day) }.min()
            guard let f = firstPlay else { return [] }
            let first = bucketStart(f, unit, calendar: calendar)
            out = out.filter { $0 >= first }
        }
        return out
    }

    /// Plays per day / week / month (by the day the plugin logged them).
    static func playsPerBucket(_ plays: [StatsPlay], _ range: StatsRange, now: Date = Date(),
                               calendar: Calendar = .current) -> [StatsCountBucket] {
        let unit = range.playsUnit
        var map: [Date: StatsCountBucket] = [:]
        for s in periods(range, unit: unit, plays: plays, now: now, calendar: calendar) {
            map[s] = StatsCountBucket(start: s, plays: 0, seconds: 0)
        }
        for p in plays {
            guard let d = StatsDecode.dayFormat.date(from: p.day) else { continue }
            let s = bucketStart(d, unit, calendar: calendar)
            guard map[s] != nil else { continue }
            map[s]!.plays += 1
            map[s]!.seconds += p.seconds
        }
        return map.values.sorted { $0.start < $1.start }
    }

    /// Weekday (0 = Monday) and hour of a local time.
    static func slot(_ date: Date, calendar: Calendar = .current) -> (weekday: Int, hour: Int) {
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        return (((c.weekday ?? 2) + 5) % 7, c.hour ?? 0)
    }

    /// Watch time per weekday × hour: each play's seconds spread over the hours it ran (local start time), so a
    /// 2 h film at 21:30 counts 30 min at 21, 60 at 22 and 30 at 23. Always 7 × 24 cells, Monday 0:00 first.
    static func heatmap(_ plays: [StatsPlay], calendar: Calendar = .current) -> [StatsHeatCell] {
        var grid = Array(repeating: 0, count: 7 * 24)
        for p in plays where p.start != Date.distantPast {
            var t = p.start, left = max(0, p.seconds)
            while left > 0 {
                let hourStart = calendar.dateInterval(of: .hour, for: t)?.start ?? t
                let inHour = max(1, Int(hourStart.addingTimeInterval(3600).timeIntervalSince(t)))
                let take = min(left, inHour)
                let s = slot(t, calendar: calendar)
                grid[s.weekday * 24 + s.hour] += take
                left -= take
                t = t.addingTimeInterval(TimeInterval(take))
            }
        }
        return (0..<7).flatMap { w in (0..<24).map { h in StatsHeatCell(weekday: w, hour: h, seconds: grid[w * 24 + h]) } }
    }

    /// Direct play / Direct stream / Transcode counts per period (Jellyfin's "Transcode (v:…)" is a transcode).
    static func playTypes(_ plays: [StatsPlay], _ range: StatsRange, now: Date = Date(),
                          calendar: Calendar = .current) -> [StatsTypeBucket] {
        let unit = range.typesUnit
        var map: [Date: StatsTypeBucket] = [:]
        for s in periods(range, unit: unit, plays: plays, now: now, calendar: calendar) { map[s] = StatsTypeBucket(start: s) }
        for p in plays {
            guard let d = StatsDecode.dayFormat.date(from: p.day) else { continue }
            let s = bucketStart(d, unit, calendar: calendar)
            guard map[s] != nil else { continue }
            switch StatsUsersAggregate.methodKind(p.method) {
            case .directPlay: map[s]!.directPlay += 1
            case .directStream: map[s]!.directStream += 1
            case .transcode: map[s]!.transcode += 1
            case nil: break
            }
        }
        return map.values.sorted { $0.start < $1.start }
    }

    /// The top devices by watch time (ties: plays, then name). A play without a device counts under its client.
    static func devices(_ plays: [StatsPlay], limit: Int = 6) -> [StatsDeviceRow] {
        let named = plays.filter { !($0.device.isEmpty && $0.client.isEmpty) }
        let g = Dictionary(grouping: named, by: { $0.device.isEmpty ? $0.client : $0.device })
        return g.map { name, ps in
            let clients = Dictionary(grouping: ps, by: \.client).max { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key }?.key ?? ""
            return StatsDeviceRow(name: name, client: clients == name ? "" : clients,
                                  seconds: StatsAggregate.totalSeconds(ps), plays: ps.count)
        }
        .sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            return $0.name < $1.name
        }
        .prefix(limit).map { $0 }
    }

    static func kinds(_ plays: [StatsPlay]) -> StatsKindSplit {
        var k = StatsKindSplit()
        for p in plays {
            if p.isMovie { k.movies += 1; k.movieSeconds += p.seconds }
            else if p.isEpisode { k.episodes += 1; k.episodeSeconds += p.seconds }
            else { k.others += 1; k.otherSeconds += p.seconds }
        }
        return k
    }

    static func data(_ plays: [StatsPlay], _ range: StatsRange, now: Date = Date(), calendar: Calendar = .current) -> StatsGraphsData {
        StatsGraphsData(plays: playsPerBucket(plays, range, now: now, calendar: calendar), playsUnit: range.playsUnit,
                        heat: heatmap(plays, calendar: calendar),
                        types: playTypes(plays, range, now: now, calendar: calendar), typesUnit: range.typesUnit,
                        devices: devices(plays), kinds: kinds(plays), count: plays.count)
    }

    /// The bucket a hovered date falls in (the last one starting at or before it).
    static func bucket<T>(at date: Date, in items: [T], start: (T) -> Date) -> T? {
        items.last { start($0) <= date } ?? items.first
    }

    /// "Nov 14", "Week of Nov 10", "November 2026".
    static func periodText(_ start: Date, _ unit: StatsBucketUnit) -> String {
        switch unit {
        case .day: return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: return "Week of " + start.formatted(.dateTime.month(.abbreviated).day())
        case .month: return start.formatted(.dateTime.month(.wide).year())
        }
    }

    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
}
