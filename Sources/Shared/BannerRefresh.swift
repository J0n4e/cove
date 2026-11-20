import Foundation

/// Settings → Home → Banner → Refresh banner: how often the Home banner (both themes) picks a fresh set of
/// titles while Cove stays open. 0 = only when Home loads (the original behaviour).
enum BannerRefresh {
    static let key = "bannerRefresh"
    static let defaultValue = 0
    static let options: [(Int, String)] = [(0, "Only when Home loads"), (15, "Every 15 min"),
                                           (30, "Every 30 min"), (60, "Every hour")]
    static var current: Int {
        let v = UserDefaults.standard.integer(forKey: key)   // 0 when unset
        return options.contains { $0.0 == v } ? v : defaultValue
    }

    /// How often the refresh loop wakes to check (cheap: it only compares dates and visibility).
    static let tick: UInt64 = 30_000_000_000

    /// Whether a refresh is due: an interval is set, it has passed, and nobody is hidden away or watching.
    /// A refresh missed while hidden or playing happens once on the first check after that.
    static func isDue(minutes: Int, last: Date, now: Date, visible: Bool, playing: Bool) -> Bool {
        minutes > 0 && visible && !playing && now.timeIntervalSince(last) >= Double(minutes) * 60
    }

    /// "From Home rows" on refresh number `round`: from each row the next two titles with a backdrop
    /// (round 0 = the first two, exactly today's banner), wrapping at the row's end; one per title, eight at most.
    static func rotatedRows(_ rows: [[Item]], round: Int) -> [Item] {
        var seen = Set<String>(), out: [Item] = []
        for items in rows {
            let withArt = items.filter { $0.backdropId != nil }
            guard !withArt.isEmpty else { continue }
            let take = min(2, withArt.count)
            let start = (round * 2) % withArt.count
            for k in 0..<take {
                let it = withArt[(start + k) % withArt.count]
                if !seen.contains(it.heroTitle) { seen.insert(it.heroTitle); out.append(it) }
            }
        }
        return Array(out.prefix(8))
    }

    /// Random picks / Favorites: titles not in the previous banner first, so a new fetch doesn't show
    /// the same set again when there are enough titles; the previous ones only fill up what's missing.
    static func avoidingPrevious(_ fetched: [Item], previous: [Item]) -> [Item] {
        let prev = Set(previous.map(\.heroTitle))
        return fetched.filter { !prev.contains($0.heroTitle) } + fetched.filter { prev.contains($0.heroTitle) }
    }
}

/// Cancels the banner refresh loop when its HomeModel goes away.
final class TaskHolder {
    var task: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    deinit { task?.cancel() }
}
