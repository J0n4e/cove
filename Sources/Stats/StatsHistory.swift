import SwiftUI

/// Activity → History: your plays grouped by day (last 90 days, 7 active days at a time). One glass card per day
/// with a clear header ("Today", "Yesterday", "Mon 16 Nov") and a small summary ("3 plays · 2h 40m"); calm rows:
/// thumb, title over a grey second line, the device and play method as small icons, start time over duration.
struct StatsHistoryView: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        StatsGate(model: model) {
            VStack(alignment: .leading, spacing: 18) {
                if model.historyLoading && model.history.isEmpty { Spinner().frame(maxWidth: .infinity).padding(60) }
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

/// One day: header + summary, then the plays with thin dividers, in a glass card.
private struct StatsDayCard: View {
    let group: StatsDayGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatsHistoryText.dayTitle(group.date)).cvFont(Glass3DTokens.Text.cardTitle + 2, weight: .bold)
                    .modifier(Glass3DReadableText())
                Spacer(minLength: 8)
                Text(StatsHistoryText.daySummary(group.plays)).cvFont(Glass3DTokens.Text.meta, weight: .medium)
                    .foregroundColor(Glass3DTokens.Grey.secondary)
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(Array(group.plays.enumerated()), id: \.element.id) { i, play in
                    if i > 0 {
                        Rectangle().fill(Color.white.opacity(Glass3DTokens.Stroke.subtle)).frame(height: 0.5).padding(.horizontal, 8)
                    }
                    StatsHistoryRow(play: play)
                }
            }
        }
        .statsCard()
    }
}

private struct StatsHistoryRow: View {
    @EnvironmentObject var emby: Emby
    let play: StatsPlay
    @State private var hover = false
    @AppStorage("textSize") private var textSize = "default"

    var body: some View {
        Button { StatsOpen.item(play.itemId, emby) } label: {
            HStack(spacing: 12) {
                StatsThumb(id: play.itemId, wide: play.isEpisode, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(play.displayTitle).cvFont(Glass3DTokens.Text.cardTitle - 1, weight: .semibold).lineLimit(1)
                        .modifier(Glass3DReadableText())
                    if let sub = StatsHistoryText.secondLine(play) {
                        Text(sub).cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                StatsRowIcons(play: play)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(play.start.formatted(date: .omitted, time: .shortened))
                        .cvFont(Glass3DTokens.Text.meta, weight: .semibold) { $0.monospacedDigit() }
                        .modifier(Glass3DReadableText())
                    Text(StatsAggregate.durationText(play.seconds))
                        .cvFont(Glass3DTokens.Text.meta - 1) { $0.monospacedDigit() }
                        .foregroundColor(Glass3DTokens.Grey.secondary)
                }
                .lineLimit(1)
                .frame(minWidth: 70 * TextScale.inApp(textSize), alignment: .trailing)   // one column for every row
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous)
                .fill(Color.white.opacity(hover ? Glass3DTokens.Fill.strong : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
    }
}

/// The device type as an SF Symbol (tooltip: app · device) and the play method as a tiny DP/DS/TC pill
/// (tooltip: the full method), in fixed slots so the rows line up.
private struct StatsRowIcons: View {
    let play: StatsPlay
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: StatsHistoryText.deviceIcon(play))
                .cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary)
                .frame(width: 20)
                .tip(StatsHistoryText.deviceTip(play))
            StatsMethodPill(method: play.method)
        }
    }
}

/// DP / DS / TC, tinted as on the Now Playing cards.
private struct StatsMethodPill: View {
    let method: String
    var body: some View {
        let tint = NowPlayingStyle.color(StatsHistoryText.methodTint(method))
        Text(StatsHistoryText.methodShort(method)).cvFont(9, weight: .bold).lineLimit(1)
            .foregroundColor(.white)
            .frame(minWidth: 26).frame(height: 16)
            .background(Capsule().fill(tint.opacity(0.35)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 0.5))
            .tip(StatsAggregate.methodText(method))
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
