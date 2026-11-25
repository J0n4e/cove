import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Activity → Year in review (every user, their own year; admins with the plugin can pick a user): a scrollable
/// story of big glass cards, plus "Save as image" / "Copy image" (a 1080 × 1920 share card).
struct StatsYearReviewView: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject var model: StatsModel
    @ObservedObject var insights: InsightsModel
    @State private var sharing = false

    var body: some View {
        Group {
            if model.availability == nil { SkeletonShimmer().padding(.vertical, 30).skeletonCrossfade() }
            else { content }
        }
        .task(id: "\(model.availability.map { "\($0)" } ?? "")|\(emby.server)|\(emby.userId)") {
            guard model.availability != nil else { return }
            await insights.prepareYear(model, emby)
        }
        .task(id: "\(insights.yearKey)|\(insights.years.count)") {
            guard model.availability != nil, !insights.years.isEmpty else { return }
            await insights.loadYear(model, emby)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.xl) {
            HStack(spacing: 12) {
                // The year as a dropdown pill too (owner), same look as the user picker
                if insights.years.count > 1 {
                    YearPickerMenu(years: insights.years, selected: Binding(get: { insights.year }, set: { insights.year = $0 }))
                }
                // Admins: one compact dropdown for the user instead of a pill with every name (owner)
                if model.availability == .available && insights.users.count > 1 {
                    YearUserMenu(users: insights.users.map { ($0.id, $0.name) },
                                 selected: Binding(get: { insights.yearUserId }, set: { insights.yearUserId = $0 }))
                }
                Spacer(minLength: 0)
                if let r = insights.review, insights.reviewKey == insights.yearKey, !r.isEmpty {
                    YearShareButton(label: "Copy image", symbol: "doc.on.doc", busy: sharing) { share(r, save: false) }
                    YearShareButton(label: "Save as image", symbol: "square.and.arrow.down", busy: sharing) { share(r, save: true) }
                }
            }
            if insights.limited {
                InsightsHint(text: "Built from what this server marks as played (each item once, on its last play date). Full stats with every play, devices and binges need an admin account and the Playback Reporting plugin.",
                             symbol: "info.circle")
            } else if let h = InsightsRetention.yearHint(maxAge: insights.maxDataAge, year: insights.year) {
                InsightsHint(text: h + " — this year is incomplete.")
            }
            if let r = insights.review, insights.reviewKey == insights.yearKey {
                if r.isEmpty {
                    StatsStateCard(symbol: "sparkles", title: "Nothing watched in \(String(r.year))",
                                   message: "Plays from this year show here as soon as there are some.")
                } else { YearStory(review: r, limited: insights.limited) }
            } else { SkeletonShimmer().padding(.vertical, 30).skeletonCrossfade() }
        }
    }

    private var userName: String {
        insights.users.first { $0.id == insights.yearUserId }?.name ?? ""
    }

    private func share(_ r: YearReview, save: Bool) {
        guard !sharing else { return }
        sharing = true
        let name = userName
        Task {
            defer { sharing = false }
            let posters = await YearShare.posters(r, emby: emby)
            guard let png = YearShare.png(review: r, userName: name, posters: posters,
                                          accent: Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red")) else { return }
            if save {
                let panel = NSSavePanel()
                panel.title = "Save Year in Review"
                panel.nameFieldStringValue = "Cove Year in Review \(r.year).png"
                panel.allowedContentTypes = [.png]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? png.write(to: url, options: .atomic)
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(png, forType: .png)
                if let img = NSImage(data: png), let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        }
    }
}

private struct YearShareButton: View {
    let label: String, symbol: String, busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol).cvFont(Glass3DTokens.Text.meta + 1, weight: .semibold)
                .padding(.horizontal, Glass3DTokens.Space.l).frame(height: 30).classicGlassPill(iconOnly: false)
        }
        .buttonStyle(.plainHand).disabled(busy).opacity(busy ? 0.6 : 1)
    }
}

