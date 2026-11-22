import SwiftUI

/// Activity → Insights (admins with Playback Reporting): a grid of glass cards, each one sentence with one big
/// number or a mini chart, over every user's plays in the range (30 days · 12 months · All).
struct StatsInsightsView: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject var model: StatsModel
    @ObservedObject var insights: InsightsModel

    var body: some View {
        StatsGate(model: model) {
            VStack(alignment: .leading, spacing: 20) {
                InsightsRangePills(range: $insights.range)
                if let h = InsightsRetention.hint(maxAge: insights.maxDataAge, need: insights.range == .month ? 2 : 12) {
                    InsightsHint(text: h)
                }
                if let d = insights.data, insights.dataRange == insights.range {
                    if d.count == 0 {
                        StatsStateCard(symbol: "lightbulb", title: "No playback recorded in this range",
                                       message: "Insights appear once people have watched something. Try a longer range.")
                    } else { InsightsGrid(data: d, range: insights.range) }
                } else if insights.loading || insights.data == nil { Spinner().frame(maxWidth: .infinity).padding(60) }
                else {
                    StatsStateCard(symbol: "exclamationmark.triangle", title: "Insights couldn't be loaded",
                                   message: "The server didn't answer. Open this tab again to retry.")
                }
            }
            .task(id: "\(insights.range.rawValue)|\(model.availability == .available)") { await insights.loadInsights(model, emby) }
        }
    }
}

/// 30 days · 12 months · All.
struct InsightsRangePills: View {
    @Binding var range: StatsRange
    var body: some View {
        let all = InsightsModel.ranges
        let sel = Binding<Int>(get: { all.firstIndex(of: range) ?? 0 }, set: { range = all[min(max($0, 0), all.count - 1)] })
        Glass3DSegmentTabs(titles: all.map(\.label), selection: sel)
    }
}

/// A one-line info card (retention, limited data).
struct InsightsHint: View {
    let text: String
    var symbol = "clock.arrow.circlepath"
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundColor(Glass3DTokens.Grey.secondary)
            Text(text).cvFont(Glass3DTokens.Text.meta + 1).foregroundColor(Glass3DTokens.Grey.secondary)
            Spacer(minLength: 0)
        }
        .statsCard()
    }
}

/// The cards. `perUser`: the Users drill-down (one user's plays: no "who" and no quiet users).
struct InsightsGrid: View {
    let data: InsightsData
    let range: StatsRange
    var perUser = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 16)], alignment: .leading, spacing: 16) {
            if let d = data.busiestDay {
                InsightCard(symbol: "calendar", title: "Busiest day", value: Insights.weekdayNames[d.index],
                            sentence: "\(StatsAggregate.hoursText(d.seconds)) watched on \(Insights.weekdayNames[d.index])s in this range.") {
                    InsightsMiniBars(values: data.weekdays, highlight: d.index, labels: StatsGraphsAggregate.weekdayNames.map { String($0.prefix(1)) })
                }
            }
            if let h = data.busiestHour {
                InsightCard(symbol: "clock", title: "Busiest hour", value: Insights.hourText(h.index),
                            sentence: "Most plays start between \(Insights.hourText(h.index)) and \(Insights.hourText((h.index + 1) % 24)).") {
                    InsightsMiniBars(values: data.hours, highlight: h.index, labels: (0..<24).map { $0 % 6 == 0 ? "\($0)" : "" })
                }
            }
            if let b = data.binge {
                InsightCard(symbol: "flame", title: "Most binged show", value: "\(b.episodes) episodes",
                            sentence: (perUser || b.user.isEmpty ? "" : "\(b.user) watched ") + "\(b.episodes) episodes of \(b.series) on \(Insights.dayText(b.day)).")
            }
            if let l = data.longest {
                InsightCard(symbol: "hourglass", title: "Longest session", value: StatsAggregate.durationText(l.seconds),
                            sentence: (perUser || l.userName.isEmpty ? "" : "\(l.userName): ") + "\(l.displayTitle) on \(Insights.dayText(l.day)).")
            }
            if !data.genres.isEmpty {
                InsightCard(symbol: "theatermasks", title: "Favourite genres", value: data.genres[0].label,
                            sentence: "Top genres by watch time.") { InsightsGenreBars(rows: data.genres) }
            }
            InsightCard(symbol: "film.stack", title: "Movies vs episodes",
                        value: "\(data.trend.movies) · \(data.trend.episodes)",
                        sentence: trendSentence) { InsightsTrendRow(trend: data.trend) }
            if data.split.total > 0 {
                InsightCard(symbol: "arrow.counterclockwise", title: "New vs rewatched", value: "\(data.split.newPercent)% new",
                            sentence: "\(data.split.new) first-time plays, \(data.split.rewatch) of items played before.") {
                    InsightsSplitBar(split: data.split)
                }
            }
            if let p = data.popular {
                InsightCard(symbol: "star", title: perUser ? "Most watched title" : "Most popular title", value: p.title,
                            sentence: perUser ? "\(p.plays) \(p.plays == 1 ? "play" : "plays") in this range."
                                : "Watched by \(p.users.count) \(p.users.count == 1 ? "user" : "users"): \(p.users.prefix(4).joined(separator: ", "))\(p.users.count > 4 ? "…" : "") · \(p.plays) plays.")
            }
            if !perUser && range != .all {
                InsightCard(symbol: "moon.zzz", title: "Quiet users", value: "\(data.quiet.count)",
                            sentence: data.quiet.isEmpty ? "Everyone who watched in the period before also watched in this one."
                                : "Watched before, nothing in this range: \(data.quiet.prefix(5).joined(separator: ", "))\(data.quiet.count > 5 ? "…" : "").")
            }
            if let f = data.finish {
                InsightCard(symbol: "flag.checkered", title: "Time to finish a movie", value: Insights.spanText(f.seconds),
                            sentence: "On average, from the first start to the last play, across \(f.movies) \(f.movies == 1 ? "movie" : "movies") watched in more than one sitting.")
            }
        }
    }

    private var trendSentence: String {
        let t = data.trend
        guard t.hasPrevious else { return "\(t.movies) movie and \(t.episodes) episode plays. No earlier period to compare with." }
        return "Movies \(Insights.changeText(t.moviesChange, current: t.movies)), episodes \(Insights.changeText(t.episodesChange, current: t.episodes)) vs the period before."
    }
}

