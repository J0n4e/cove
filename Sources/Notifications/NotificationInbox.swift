import Foundation

// In-app notification list (Glass3D → Activity → Notifications): the pure part. Every notification Cove makes
// is also kept here, newest first, bounded (100 items, 30 days). Saved as Application Support/Cove/notifications.json
// by NotificationCenterStore. Tested in Tests/NotificationCenterTests.swift.

/// One picture of a stored notification (same order as the banner's candidates).
struct StoredNotificationImage: Codable, Equatable, Hashable {
    let id: String
    let kind: String
}

/// One stored notification.
struct StoredNotification: Codable, Equatable, Identifiable {
    let id: String
    let date: Date
    /// The macOS banner's title and body
    let title: String
    let body: String
    /// The card's bold title and detail line
    let cardTitle: String
    let cardDetail: String
    /// Where Open goes: NewMediaService.userInfo (strings: server, userId, kind, id, seriesId, season)
    let target: [String: String]
    let images: [StoredNotificationImage]
    let server: String
    let userId: String
    /// What Play starts (a movie, the episode, a batch's first new episode); nil = no Play button
    let playId: String?
    var read: Bool
    /// When the server added the item(s); nil for old entries (then the alert time is shown)
    var added: Date? = nil

    init(_ n: NewMediaNotification, date: Date, target: [String: String], read: Bool = false) {
        self.id = n.id + "|" + String(Int(date.timeIntervalSince1970))
        self.date = date
        self.title = n.title
        self.body = n.body
        self.cardTitle = n.cardTitle.isEmpty ? n.title : n.cardTitle
        self.cardDetail = n.cardDetail.isEmpty ? n.body : n.cardDetail
        self.target = target
        self.images = n.images.map { StoredNotificationImage(id: $0.id, kind: $0.kind) }
        self.server = n.server
        self.userId = n.userId
        self.playId = n.playId
        self.read = read
        self.added = n.added
    }
}

/// How a new notification is shown.
enum NotificationPresentation: Equatable {
    /// Cove's own glass toast (Cove in front, nothing playing): no macOS banner
    case toast
    /// The macOS banner (Cove in the background or hidden)
    case banner
    /// Only the list (Cove in front while a video plays: keep it unobtrusive)
    case listOnly

    /// `frontmost`: NSApp.isActive with a main window key; `playing`: a video is open in the player.
    static func decide(frontmost: Bool, playing: Bool) -> NotificationPresentation {
        guard frontmost else { return .banner }
        return playing ? .listOnly : .toast
    }
}

enum NotificationInbox {
    static let maxItems = 100
    static let maxAge: TimeInterval = 30 * 24 * 3600

    /// Drops what is older than 30 days and keeps the newest 100 (newest first).
    static func pruned(_ list: [StoredNotification], now: Date) -> [StoredNotification] {
        let fresh = list.filter { now.timeIntervalSince($0.date) <= maxAge }.sorted { $0.date > $1.date }
        return Array(fresh.prefix(maxItems))
    }

    /// The same news a second time: same server and user, same card (title, detail line) and the same item (Play
    /// target or Open target), within 2 days. Happens when one movie sits in two libraries (each library is checked
    /// on its own) or is found by the poll and the socket at once (owner: two cards for one movie).
    static func isDuplicate(_ n: StoredNotification, in list: [StoredNotification]) -> Bool {
        list.contains { o in
            o.id != n.id && norm(o.server) == norm(n.server) && o.userId == n.userId
                && o.cardTitle == n.cardTitle && o.cardDetail == n.cardDetail
                && (sameItem(o, n) || o.added != nil && o.added == n.added)
                && abs(o.date.timeIntervalSince(n.date)) < 2 * 24 * 3600
        }
    }
    private static func sameItem(_ a: StoredNotification, _ b: StoredNotification) -> Bool {
        if let x = a.playId, let y = b.playId { return x == y }
        return a.target["id"] != nil && a.target["id"] == b.target["id"]
    }

    /// The list without the repeats already in it (keeps the newest of each); for lists saved before the check.
    static func deduped(_ list: [StoredNotification]) -> [StoredNotification] {
        var kept: [StoredNotification] = []
        for n in list.sorted(by: { $0.date > $1.date }) where !isDuplicate(n, in: kept) { kept.append(n) }
        return kept
    }

    /// Adds one at the top (an older copy with the same id is replaced), then prunes.
    static func adding(_ n: StoredNotification, to list: [StoredNotification], now: Date) -> [StoredNotification] {
        pruned([n] + list.filter { $0.id != n.id }, now: now)
    }

