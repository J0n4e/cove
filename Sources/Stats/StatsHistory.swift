import SwiftUI

/// Activity → History: your plays grouped by day (last 90 days, 7 active days at a time). One glass card per day
/// with a clear header ("Today", "Yesterday", "Mon 16 Nov") and a small summary ("3 plays · 2h 40m"),
/// then the day's titles as poster cards (same title played twice that day → one card with "×2").
struct StatsHistoryView: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        StatsGate(model: model) {
            VStack(alignment: .leading, spacing: 18) {
                if model.historyLoading && model.history.isEmpty { SkeletonShimmer().padding(.vertical, 30) }
                else if model.history.isEmpty {
                    StatsStateCard(symbol: "clock.arrow.circlepath", title: "No plays in the last \(StatsModel.historyRange) days",
                                   message: "Data is collected from now on: plays longer than a minute show here once the Playback Reporting plugin has recorded them.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(StatsAggregate.groupByDay(model.history)) { StatsDayCard(group: $0) }
                    }
                    if model.hasMoreHistory {
                        Button { Task { await model.loadMoreHistory() } } label: {
                            Text(model.historyLoading ? "Loading…" : "Show more")
                                .cvFont(Glass3DTokens.Text.meta + 1, weight: .semibold)
                                .padding(.horizontal, 18).frame(height: 32).classicGlassPill(iconOnly: false)
                        }
                        .buttonStyle(.plainHand).disabled(model.historyLoading)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .task { await model.loadHistory() }
        }
    }
}

/// One day: header + summary, then the day's titles as poster cards in a wrapping grid, in a glass card.
private struct StatsDayCard: View {
    let group: StatsDayGroup
    @AppStorage("textSize") private var textSize = "default"
    var body: some View {
        let w = 150 * TextScale.inApp(textSize)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatsHistoryText.dayTitle(group.date)).cvFont(Glass3DTokens.Text.cardTitle + 2, weight: .bold)
                    .modifier(Glass3DReadableText())
                Spacer(minLength: 8)
                Text(StatsHistoryText.daySummary(group.plays)).cvFont(Glass3DTokens.Text.meta, weight: .medium)
                    .foregroundColor(Glass3DTokens.Grey.secondary)
            }
            .padding(.horizontal, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: w, maximum: w + 30), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 18) {
                ForEach(StatsHistoryText.cards(group.plays)) { StatsHistoryTile(card: $0) }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
        .statsCard()
    }
}

/// One title played that day: a 2:3 poster (episodes show their series' poster) with the device + method in a
/// corner, the title, and one grey line "S2:E4 · 20:15 · 45 min". Click opens the played item.
private struct StatsHistoryTile: View {
    @EnvironmentObject var emby: Emby
    let card: StatsHistoryCard
    @State private var posterId: String?
    @State private var hover = false

    var body: some View {
        let play = card.play
        Button { StatsOpen.item(play.itemId, emby) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.white.opacity(0.08)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let url = posterURL {
                            CachedImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) }
                                placeholder: { Color.clear }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if card.count > 1 {
                            Text("×\(card.count)").cvFont(Glass3DTokens.Text.meta - 1, weight: .heavy).foregroundColor(.white)
                                .padding(.horizontal, 7).frame(height: 20).background(Capsule().fill(.black.opacity(0.6))).padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { StatsTileBadge(play: play).padding(6) }
                    .g3Shadow(Glass3DTokens.shadowMedium)
                    .modifier(HoverLift(hover: hover))
                Text(play.displayTitle).cvFont(Glass3DTokens.Text.meta + 1).lineLimit(2)
                    .modifier(Glass3DReadableText())
                Text(StatsHistoryText.caption(card)).cvFont(Glass3DTokens.Text.meta - 1) { $0.monospacedDigit() }
                    .foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .onHover { hover = $0 }
        .zIndex(hover ? 1 : 0)
        .task(id: play.itemId) {
            guard play.isEpisode else { return }
            if let it = await emby.itemRecord(play.itemId) { posterId = it.SeriesId ?? it.Id }
        }
    }

    private var posterURL: URL? {
        if card.play.isEpisode {
            guard let posterId else { return nil }
            return emby.image(posterId, width: 300)
        }
        return emby.image(card.play.itemId, width: 300)
    }
}

/// Device icon + DP/DS/TC dot in a small dark corner pill (tooltip: app · device · method).
private struct StatsTileBadge: View {
    let play: StatsPlay
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: StatsHistoryText.deviceIcon(play)).cvFont(Glass3DTokens.Text.meta - 2).foregroundColor(.white)
            Circle().fill(NowPlayingStyle.color(StatsHistoryText.methodTint(play.method))).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(Capsule().fill(.black.opacity(0.6)))
        .tip(StatsHistoryText.badgeTip(play))
    }
}