/// One insight: icon + title, a big value, one sentence and an optional mini chart. Hover: the Users card's
/// gentle lift and brighter edge.
struct InsightCard<Accessory: View>: View {
    let symbol: String
    let title: String
    let value: String
    let sentence: String
    @ViewBuilder var accessory: () -> Accessory
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).cvFont(13, weight: .semibold).foregroundColor(Theme.accent(accentName))
                Text(title).cvFont(Glass3DTokens.Text.meta, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
            }
            Text(value).cvFont(26, weight: .heavy).lineLimit(1).minimumScaleFactor(0.5).modifier(Glass3DReadableText())
            Text(sentence).cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.primary)
                .fixedSize(horizontal: false, vertical: true)
            accessory().padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .statsCard()
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
            .strokeBorder(Color.white.opacity(hover ? Glass3DTokens.Stroke.strong : 0), lineWidth: 0.75))
        .scaleEffect(hover ? 1.015 : 1)
        .animation(Glass3DTokens.Motion.fast, value: hover)
        .onHover { hover = $0 }
    }
}

extension InsightCard where Accessory == EmptyView {
    init(symbol: String, title: String, value: String, sentence: String) {
        self.init(symbol: symbol, title: title, value: value, sentence: sentence) { EmptyView() }
    }
}

/// Small accent bars (weekdays, hours, months), the highlighted one full strength.
struct InsightsMiniBars: View {
    let values: [Int]
    var highlight: Int?
    var labels: [String] = []
    var height: CGFloat = 46
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let top = max(1, values.max() ?? 1), accent = Theme.accent(accentName)
        HStack(alignment: .bottom, spacing: values.count > 12 ? 2 : 5) {
            ForEach(values.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(accent.opacity(i == highlight ? 1 : 0.45))
                        .frame(height: max(values[i] > 0 ? 3 : 1, height * CGFloat(values[i]) / CGFloat(top)))
                        .opacity(values[i] > 0 ? 1 : 0.3)
                    if i < labels.count {
                        Text(labels[i]).cvFont(9).foregroundColor(Glass3DTokens.Grey.tertiary).lineLimit(1).fixedSize()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height + (labels.isEmpty ? 0 : 14), alignment: .bottom)
    }
}

private struct InsightsGenreBars: View {
    let rows: [InsightsCount]
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let top = max(1, rows.map(\.seconds).max() ?? 1)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text(r.label).cvFont(Glass3DTokens.Text.meta - 1, weight: .medium).foregroundColor(Glass3DTokens.Grey.primary)
                        .lineLimit(1).frame(width: 96, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Theme.accent(accentName).opacity(0.8))
                            .frame(width: max(4, g.size.width * CGFloat(r.seconds) / CGFloat(top)))
                    }
                    .frame(height: 6)
                    Text(StatsAggregate.hoursText(r.seconds)).cvFont(10).foregroundColor(Glass3DTokens.Grey.secondary)
                        .monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
    }
}

private struct InsightsTrendRow: View {
    let trend: InsightsTrend
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        HStack(spacing: 16) {
            StatsLegendChip(color: Theme.accent(accentName), text: "Movies \(Insights.changeText(trend.moviesChange, current: trend.movies))")
            StatsLegendChip(color: StatsUsersStyle.episodes, text: "Episodes \(Insights.changeText(trend.episodesChange, current: trend.episodes))")
            Spacer(minLength: 0)
        }
        .opacity(trend.hasPrevious ? 1 : 0.6)
    }
}

private struct InsightsSplitBar: View {
    let split: InsightsSplit
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                Theme.accent(accentName).frame(width: g.size.width * CGFloat(split.new) / CGFloat(max(1, split.total)))
                StatsUsersStyle.episodes
            }
            .opacity(0.8).clipShape(Capsule())
        }
        .frame(height: 6)
        .help("Accent: first-time plays · Blue: rewatches")
    }
}
