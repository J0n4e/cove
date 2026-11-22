import Foundation

// Now Playing → Users (admins + Playback Reporting only): one card per server user. Pure rules here (tested in
// StatsUsersTests); the loading is in StatsModel.loadUsers, the views in StatsUsers.swift.

/// A server user from `/Users` (both servers: Id, Name, LastActivityDate, PrimaryImageTag).
struct StatsServerUser: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lastActivity: Date?
    let imageTag: String?
    var lastLogin: Date? = nil
}

/// Direct play / Direct stream / Transcode shares of a user's plays (0…1 each, summing to 1 when any are known).
struct StatsMethodShares: Hashable, Sendable {
    var directPlay = 0.0, directStream = 0.0, transcode = 0.0
    var isEmpty: Bool { directPlay + directStream + transcode == 0 }
    /// "7% DP / 21% DS / 72% TC" (rounded so the three add up to 100).
    var text: String {
        let p = StatsUsersAggregate.percents([directPlay, directStream, transcode])
        return "\(p[0])% DP / \(p[1])% DS / \(p[2])% TC"
    }
}

/// One user's card.
struct StatsUserSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let imageTag: String?
    let plays: Int
    let seconds: Int
    let movies: Int
    let episodes: Int
    let titles: Int
    let topDevice: String?
    let methods: StatsMethodShares
    let lastSeen: Date?
    let address: String?          // the latest play's RemoteAddress (Emby); nil when the server doesn't record it
    /// The account's own User.LastActivityDate / LastLoginDate (Last active line + tooltip)
    var lastActive: Date? = nil
    var lastLogin: Date? = nil
    var isLocal: Bool? { address.flatMap(StatsNet.isLocal) }
}

/// The summary row above the cards. Averages count only users with at least one play in the range.
struct StatsUsersTotals: Equatable, Sendable {
    let totalUsers: Int
    let activeUsers: Int
    let mostActive: String?
    let avgPlays: Double
    let avgSeconds: Double
    var avgPlaysText: String { String(format: "%.1f", avgPlays) }
    var avgHoursText: String { String(format: "%.1fh", avgSeconds / 3600) }
}

enum StatsMethodKind: Equatable, Sendable { case directPlay, directStream, transcode }

enum StatsUsersAggregate {
    /// "DirectPlay", "DirectStream", "Transcode", Jellyfin's "Transcode (v:h264 a:aac)" / "DirectStream (…)".
    static func methodKind(_ m: String) -> StatsMethodKind? {
        let l = m.lowercased().replacingOccurrences(of: " ", with: "")
        if l.hasPrefix("directplay") { return .directPlay }
        if l.hasPrefix("directstream") { return .directStream }
        if l.hasPrefix("transcode") { return .transcode }
        return nil
    }

    static func methodShares(_ plays: [StatsPlay]) -> StatsMethodShares {
        var dp = 0, ds = 0, tc = 0
        for p in plays {
            switch methodKind(p.method) {
            case .directPlay: dp += 1
            case .directStream: ds += 1
            case .transcode: tc += 1
            case nil: break
            }
        }
        let n = Double(dp + ds + tc)
        guard n > 0 else { return StatsMethodShares() }
        return StatsMethodShares(directPlay: Double(dp) / n, directStream: Double(ds) / n, transcode: Double(tc) / n)
    }

    /// Whole percents that add up to 100 (largest remainder); all zero when nothing is known.
    static func percents(_ shares: [Double]) -> [Int] {
        let total = shares.reduce(0, +)
        guard total > 0 else { return shares.map { _ in 0 } }
        let raw = shares.map { $0 / total * 100 }
        var out = raw.map { Int($0.rounded(.down)) }
        let order = raw.indices.sorted { (raw[$0] - Double(out[$0])) > (raw[$1] - Double(out[$1])) }
        var left = 100 - out.reduce(0, +)
        for i in order where left > 0 { out[i] += 1; left -= 1 }
        return out
    }

    /// The device with the most plays (ties: the most watch time, then the name); the client when no device is logged.
    static func topDevice(_ plays: [StatsPlay]) -> String? {
        let named = plays.map { (name: $0.device.isEmpty ? $0.client : $0.device, s: $0.seconds) }.filter { !$0.name.isEmpty }
        let g = Dictionary(grouping: named, by: \.name)
        return g.max { a, b in
            let ka = (a.value.count, a.value.reduce(0) { $0 + $1.s }), kb = (b.value.count, b.value.reduce(0) { $0 + $1.s })
            return ka != kb ? ka < kb : a.key > b.key
        }?.key
    }