/// The story: big glass cards, one highlight each.
private struct YearStory: View {
    let review: YearReview
    let limited: Bool
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        let r = review
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
                Text("Your \(String(r.year))").cvFont(34, weight: .heavy).modifier(Glass3DReadableText())
                HStack(spacing: Glass3DTokens.Space.l) {
                    YearBig(value: r.hoursText, label: "Hours watched")
                    YearBig(value: "\(r.movies)", label: r.movies == 1 ? "Movie" : "Movies")
                    YearBig(value: "\(r.episodes)", label: r.episodes == 1 ? "Episode" : "Episodes")
                    YearBig(value: "\(r.activeDays)", label: r.activeDays == 1 ? "Day with a play" : "Days with a play")
                }
            }
            if !r.topMovies.isEmpty {
                YearCard(title: "Top movies") {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(r.topMovies.enumerated()), id: \.element.id) { i, t in
                            YearPoster(rank: i + 1, title: t.title, itemId: t.itemId, show: false,
                                       caption: limited ? nil : StatsAggregate.hoursText(t.seconds))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if !r.topShows.isEmpty {
                YearCard(title: "Top shows") {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(r.topShows.enumerated()), id: \.element.id) { i, s in
                            YearPoster(rank: i + 1, title: s.top.title, itemId: s.top.itemId, show: true,
                                       caption: "\(s.episodes) \(s.episodes == 1 ? "episode" : "episodes")")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            YearCard(title: "Busiest month") {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
                    if let m = r.busiestMonth {
                        Text("\(Insights.monthNames[m]) · \(StatsAggregate.hoursText(r.months[m]))").cvFont(22, weight: .heavy)
                            .modifier(Glass3DReadableText())
                    }
                    InsightsMiniBars(values: r.months, highlight: r.busiestMonth,
                                     labels: Insights.monthNames.map { String($0.prefix(3)) }, height: 90)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16)], alignment: .leading, spacing: 16) {
                if let g = r.topGenre { YearFact(symbol: "theatermasks", title: "Top genre", value: g, sentence: "What you watched most.") }
                if let w = r.weekday {
                    YearFact(symbol: "calendar", title: "Favourite day & time",
                             value: Insights.weekdayNames[w] + (r.hour.map { " · \(Insights.hourText($0))" } ?? ""),
                             sentence: limited ? "When you usually finished things." : "When you watched the most.")
                }
                if let b = r.binge {
                    YearFact(symbol: "flame", title: "Longest binge", value: "\(b.episodes) episodes",
                             sentence: "\(b.series) on \(Insights.dayText(b.day)).")
                }
                if let d = r.device { YearFact(symbol: "tv", title: "Device used most", value: d, sentence: "Your go-to screen this year.") }
                if let f = r.first {
                    YearFact(symbol: "sunrise", title: "First thing watched", value: f.displayTitle,
                             sentence: [f.displaySubtitle, Insights.dayText(f.day)].compactMap { $0 }.joined(separator: " · "))
                }
                if let l = r.last, l.id != r.first?.id {
                    YearFact(symbol: "sunset", title: "Latest thing watched", value: l.displayTitle,
                             sentence: [l.displaySubtitle, Insights.dayText(l.day)].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }
}

private struct YearBig: View {
    let value: String, label: String
    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
            Text(value).cvFont(40, weight: .heavy).lineLimit(1).minimumScaleFactor(0.5).modifier(Glass3DReadableText())
            Text(label).cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).statsCard()
    }
}

private struct YearCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsHeading(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).statsCard()
    }
}

private struct YearFact: View {
    let symbol: String, title: String, value: String, sentence: String
    var body: some View {
        InsightCard(symbol: symbol, title: title, value: value, sentence: sentence)
    }
}

/// A poster with rank, title and caption; click opens the movie or the show.
private struct YearPoster: View {
    @EnvironmentObject var emby: Emby
    let rank: Int
    let title: String
    let itemId: String
    let show: Bool
    let caption: String?
    @State private var item: Item?

    var body: some View {
        Button { if let item { emby.openPage(item) } } label: {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                CachedImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("\(rank)").cvFont(13, weight: .heavy).foregroundColor(.white)
                            .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.55))).padding(Glass3DTokens.Space.s)
                    }
                    .g3Shadow(Glass3DTokens.shadowMedium)
                Text(title).cvFont(Glass3DTokens.Text.meta + 1, weight: .semibold).lineLimit(2).modifier(Glass3DReadableText())
                if let caption { Text(caption).cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary) }
            }
            .frame(width: 120, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .disabled(item == nil)
        .task(id: itemId) {
            guard let it = await emby.itemRecord(itemId) else { return }
            if show, let sid = it.SeriesId, let s = await emby.itemRecord(sid) { item = s } else { item = it }
        }
    }

    private var url: URL? {
        if let item { return emby.image(item.Id, width: 300) }
        return show ? nil : emby.image(itemId, width: 300)
    }
}

// MARK: - Share card (1080 × 1920 PNG)

@MainActor
enum YearShare {
    static let size = CGSize(width: 1080, height: 1920)