    /// Whether an entry belongs to the active server (old entries without a server: yes; no active server yet: yes).
    static func isServer(_ entry: String, _ active: String) -> Bool {
        entry.isEmpty || active.isEmpty || norm(entry) == norm(active)
    }
    static func norm(_ s: String) -> String {
        var t = s.lowercased(); while t.hasSuffix("/") { t.removeLast() }; return t
    }
    /// The active server's entries only (owner: notifications just from the server Cove is on).
    static func forServer(_ list: [StoredNotification], _ active: String) -> [StoredNotification] {
        list.filter { isServer($0.server, active) }
    }

    static func unreadCount(_ list: [StoredNotification]) -> Int { list.filter { !$0.read }.count }

    static func markRead(_ id: String, in list: [StoredNotification]) -> [StoredNotification] {
        list.map { var n = $0; if n.id == id { n.read = true }; return n }
    }

    /// The stored entry a clicked macOS banner belongs to: same target (the banner's userInfo is the entry's target)
    /// and title, the newest unread one first. nil when nothing matches (e.g. the entry was cleared).
    static func matching(_ info: [String: String], title: String?, in list: [StoredNotification]) -> String? {
        let same = list.filter { $0.target == info }.sorted { $0.date > $1.date }
        let titled = same.filter { title == nil || $0.title == title }
        return (titled.first { !$0.read } ?? same.first { !$0.read } ?? titled.first ?? same.first)?.id
    }

    static func markAllRead(_ list: [StoredNotification]) -> [StoredNotification] {
        list.map { var n = $0; n.read = true; return n }
    }

    static func removing(_ id: String, from list: [StoredNotification]) -> [StoredNotification] {
        list.filter { $0.id != id }
    }

    enum Section: String, Equatable { case today = "Today", yesterday = "Yesterday", earlier = "Earlier" }

    static func section(of date: Date, now: Date, calendar: Calendar = .current) -> Section {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return .yesterday }
        return .earlier
    }

    /// Today / Yesterday / Earlier, in that order, empty sections left out; items newest first.
    static func grouped(_ list: [StoredNotification], now: Date, calendar: Calendar = .current)
        -> [(section: Section, items: [StoredNotification])] {
        // By when the server added it (owner), old entries by the alert time
        let sorted = list.sorted { ($0.added ?? $0.date) > ($1.added ?? $1.date) }
        return [Section.today, .yesterday, .earlier].compactMap { s in
            let items = sorted.filter { section(of: $0.added ?? $0.date, now: now, calendar: calendar) == s }
            return items.isEmpty ? nil : (s, items)
        }
    }

    /// The card's time line: when the server ADDED it (owner: the alert time isn't interesting), e.g.
    /// "Added yesterday, 21:14" / "Added today, 09:02" / "Added 18 Nov, 21:14"; old entries keep the alert time.
    static func addedText(_ n: StoredNotification, now: Date, calendar: Calendar = .current) -> String {
        guard let a = n.added else { return relativeTime(n.date, now: now) }
        let t = a.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(a, inSameDayAs: now) { return "Added today, \(t)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(a, inSameDayAs: y) { return "Added yesterday, \(t)" }
        return "Added " + a.formatted(.dateTime.day().month(.abbreviated)) + ", " + t
    }

    /// "Just now", "5 min ago", "2 h ago", "3 d ago".
    static func relativeTime(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }

    /// The picture link for a card: the server's own image, without the art plugin's enhancers (as the banner).
    /// The server a card's picture comes from: the entry's own server; old entries without one → the current server.
    static func imageServer(stored: String, current: String) -> String {
        let s = stored.trimmingCharacters(in: .whitespaces)
        return (s.isEmpty ? current : s).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Headers for pictures of a server that isn't the current one: its saved token (tokens keyed by the
    /// lowercased address, as ServerStore), or none (Emby/Jellyfin pictures usually need no sign-in).
    static func otherServerHeaders(server: String, current: String, tokens: [String: String]) -> [String: String] {
        guard !server.isEmpty, server.lowercased() != current.lowercased(),
              let t = tokens[server.lowercased()], !t.isEmpty else { return [:] }
        return ["X-Emby-Token": t]
    }

    static func imageURL(server: String, _ img: StoredNotificationImage, width: Int = 480) -> URL? {
        URL(string: "\(server)/Items/\(img.id)/Images/\(img.kind)?maxWidth=\(width)&quality=80&EnableImageEnhancers=false")
    }

    // MARK: File

    static func encode(_ list: [StoredNotification]) -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(list)
    }

    static func decode(_ d: Data) -> [StoredNotification] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([StoredNotification].self, from: d)) ?? []
    }
}
