import SwiftUI

/// Activity → Libraries (admins with Playback Reporting): one glass card per movie / TV / music library, most
/// watch time in the range first: size, plays and watch time, top 3 titles and the latest additions.
struct StatsLibrariesView: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject var model: StatsModel

    var body: some View {
        StatsGate(model: model) {
            VStack(alignment: .leading, spacing: 20) {
                StatsRangePills(range: $model.range)
                if model.librariesRange == model.range && !model.libraries.isEmpty {
                    if model.librariesTruncated {
                        Text("Only the \(StatsModel.libraryMapLimit.formatted()) most recently played titles are matched to their library in this range.")
                            .cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                    LazyVStack(alignment: .center, spacing: 14) {
                        ForEach(model.libraries) { StatsLibraryCard(usage: $0).frame(maxWidth: 860) }
                    }
                    .frame(maxWidth: .infinity)
                } else if model.librariesLoading || model.librariesRange == nil {
                    Spinner().frame(maxWidth: .infinity).padding(60)
                } else {
                    StatsStateCard(symbol: "books.vertical", title: "No libraries found",
                                   message: "Movie, TV and music libraries you can see show here.")
                }
            }
            .task(id: model.range) { await model.loadLibraries(emby) }
        }
    }
}

private struct StatsLibraryCard: View {
    let usage: StatsLibraryUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).cvFont(20, weight: .semibold).foregroundColor(Glass3DTokens.Grey.primary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(Glass3DTokens.Fill.strong)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
                VStack(alignment: .leading, spacing: 3) {
                    Text(usage.lib.name).cvFont(Glass3DTokens.Text.cardTitle + 1, weight: .bold).lineLimit(1)
                        .modifier(Glass3DReadableText())
                    Text(usage.counts.isEmpty ? "—" : StatsLibrariesAggregate.countsText(usage.counts))
                        .cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StatsLibraryStat(value: "\(usage.plays)", label: usage.plays == 1 ? "Play" : "Plays")
                StatsLibraryStat(value: StatsAggregate.hoursText(usage.seconds), label: "Watch time")
            }
            if !usage.tops.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Most watched").cvFont(Glass3DTokens.Text.meta, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(usage.tops.enumerated()), id: \.element.id) { i, t in StatsLibraryTopTile(rank: i + 1, top: t) }
                        Spacer(minLength: 0)
                    }
                }
            }
            StatsRecentlyAddedStrip(libraryId: usage.lib.id)
        }
        .statsCard()
    }

    private var icon: String {
        switch (usage.lib.kind ?? "").lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "books.vertical"
        }
    }
}

private struct StatsLibraryStat: View {
    let value: String, label: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).cvFont(18, weight: .heavy).lineLimit(1).modifier(Glass3DReadableText())
            Text(label).cvFont(10, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
        }
        .frame(minWidth: 70, alignment: .trailing)
    }
}

/// A poster with its rank, title and time; click opens the movie, show or song.
private struct StatsLibraryTopTile: View {
    @EnvironmentObject var emby: Emby
    let rank: Int
    let top: StatsLibraryTop
    @State private var item: Item?

    var body: some View {
        Button { if let item { emby.openPage(item) } } label: {
            VStack(alignment: .leading, spacing: 5) {
                CachedImage(url: poster) { img in img.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("\(rank)").cvFont(12, weight: .heavy).foregroundColor(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(.black.opacity(0.55))).padding(5)
                    }
                    .g3Shadow(Glass3DTokens.shadowMedium)
                Text(top.top.title).cvFont(Glass3DTokens.Text.meta, weight: .semibold).lineLimit(2).modifier(Glass3DReadableText())
                Text("\(StatsAggregate.hoursText(top.top.seconds)) · \(top.top.plays) \(top.top.plays == 1 ? "play" : "plays")")
                    .cvFont(Glass3DTokens.Text.meta - 2).foregroundColor(Glass3DTokens.Grey.secondary)
            }
            .frame(width: 96, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .disabled(item == nil)
        .task(id: top.top.itemId) {
            guard let it = await emby.itemRecord(top.top.itemId) else { return }
            if top.show, let sid = it.SeriesId, let s = await emby.itemRecord(sid) { item = s } else { item = it }
        }
    }

    private var poster: URL? {
        if let item { return emby.image(top.show ? (item.SeriesId ?? item.Id) : item.Id, width: 240) }
        return top.show ? nil : emby.image(top.top.itemId, width: 240)
    }
}

/// The library's latest 8 additions (the server's Latest list), click opens them.
private struct StatsRecentlyAddedStrip: View {
    @EnvironmentObject var emby: Emby
    let libraryId: String
    @State private var items: [Item] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recently added").cvFont(Glass3DTokens.Text.meta, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(items) { it in
                                Button { emby.openPage(it) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        CachedImage(url: emby.image(it.posterId, width: 200)) { img in img.resizable().aspectRatio(contentMode: .fill) }
                                            placeholder: { Color.white.opacity(0.08) }
                                            .frame(width: 72, height: 108)
                                            .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous)
                                                .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.5))
                                        Text(it.heroTitle).cvFont(10, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 72, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plainHand)
                                .help(it.heroTitle)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .task(id: libraryId) {
            let r: [Item]? = try? await emby.get("/Users/\(emby.userId)/Items/Latest", ["ParentId": libraryId, "Limit": "8"])
            items = Array((r ?? []).prefix(8))
        }
    }
}
