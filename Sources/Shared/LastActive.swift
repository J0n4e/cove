import Foundation

// "Last active 2 h ago" for every account (Manage server → Users rows, Activity → Users cards), from the server's
// User.LastActivityDate; the tooltip adds LastLoginDate. Tested in Tests/WatchActivityTests.swift.
enum LastActive {
    /// "just now", "5 min ago", "2 h ago", "3 d ago", then the date ("Nov 2" / "Nov 2, 2025").
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        if s < 7 * 86400 { return "\(Int(s / 86400)) d ago" }
        let sameYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: now)
        return sameYear ? d.formatted(.dateTime.month(.abbreviated).day())
                        : d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Last active 2 h ago" / "Last active: Never".
    static func text(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "Last active: Never" }
        return "Last active " + ago(d, now: now)
    }

    /// The exact date for tooltips ("Nov 14, 2026 at 00:01").
    static func exact(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// Tooltip: "Last active: Nov 14, 2026 at 00:01 · Last login: Never".
    static func tooltip(activity: Date?, login: Date?) -> String {
        "Last active: " + (activity.map(exact) ?? "Never") + " · Last login: " + (login.map(exact) ?? "Never")
    }

    enum Sort: Int, CaseIterable { case name, lastActive }

    /// Most recent first; never-active users last (by name).
    static func byLastActive<T>(_ list: [T], date: (T) -> Date?, name: (T) -> String) -> [T] {
        list.sorted { a, b in
            switch (date(a), date(b)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending
            }
        }
    }
}
