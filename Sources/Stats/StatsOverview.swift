import SwiftUI

/// Activity → Overview ("Your stats"): hours and plays in the chosen range, simple bars, top 5 movies and shows.
struct StatsOverviewView: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        StatsGate(model: model) {
            VStack(alignment: .leading, spacing: 20) {
                StatsRangePills(range: $model.range)
                if model.overviewLoading && model.overview.isEmpty { SkeletonShimmer().padding(.vertical, 30) }
                else { StatsOverviewContent(plays: model.overview, range: model.range) }
            }
            .task(id: model.range) { await model.loadOverview() }
        }
    }
}

/// Shared by Overview and the Users tab's per-user drill-down.
struct StatsOverviewContent: View {
    let plays: [StatsPlay]
    let range: StatsRange

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if StatsAggregate.isFewData(plays) {
                StatsStateCard(symbol: "chart.bar.xaxis", title: plays.isEmpty ? "No playback recorded in this range" : "Only a few plays so far",
                               message: "Data is collected from now on: the Playback Reporting plugin records every play from when it was installed. Check back after some watching.")
            }
            if !plays.isEmpty {
                StatsHeroRow(plays: plays)
                StatsBarsCard(bars: StatsAggregate.bars(plays, range))
                StatsRecentRow(recent: StatsAggregate.recentlyWatched(plays))   // under the watched-time chart (owner)
                StatsTopRow(title: "Top movies", tops: StatsAggregate.topMovies(plays), show: false)
                StatsTopRow(title: "Top shows", tops: StatsAggregate.topShows(plays), show: true)
            }
        }
    }
}

/// 7 days · 30 days · 12 months · All (the same glass segment pill as the tabs).
struct StatsRangePills: View {
    @Binding var range: StatsRange
    var body: some View {
        let sel = Binding<Int>(get: { range.rawValue }, set: { range = StatsRange(rawValue: $0) ?? .month })
        Glass3DSegmentTabs(titles: StatsRange.allCases.map(\.label), selection: sel)
    }
}

private struct StatsHeroRow: View {
    let plays: [StatsPlay]
    var body: some View {
        let titles = Set(plays.map { $0.isEpisode ? "s:" + $0.displayTitle : "i:" + $0.itemId }).count
        HStack(spacing: 14) {
            StatsHero(value: StatsAggregate.hoursText(StatsAggregate.totalSeconds(plays)), label: "Watched")
            StatsHero(value: "\(plays.count)", label: plays.count == 1 ? "Play" : "Plays")
            StatsHero(value: "\(titles)", label: titles == 1 ? "Title" : "Titles")
        }
    }
}

private struct StatsHero: View {
    let value: String, label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).cvFont(30, weight: .heavy).modifier(Glass3DReadableText())
            Text(label).cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).statsCard()
    }
}

/// Plain bars (hours per day or per month), red accent, no grid lines.
private struct StatsBarsCard: View {
    let bars: [StatsBar]
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let top = max(1, bars.map(\.seconds).max() ?? 1)
        let showLabels = bars.count <= 14
        VStack(alignment: .leading, spacing: 10) {
            StatsHeading(text: "Time watched")
            HStack(alignment: .bottom, spacing: bars.count > 20 ? 3 : 8) {
                ForEach(bars) { b in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: Glass3DTokens.Radius.tag, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.accent(accentName), Theme.accent(accentName).opacity(0.55)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(height: max(b.seconds > 0 ? 3 : 1, 120 * CGFloat(b.seconds) / CGFloat(top)))
                            .opacity(b.seconds > 0 ? 1 : 0.25)
                        if showLabels {
                            Text(b.label).cvFont(10).foregroundColor(Glass3DTokens.Grey.tertiary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(b.label): \(StatsAggregate.hoursText(b.seconds))")
                }
            }
            .frame(height: showLabels ? 140 : 124, alignment: .bottom)
        }
        .statsCard()
    }
}

private struct StatsTopRow: View {
    let title: String
    let tops: [StatsTop]
    let show: Bool
    var body: some View {
        if !tops.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                StatsHeading(text: title)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(tops.enumerated()), id: \.element.id) { i, t in StatsTopTile(rank: i + 1, top: t, show: show) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Recently watched: the last 10 distinct titles in the range, newest first, as the Top 5's poster cards
/// (no rank; episodes collapsed to their series with "S2:E4" under the title).
private struct StatsRecentRow: View {
    let recent: [StatsRecent]
    var body: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                StatsHeading(text: "Recently watched")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(recent) { r in StatsTopTile(rank: nil, top: r.top, show: r.show, caption: r.caption) }
                    }
                    .padding(.bottom, 8)   // room for the poster shadow
                }
            }
        }
    }
}

/// A poster with its rank, title and time; click opens the movie or the show.
private struct StatsTopTile: View {
    @EnvironmentObject var emby: Emby
    let rank: Int?
    let top: StatsTop
    let show: Bool
    var caption: String? = nil   // Recently watched: replaces the time · plays line
    @State private var item: Item?
    @State private var missing = false

    var body: some View {
        Button { if let item { emby.openPage(item) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: posterURL) { img in img.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 130, height: 195)
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let rank {
                            Text("\(rank)").cvFont(13, weight: .heavy).foregroundColor(.white)
                                .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.55))).padding(6)
                        }
                    }
                    .g3Shadow(Glass3DTokens.shadowMedium)
                Text(top.title).cvFont(Glass3DTokens.Text.meta + 1, weight: .semibold).lineLimit(2)
                    .modifier(Glass3DReadableText())
                Text(caption ?? "\(StatsAggregate.hoursText(top.seconds)) · \(top.plays) \(top.plays == 1 ? "play" : "plays")")
                    .cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary)
                if missing { Text("Removed from library").cvFont(10).foregroundColor(Glass3DTokens.Grey.tertiary) }
            }
            .frame(width: 130, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .disabled(item == nil)
        .task(id: top.itemId) { await resolve() }
    }

    private var posterURL: URL? {
        if let item { return emby.image(show ? (item.SeriesId ?? item.Id) : item.Id, width: 300) }
        return show ? nil : emby.image(top.itemId, width: 300)
    }

    /// A show tile holds one of its episodes: open (and show) the series.
    private func resolve() async {
        guard let it = await emby.itemRecord(top.itemId) else { missing = true; return }
        if show, let sid = it.SeriesId, let series = await emby.itemRecord(sid) { item = series } else { item = it }
    }
}
