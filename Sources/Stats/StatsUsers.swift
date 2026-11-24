import SwiftUI

/// Activity → Users (admins with Playback Reporting): a summary row, then one glass card per server user,
/// most watch time first. Same glass cards, readable text and range pill as Overview.
struct StatsUsersView: View {
    @ObservedObject var model: StatsModel
    @AppStorage("statsUsersSort") private var sort = 0   // 0 watch time, 1 last active

    private var cards: [StatsUserSummary] {
        let l = StatsUsersAggregate.withPlays(model.users)
        return sort == 1 ? LastActive.byLastActive(l, date: { $0.lastActive ?? $0.lastSeen }, name: { $0.name }) : l
    }

    var body: some View {
        StatsGate(model: model) {
            if let user = model.selectedUser { StatsUserOverview(model: model, user: user) }
            else {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.xl) {
                HStack {
                    StatsRangePills(range: $model.range)
                    Spacer()
                    Glass3DSegmentTabs(titles: ["Watch time", "Last active"], selection: $sort)
                }
                if model.usersLoading && model.usersRange != model.range { SkeletonShimmer().padding(.vertical, Glass3DTokens.Space.xxl).skeletonCrossfade() }
                else if model.users.isEmpty {
                    StatsStateCard(symbol: "person.2", title: "No users found",
                                   message: "The server didn't list any users. Open this tab again to retry.")
                } else if StatsUsersAggregate.withPlays(model.users).isEmpty {
                    StatsStateCard(symbol: "person.2", title: "No plays in this range",
                                   message: "Nobody on this server played anything in the chosen range. Try a longer one.")
                } else {
                    // Summary counts every server user; the cards only those with plays (as Unraid's Stream Viewer)
                    StatsUsersSummaryRow(totals: StatsUsersAggregate.totals(model.users))
                        .frame(maxWidth: 860).frame(maxWidth: .infinity)   // as wide as the cards, centred (owner)
                    // One user per line, full width, most active first (owner)
                    LazyVStack(alignment: .center, spacing: Glass3DTokens.Space.l) {   // centred in the page (owner)
                        ForEach(cards) { u in
                            StatsUserCard(user: u) { model.userOverview = []; model.selectedUser = u }
                                .frame(maxWidth: 860)   // fits the contents, not stretched (owner)
                        }
                    }
                    .frame(maxWidth: .infinity)   // the column spans the page so the cards sit in its middle
                }
            }
            .task(id: model.range) { await model.loadUsers() }
            }
        }
    }
}

/// One user's Overview (the same content as the Overview tab) with an avatar + name header and an
/// "All users" back pill; the range pill is shared with the list.
private struct StatsUserOverview: View {
    @ObservedObject var model: StatsModel
    let user: StatsUserSummary
    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.xl) {
            HStack(spacing: Glass3DTokens.Space.m) {
                Button { model.selectedUser = nil } label: {
                    Label("All users", systemImage: "chevron.left").cvFont(Glass3DTokens.Text.meta + 1, weight: .semibold)
                        .padding(.horizontal, Glass3DTokens.Space.l).frame(height: 30).classicGlassPill(iconOnly: false)
                }
                .buttonStyle(.plainHand)
                StatsUserAvatar(user: user)
                Text(user.name).cvFont(Glass3DTokens.Text.section, weight: .bold).lineLimit(1).modifier(Glass3DReadableText())
                Spacer(minLength: 0)
            }
            StatsRangePills(range: $model.range)
            if model.userOverviewLoading && model.userOverview.isEmpty { SkeletonShimmer().padding(.vertical, Glass3DTokens.Space.xxl).skeletonCrossfade() }
            else {
                StatsOverviewContent(plays: model.userOverview, range: model.range)
                if !StatsAggregate.isFewData(model.userOverview) {   // the Insights cards for this user's plays
                    StatsHeading(text: "Insights")
                    InsightsGrid(data: Insights.data(current: model.userOverview, previous: [], hasPrevious: false, genres: [:]),
                                 range: model.range, perUser: true)
                }
            }
        }
        .task(id: "\(user.id)|\(model.range.rawValue)") { await model.loadUserOverview() }
    }
}