    /// A user's card from their plays (already filtered to ≥ 60 s and to the range).
    static func summary(_ user: StatsServerUser, plays: [StatsPlay]) -> StatsUserSummary {
        let latest = plays.max { $0.start < $1.start }
        let titles = Set(plays.map { $0.isEpisode ? "s:" + $0.displayTitle : "i:" + $0.itemId }).count
        let addr = plays.sorted { $0.start > $1.start }.first { !$0.remoteAddress.isEmpty }?.remoteAddress
        let seen = [user.lastActivity, latest?.start].compactMap { $0 }.max()
        return StatsUserSummary(id: user.id, name: user.name, imageTag: user.imageTag, plays: plays.count,
                                seconds: StatsAggregate.totalSeconds(plays),
                                movies: plays.filter(\.isMovie).count, episodes: plays.filter(\.isEpisode).count,
                                titles: titles, topDevice: topDevice(plays), methods: methodShares(plays),
                                lastSeen: seen, address: addr, lastActive: user.lastActivity, lastLogin: user.lastLogin)
    }

    /// Most watch time first, then most plays, then the name.
    static func sorted(_ users: [StatsUserSummary]) -> [StatsUserSummary] {
        users.sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The cards shown: users with at least one play in the range, in the given (watch time) order.
    static func withPlays(_ users: [StatsUserSummary]) -> [StatsUserSummary] { users.filter { $0.plays > 0 } }

    static func totals(_ users: [StatsUserSummary]) -> StatsUsersTotals {
        let active = users.filter { $0.plays > 0 }
        let n = Double(active.count)
        return StatsUsersTotals(totalUsers: users.count, activeUsers: active.count,
                                mostActive: sorted(active).first?.name,
                                avgPlays: n > 0 ? Double(active.reduce(0) { $0 + $1.plays }) / n : 0,
                                avgSeconds: n > 0 ? Double(active.reduce(0) { $0 + $1.seconds }) / n : 0)
    }

    /// "JD" for "John Doe", "MA" for "mario", "?" for an empty name.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }
        if words.count >= 2 { return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased() }
        guard let w = words.first else { return "?" }
        return String(w.prefix(2)).uppercased()
    }

    /// A stable colour slot (0..<n) for the avatar from the name.
    static func colorIndex(_ name: String, count: Int) -> Int {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return count > 0 ? sum % count : 0
    }
}

/// Local vs Remote from an address the server logged.
enum StatsNet {
    /// true = private / loopback / link-local, false = public, nil = unreadable.
    static func isLocal(_ raw: String) -> Bool? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("[") , let end = s.firstIndex(of: "]") { s = String(s[s.index(after: s.startIndex)..<end]) }   // [v6]:port
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }                                                     // mapped v4
        if s.contains(".") {
            if let c = s.firstIndex(of: ":") { s = String(s[..<c]) }                                                 // v4:port
            let o = s.split(separator: ".").compactMap { Int($0) }
            guard o.count == 4, o.allSatisfy({ (0...255).contains($0) }) else { return nil }
            switch (o[0], o[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true      // carrier-grade NAT / Tailscale
            default: return false
            }
        }
        guard s.contains(":") else { return nil }
        if s == "::1" { return true }
        if s.hasPrefix("fc") || s.hasPrefix("fd") || s.hasPrefix("fe8") || s.hasPrefix("fe9") || s.hasPrefix("fea") || s.hasPrefix("feb") { return true }
        return false
    }
}

extension StatsDecode {
    /// `PlayActivity` for every user: normalised user id → (day → value).
    static func activityAll(_ data: Data) -> [String: [String: Int]] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var out: [String: [String: Int]] = [:]
        for row in arr {
            let id = norm(string(row["user_id"]))
            guard !id.isEmpty, id != "labels_user", let usage = row["user_usage"] as? [String: Any] else { continue }
            out[id] = usage.mapValues { int($0) }
        }
        return out
    }

    /// `/Users`: the server's users.
    static func serverUsers(_ data: Data) -> [StatsServerUser] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            let id = string(o["Id"])
            guard !id.isEmpty else { return nil }
            let tag = string(o["PrimaryImageTag"])
            return StatsServerUser(id: id, name: string(o["Name"]), lastActivity: isoDate(string(o["LastActivityDate"])),
                                   imageTag: tag.isEmpty ? nil : tag, lastLogin: isoDate(string(o["LastLoginDate"])))
        }
    }

    /// "2026-11-14T00:01:23.1234567Z" (7 fraction digits, as .NET writes them) or without fraction / zone.
    static func isoDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        var t = s
        if let dot = t.firstIndex(of: ".") {
            let rest = t[t.index(after: dot)...]
            let zone = rest.drop(while: { $0.isNumber })
            t = String(t[..<dot]) + String(zone)
        }
        if !(t.hasSuffix("Z") || t.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil) { t += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: t) else { return nil }
        return d.timeIntervalSince1970 < 86_400 * 365 ? nil : d   // .NET's 0001-01-01 = never
    }
}