    /// Poster pictures for the card, loaded before rendering (ImageRenderer draws one pass, no async images):
    /// movies then shows, nil where a picture is missing.
    static func posters(_ r: YearReview, emby: Emby) async -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for t in r.topMovies {
            if let u = emby.image(t.itemId, width: 300), let img = await ImageCache.shared.image(u) { out[t.id] = img }
        }
        for s in r.topShows {
            let sid = await emby.itemRecord(s.top.itemId)?.SeriesId ?? s.top.itemId
            if let u = emby.image(sid, width: 300), let img = await ImageCache.shared.image(u) { out[s.id] = img }
        }
        return out
    }

    /// The card as an image exactly `size` pixels big.
    static func render(review: YearReview, userName: String, posters: [String: NSImage], accent: Color) -> CGImage? {
        let card = YearShareCard(review: review, userName: userName, posters: posters, accent: accent)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: card)
        r.scale = 1
        r.proposedSize = ProposedViewSize(size)
        return r.cgImage
    }

    static func png(review: YearReview, userName: String, posters: [String: NSImage], accent: Color) -> Data? {
        guard let cg = render(review: review, userName: userName, posters: posters, accent: accent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// The tall share card: dark Glass3D background with an accent glow, the big numbers, poster rows, highlights.
struct YearShareCard: View {
    let review: YearReview
    let userName: String
    let posters: [String: NSImage]
    let accent: Color

    var body: some View {
        let r = review
        ZStack {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 900)
            RadialGradient(colors: [accent.opacity(0.25), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 800)
            VStack(alignment: .leading, spacing: 44) {
                VStack(alignment: .leading, spacing: 8) {
                    // Share image (ImageRenderer at a fixed pixel size): fixed fonts on purpose, not cvFont
                    Text("YEAR IN REVIEW").font(.system(size: 30, weight: .bold)).tracking(6).foregroundColor(accent)
                    Text(String(r.year)).font(.system(size: 150, weight: .heavy)).foregroundColor(.white)
                    if !userName.isEmpty { Text(userName).font(.system(size: 40, weight: .semibold)).foregroundColor(.white.opacity(0.75)) }
                }
                VStack(spacing: 22) {
                    HStack(spacing: 22) { tile(r.hoursText, "Hours watched"); tile("\(r.movies)", "Movies") }
                    HStack(spacing: 22) { tile("\(r.episodes)", "Episodes"); tile("\(r.activeDays)", "Days with a play") }
                }
                if !r.topMovies.isEmpty { posterRow("Top movies", r.topMovies.map { ($0.id, $0.title) }) }
                if !r.topShows.isEmpty { posterRow("Top shows", r.topShows.map { ($0.id, $0.top.title) }) }
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
                    if let g = r.topGenre { line("Top genre", g) }
                    if let m = r.busiestMonth { line("Busiest month", Insights.monthNames[m]) }
                    if let b = r.binge { line("Longest binge", "\(b.episodes) episodes of \(b.series)") }
                }
                Spacer(minLength: 0)
                Text("Made with Cove").font(.system(size: 26, weight: .medium)).foregroundColor(.white.opacity(0.45))
            }
            .padding(80)
            .frame(width: YearShare.size.width, height: YearShare.size.height, alignment: .topLeading)
        }
        .frame(width: YearShare.size.width, height: YearShare.size.height)
        .clipped()
    }

    private func tile(_ value: String, _ label: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.shareCard, style: .continuous)
        return VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
            Text(value).font(.system(size: 76, weight: .heavy)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 28, weight: .medium)).foregroundColor(.white.opacity(0.7))
        }
        .padding(30).frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.white.opacity(0.07)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5))
    }

    private func posterRow(_ title: String, _ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 34, weight: .bold)).foregroundColor(.white)
            HStack(spacing: 18) {
                ForEach(Array(items.prefix(5)), id: \.0) { item in
                    let (id, name) = item
                    ZStack {
                        Color.white.opacity(0.08)
                        if let img = posters[id] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                        else { Text(name).font(.system(size: 20, weight: .semibold)).foregroundColor(.white.opacity(0.7)).padding(Glass3DTokens.Space.m) }
                    }
                    .frame(width: 166, height: 249)
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.hero, style: .continuous))
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.system(size: 28, weight: .medium)).foregroundColor(.white.opacity(0.6)).frame(width: 260, alignment: .leading)
            Text(value).font(.system(size: 34, weight: .bold)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}


/// Year in review: the user picker as one glass pill (initials + name + chevron) opening a menu with ✓ on the current
/// user, like the other glass pills (owner: a pill with all the names was too much).
struct YearUserMenu: View {
    let users: [(id: String, name: String)]
    @Binding var selected: String
    var current: String { users.first { $0.id == selected }?.name ?? users.first?.name ?? "" }
    var body: some View {
        Menu {
            ForEach(users, id: \.id) { u in
                Toggle(u.name, isOn: Binding(get: { selected == u.id }, set: { if $0 { selected = u.id } }))
            }
        } label: {
            HStack(spacing: 8) {
                Text(ProfileInitials.of(current)).cvFont(10, weight: .bold).foregroundColor(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor.opacity(0.55)))
                Text(current).cvFont(13, weight: .semibold).lineLimit(1)
                Image(systemName: "chevron.down").cvFont(10, weight: .bold).opacity(0.8)
            }
            .padding(.leading, Glass3DTokens.Space.s).padding(.trailing, 12).frame(height: 36)
            .modifier(ClassicClearGlass(shape: Capsule()))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .helpLabel("Whose year")
    }
}


/// Year in review: the year as one glass pill (calendar + year + chevron) opening a menu with ✓ on the current year.
struct YearPickerMenu: View {
    let years: [Int]
    @Binding var selected: Int
    var body: some View {
        Menu {
            ForEach(years, id: \.self) { y in
                Toggle(String(y), isOn: Binding(get: { selected == y }, set: { if $0 { selected = y } }))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar").cvFont(12, weight: .semibold)
                Text(String(selected)).cvFont(13, weight: .semibold)
                Image(systemName: "chevron.down").cvFont(10, weight: .bold).opacity(0.8)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .modifier(ClassicClearGlass(shape: Capsule()))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .helpLabel("Year")
    }
}