private struct StatsUsersSummaryRow: View {
    let totals: StatsUsersTotals
    var body: some View {
        let avgHelp = "Averaged over the \(totals.activeUsers) user\(totals.activeUsers == 1 ? "" : "s") with at least one play in this range"
        // 2 × 2 (owner): Total users · Avg hours, then Most active · Avg plays
        VStack(spacing: Glass3DTokens.Space.l) {
            HStack(spacing: Glass3DTokens.Space.l) {
                StatsUsersSummaryTile(label: "Total users", value: "\(totals.totalUsers)", help: "Every user on this server")
                StatsUsersSummaryTile(label: "Avg hours / user", value: totals.avgHoursText, help: avgHelp)
            }
            HStack(spacing: Glass3DTokens.Space.l) {
                StatsUsersSummaryTile(label: "Most active", value: totals.mostActive ?? "—", help: "Most watch time in this range")
                StatsUsersSummaryTile(label: "Avg plays / user", value: totals.avgPlaysText, help: avgHelp)
            }
        }
    }
}

private struct StatsUsersSummaryTile: View {
    let label: String, value: String, help: String
    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
            Text(label).cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
            Text(value).cvFont(26, weight: .heavy).lineLimit(1).minimumScaleFactor(0.6).modifier(Glass3DReadableText())
        }
        .frame(maxWidth: .infinity, alignment: .leading).statsCard().help(help)
    }
}

/// Softened tints that sit on the glass (Movies = accent, Episodes = blue, play types green / blue / orange).
enum StatsUsersStyle {
    static let episodes = Color(red: 0.45, green: 0.65, blue: 1.0)
    static let directPlay = Color(red: 0.40, green: 0.80, blue: 0.52)
    static let directStream = Color(red: 0.45, green: 0.65, blue: 1.0)
    static let transcode = Color(red: 1.0, green: 0.66, blue: 0.32)
    static let avatars: [Color] = [.init(red: 0.85, green: 0.35, blue: 0.40), .init(red: 0.40, green: 0.62, blue: 0.95),
                                   .init(red: 0.45, green: 0.75, blue: 0.50), .init(red: 0.90, green: 0.62, blue: 0.30),
                                   .init(red: 0.68, green: 0.50, blue: 0.92), .init(red: 0.30, green: 0.72, blue: 0.75)]
}

private struct StatsUserCard: View {
    @EnvironmentObject var emby: Emby
    let user: StatsUserSummary
    var open: () -> Void = {}
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false