/// History's text rules (tested in StatsHistoryPolishTests).
enum StatsHistoryText {
    /// "Today", "Yesterday", else "Mon 16 Nov" (plus the year when it isn't this year).
    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "EEE d MMM" : "EEE d MMM yyyy"
        return f.string(from: date)
    }

    /// "3 plays · 2h 40m" / "1 play · 45m".
    static func daySummary(_ plays: [StatsPlay]) -> String {
        let s = StatsAggregate.totalSeconds(plays)
        let h = s / 3600, m = (s % 3600) / 60
        let dur = h > 0 ? "\(h)h \(m)m" : "\(s > 0 ? max(m, 1) : 0)m"
        return "\(plays.count) play\(plays.count == 1 ? "" : "s") · \(dur)"
    }

    /// Episodes: "S2:E4 · Episode name"; anything else: its type ("Movie", "Audio"); nil when unknown.
    static func secondLine(_ play: StatsPlay) -> String? {
        if let sub = play.displaySubtitle { return sub }
        return play.type.isEmpty ? nil : play.type
    }

    /// The day's plays as poster cards, newest first; repeat plays of the same item merge into one card.
    static func cards(_ plays: [StatsPlay]) -> [StatsHistoryCard] {
        var order: [String] = [], byItem: [String: [StatsPlay]] = [:]
        for p in plays.sorted(by: { $0.start > $1.start }) {
            if byItem[p.itemId] == nil { order.append(p.itemId) }
            byItem[p.itemId, default: []].append(p)
        }
        return order.compactMap { id in
            guard let ps = byItem[id], let first = ps.first else { return nil }
            return StatsHistoryCard(play: first, count: ps.count, seconds: StatsAggregate.totalSeconds(ps))
        }
    }

    /// "S2:E4 · 20:15 · 45 min" (episodes) / "20:15 · 1 h 52 min" (anything else); time = the latest play.
    static func caption(_ card: StatsHistoryCard, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = timeZone; f.dateFormat = "HH:mm"
        var parts = [f.string(from: card.play.start), length(card.seconds)]
        if let e = card.play.episode { parts.insert("S\(e.season):E\(e.number)", at: 0) }
        return parts.joined(separator: " · ")
    }

    /// "45 min", "1 h 52 min", "2 h".
    static func length(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h == 0 { return "\(max(1, m)) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "Cove · Mac · Direct play".
    static func badgeTip(_ play: StatsPlay) -> String {
        [play.client, play.device, StatsAggregate.methodText(play.method)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func deviceIcon(_ play: StatsPlay) -> String {
        let i = NowPlayingStyle.clientIcon(client: play.client, device: play.device)
        return i == "macbook" ? "laptopcomputer" : i
    }
    static func deviceTip(_ play: StatsPlay) -> String {
        [play.client, play.device].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func methodShort(_ m: String) -> String {
        switch StatsUsersAggregate.methodKind(m) {
        case .directPlay: return "DP"
        case .directStream: return "DS"
        case .transcode: return "TC"
        case nil: return "—"
        }
    }
    static func methodTint(_ m: String) -> NowPlayingStyle.Tint {
        switch StatsUsersAggregate.methodKind(m) {
        case .transcode: return .orange
        case .directStream: return .blue
        default: return .green
        }
    }
}

/// One poster card in a History day: the newest play of the item, how often it was played that day, total time.
struct StatsHistoryCard: Identifiable, Hashable, Sendable {
    let play: StatsPlay
    let count: Int
    let seconds: Int
    var id: String { play.itemId }
}
