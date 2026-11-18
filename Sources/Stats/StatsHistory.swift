import SwiftUI

/// Now Playing → History: your plays grouped by day (last 90 days, 7 active days at a time).
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
                    ForEach(StatsAggregate.groupByDay(model.history)) { StatsDaySection(group: $0) }
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

private struct StatsDaySection: View {
    let group: StatsDayGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .cvFont(Glass3DTokens.Text.cardTitle, weight: .bold).modifier(Glass3DReadableText())
            VStack(spacing: 2) {
                ForEach(group.plays) { StatsHistoryRow(play: $0) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
                .fill(Color.white.opacity(Glass3DTokens.Fill.subtle)))
            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
                .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.75))
        }
    }
}

private struct StatsHistoryRow: View {
    @EnvironmentObject var emby: Emby
    let play: StatsPlay
    @State private var hover = false

    var body: some View {
        Button { StatsOpen.item(play.itemId, emby) } label: {
            HStack(spacing: 12) {
                StatsThumb(id: play.itemId, wide: play.isEpisode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(play.displayTitle).cvFont(Glass3DTokens.Text.cardTitle - 1, weight: .semibold).lineLimit(1)
                        .modifier(Glass3DReadableText())
                    if let sub = play.displaySubtitle {
                        Text(sub).cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                    }
                    Text([play.client, play.device].filter { !$0.isEmpty }.joined(separator: " · "))
                        .cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(play.start.formatted(date: .omitted, time: .shortened))
                        .cvFont(Glass3DTokens.Text.meta, weight: .semibold).modifier(Glass3DReadableText())
                    Text(StatsAggregate.durationText(play.seconds))
                        .cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary)
                    StatsMethodPill(method: play.method)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous)
                .fill(Color.white.opacity(hover ? Glass3DTokens.Fill.strong : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .onHover { hover = $0 }
    }
}

/// Direct play / Direct stream / Transcode, tinted as on the Now Playing cards.
private struct StatsMethodPill: View {
    let method: String
    var body: some View {
        let tint = NowPlayingStyle.color(NowPlayingStyle.playMethod(method.lowercased().hasPrefix("transcode") ? "transcode" : method).tint)
        Text(StatsAggregate.methodText(method)).cvFont(10, weight: .semibold).lineLimit(1)
            .foregroundColor(.white)
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(tint.opacity(0.35)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 0.5))
    }
}