    var body: some View {
        Button(action: open) { content }
            .buttonStyle(.plainHand)
            .tip("Show \(user.name)'s overview")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
            HStack(spacing: Glass3DTokens.Space.m) {
                StatsUserAvatar(user: user)
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    Text(user.name).cvFont(Glass3DTokens.Text.cardTitle + 1, weight: .bold).lineLimit(1).modifier(Glass3DReadableText())
                    Text(LastActive.text(user.lastActive)).cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                        .tip(LastActive.tooltip(activity: user.lastActive, login: user.lastLogin))
                    Text(seenLine).cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StatsUserBadge(text: emby.isJellyfin ? "JELLYFIN" : "EMBY",
                               tint: emby.isJellyfin ? Color(red: 0.68, green: 0.50, blue: 0.92) : StatsUsersStyle.directPlay)
                if let local = user.isLocal {
                    StatsUserBadge(text: local ? "Local" : "Remote", tint: local ? StatsUsersStyle.directStream : Theme.accent(accentName))
                }
            }
            HStack(spacing: Glass3DTokens.Space.s) {
                StatsUserTile(value: "\(user.plays)", label: "Plays")
                StatsUserTile(value: StatsAggregate.hoursText(user.seconds), label: "Watch time")
                StatsUserTile(value: "\(user.movies)", label: "Movies", tint: Theme.accent(accentName))
                StatsUserTile(value: "\(user.episodes)", label: "Episodes", tint: StatsUsersStyle.episodes)
                StatsUserTile(value: "\(user.titles)", label: "Titles")
                StatsUserTile(value: user.topDevice ?? "—", label: "Device", small: true)
            }
            StatsPlayTypesBar(shares: user.methods)
        }
        .statsCard()
        .opacity(user.plays == 0 ? 0.7 : 1)
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
            .strokeBorder(Color.white.opacity(hover ? Glass3DTokens.Stroke.strong : 0), lineWidth: 0.75))
        .scaleEffect(hover ? 1.015 : 1)   // a gentle lift + brighter edge: the card opens the user's overview
        .animation(Glass3DTokens.Motion.fast, value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    /// "Last seen: Nov 14, 00:01 · IP: 217.84.235.168" — the IP only while the pointer is on the card.
    private var seenLine: String {
        var s = "Last seen: " + (user.lastSeen.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "never")
        if let a = user.address { s += hover ? " · IP: \(a)" : " · IP: hover to show" }
        return s
    }
}

private struct StatsUserAvatar: View {
    @EnvironmentObject var emby: Emby
    let user: StatsUserSummary
    var body: some View {
        let color = StatsUsersStyle.avatars[StatsUsersAggregate.colorIndex(user.name, count: StatsUsersStyle.avatars.count)]
        let initials = ZStack {
            Circle().fill(color.opacity(0.55))
            Text(StatsUsersAggregate.initials(user.name)).cvFont(15, weight: .bold).foregroundColor(.white)
        }
        Group {
            if let tag = user.imageTag, let url = URL(string: "\(emby.server)/Users/\(user.id)/Images/Primary?maxWidth=96&quality=80&tag=\(tag)") {
                CachedImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { initials }
            } else { initials }
        }
        .frame(width: 42, height: 42).clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
    }
}

private struct StatsUserBadge: View {
    let text: String, tint: Color
    var body: some View {
        Text(text).cvFont(10, weight: .bold).foregroundColor(.white).lineLimit(1)
            .padding(.horizontal, Glass3DTokens.Space.s).frame(height: 18)
            .background(Capsule().fill(tint.opacity(0.35)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 0.5))
    }
}

private struct StatsUserTile: View {
    let value: String, label: String
    var tint: Color? = nil
    var small = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).cvFont(small ? 13 : 18, weight: .heavy).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundColor(tint ?? Glass3DTokens.Grey.primary).modifier(Glass3DReadableText())
            Text(label).cvFont(10, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous)
            .fill(Color.white.opacity(Glass3DTokens.Fill.subtle)))
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous)
            .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.5))
        .help(value + " " + label.lowercased())
    }
}

/// "Play types:" a thin stacked bar (Direct play / Direct stream / Transcode) with the percents.
private struct StatsPlayTypesBar: View {
    let shares: StatsMethodShares
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            Text("Play types:").cvFont(Glass3DTokens.Text.meta - 1, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
            GeometryReader { g in
                HStack(spacing: 0) {
                    if shares.isEmpty { Color.white.opacity(0.1) }
                    else {
                        StatsUsersStyle.directPlay.frame(width: g.size.width * shares.directPlay)
                        StatsUsersStyle.directStream.frame(width: g.size.width * shares.directStream)
                        StatsUsersStyle.transcode.frame(width: g.size.width * shares.transcode)
                    }
                }
                .opacity(0.8).clipShape(Capsule())
            }
            .frame(height: 6)
            Text(shares.isEmpty ? "—" : shares.text).cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary)
                .lineLimit(1).fixedSize()
        }
        .help("Green: Direct play · Blue: Direct stream · Orange: Transcode")
    }
}
