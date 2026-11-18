import IOKit.pwr_mgt
import SwiftUI
import AVKit

func classicParseDate(_ s: String?) -> Date? {
    guard let s, s.count >= 19 else { return nil }
    return ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
}

/// A series' seasons stacked like playing cards (as the Home banner's deck): the shown season in front, the ones
/// after it peeking out behind; glass ‹ › beside it. Changing season cross-fades the whole deck.
struct SeasonDeck: View {
    let numbers: [Int]
    let selected: Int
    let title: (Int) -> String
    let image: (Int) -> URL?
    let select: (Int) -> Void
    /// Front card badges, as on the season posters: ♡ and ✓ with the unwatched count (DeckCardBadges)
    let badge: (Int) -> Int?
    let seasonItem: (Int) -> Item?
    let episodes: (Int) -> [Item]
    /// Collections: the line under the deck (the front movie's year, so the order is clear), the movie the front
    /// card opens, and what the arrows step through
    var caption: ((Int) -> String?)? = nil
    var link: ((Int) -> Item?)? = nil
    /// Collections: whether each movie is watched (the check on every card, top right, as on posters)
    var watched: ((Int) -> Bool)? = nil
    var noun = "season"
    private let w: CGFloat = 280, h: CGFloat = 420
    @AppStorage("accent") private var accentName = "red"
    private let peek: CGFloat = 40

    /// The deck's own position; the page's season follows it (and the deck follows the page when the season
    /// changes elsewhere).
    @State private var pos = -1
    @State private var swipe = DeckSwipe()
    var shownPos: Int { pos >= 0 ? pos : (numbers.firstIndex(of: selected) ?? 0) }

    var body: some View {
        HStack(spacing: 12) {
            arrow("chevron.left", "Previous \(noun)", enabled: shownPos > 0) { go(shownPos - 1) }
            VStack(alignment: .leading, spacing: 10) {
                cards
                if let caption, numbers.indices.contains(shownPos), let c = caption(numbers[shownPos]) {
                    Text(c).cvFont(15, weight: .semibold).foregroundColor(.white).classicBlackOutline()
                        .frame(width: w).id(shownPos).transition(.opacity)   // centered under the front card
                }
            }
            arrow("chevron.right", "Next \(noun)", enabled: shownPos < numbers.count - 1) { go(shownPos + 1) }
        }
        .onHover { swipe.inside = $0 }
        .onAppear {
            pos = numbers.firstIndex(of: selected) ?? 0
            let box = swipe
            swipe.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard box.inside, let step = box.step(e) else { return box.inside && box.horizontal ? nil : e }
                // Past the first or last card the page scrolls on instead
                guard numbers.indices.contains(shownPos + step) else { return e }
                go(shownPos + step)
                return nil
            }
        }
        .onDisappear { if let m = swipe.monitor { NSEvent.removeMonitor(m); swipe.monitor = nil } }
        .onChange(of: selected) { _, s in
            if let i = numbers.firstIndex(of: s), i != pos { pos = i }
        }
    }

    func arrow(_ icon: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(help, systemImage: icon).classicGlassPill(size: 40) }
            .buttonStyle(HoverButton()).helpLabel(help)
            .disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    /// Shows season `p`: the whole deck cross-fades to its new stack.
    func go(_ p: Int) {
        guard p >= 0, p < numbers.count, p != shownPos else { return }
        withAnimation(.easeInOut(duration: 0.35)) { pos = p }
        select(numbers[p])
    }

    var cards: some View {
        let pos = shownPos
        let shown = min(numbers.count - pos, 4)
        return ZStack(alignment: .leading) { stack(pos, shown) }
            .frame(width: w + CGFloat(3) * peek, height: h, alignment: .leading)
    }

    /// One whole stack, keyed by its position: a new position replaces the stack as one piece with a plain
    /// cross-fade (the same both ways)
    func stack(_ pos: Int, _ shown: Int) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array((pos..<(pos + shown)).reversed()), id: \.self) { p in
                let k = p - pos
                deckButton(p, k: k) { card(numbers[p], k: k) }
                // v1.18.6: the poster badges (♡ / ✓ with the unwatched count) on the front card, no hover buttons
                .modifier(DeckCardBadges(front: k == 0, item: seasonItem(numbers[p]), episodes: episodes(numbers[p]),
                                         unwatched: badge(numbers[p]), watched: watched?(numbers[p])))
                    .buttonStyle(.plainHand)
                    .accessibilityLabel(title(numbers[p]))   // no tooltip: the card shows its name
                    .scaleEffect(1 - CGFloat(k) * 0.08, anchor: .trailing)
                    .offset(x: CGFloat(k) * peek)
            }
        }
        .id(pos)
        .transition(.opacity)
    }

    /// The front card of a collection opens its movie; every other card brings itself to the front.
    @ViewBuilder func deckButton<L: View>(_ p: Int, k: Int, @ViewBuilder label: () -> L) -> some View {
        if k == 0, let link, let it = link(numbers[p]) {
            NavigationLink(value: it) { label() }
        } else {
            Button { go(p) } label: { label() }
        }
    }

    func card(_ n: Int, k: Int) -> some View {
        CachedImage(url: image(n)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { ZStack { Color(white: 0.15); Text(title(n)).cvFont(10, weight: .regular) } }
        .frame(width: w, height: h).clipped()   // no name on the card: season and movie covers show their own
        .cornerRadius(10)
        .modifier(ClassicLightCard(radius: 10, accent: Theme.accent(accentName), size: CGSize(width: w, height: h),
                                   tracksHover: k == 0))   // the posters' light glass edge; glow on the front card
        .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(Double(k) * 0.22)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

/// A two-finger trackpad swipe over a card deck: one card per swipe (left = next, right = previous), whatever
/// the swipe's length; the page keeps scrolling up and down as usual, and the mouse wheel always scrolls the page.
final class DeckSwipe {
    var monitor: Any?
    var inside = false
    /// This swipe goes sideways (its events are the deck's, not the page's)
    var horizontal = false
    private var dx: CGFloat = 0
    private var fired = false

    /// The step this event completes (+1 next, -1 previous), or nil.
    func step(_ e: NSEvent) -> Int? {
        // The coasting after the fingers lift belongs to the swipe already counted
        if !e.momentumPhase.isEmpty { return nil }
        if e.phase == .began || e.phase == .mayBegin { dx = 0; fired = false; horizontal = false }
        // A mouse wheel (no phases at all; a trackpad marks every event with its swipe or coasting phase) stays
        // the page's
        if e.phase.isEmpty && e.momentumPhase.isEmpty { horizontal = false; return nil }
        if e.phase == .ended || e.phase == .cancelled { horizontal = false; return nil }
        if !horizontal {
            guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return nil }
            horizontal = true
        }
        dx += e.scrollingDeltaX
        guard !fired, abs(dx) > 40 else { return nil }
        fired = true
        return dx < 0 ? 1 : -1   // fingers to the left bring the next card
    }
}


struct ClassicBackdrop: View {
    @EnvironmentObject var emby: Emby
    let id: String
    var body: some View {
        CachedImage(url: emby.image(id, "Backdrop", width: 1600)) { p in
            p.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.1) }
    }
}

// MARK: - Detail / movie info

struct ClassicCastTile: View {
    @EnvironmentObject var emby: Emby
    let p: Full.Person
    @AppStorage("castSize") private var castSize = "normal"   // Settings → Libraries → Movie and show pages
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    var body: some View {
        let big = castSize == "large"
        VStack(spacing: 6) {
            CachedImage(url: emby.image(p.Id, width: big ? 360 : 240)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack { Color(white: 0.18); Image(systemName: "person.fill").cvFont(big ? 44 : 30).foregroundColor(.secondary) }
            }
            // Large: a portrait photo card (2:3); Normal: the round photo
            .frame(width: big ? 132 : 88, height: big ? 198 : 88)
            .clipShape(RoundedRectangle(cornerRadius: big ? 10 : 44))
            .modifier(ClassicLightCard(radius: big ? 10 : 44, hover: hover, accent: Theme.accent(accentName),
                                       size: big ? CGSize(width: 132, height: 198) : CGSize(width: 88, height: 88)))   // the posters' light glass edge
            .shadow(color: .black.opacity(big ? 0.45 : 0), radius: 6, y: 3)
            // Favorites show a small heart top left, as posters do
            .overlay(alignment: .topLeading) {
                if emby.isPersonFav(p.Id) {
                    FavHeart(size: 16).padding(big ? 8 : 2)
                }
            }
            // Favorite heart, bottom right on hover, as on posters
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    let fav = emby.isPersonFav(p.Id)
                    ItemActionsButton.circle(fav ? "heart.fill" : "heart", on: fav,
                                             help: fav ? "Remove from Favorites" : "Add to Favorites") {
                        Task { await emby.setFav(p.Id, !fav, name: p.Name) }
                    }.padding(big ? 8 : 0)
                }
            }
            .scrollHover($hover)
            .classicHoverLift()   // grows a little under the pointer, like posters
            Text(p.Name).cvFont(big ? 12 : 10, weight: .semibold).lineLimit(1)
            Text(p.Role ?? p.`Type` ?? "").cvFont(10).foregroundColor(.secondary).lineLimit(1)
        }.frame(width: CastTile.width(castSize)).multilineTextAlignment(.center)
    }
}

struct ClassicDetailView: View {
    @Environment(\.noBack) private var noBack
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let item: Item
    /// The page's data, loading and Play decisions, shared with the other theme
    @StateObject private var model: DetailModel

    init(item: Item) {
        self.item = item
        _model = StateObject(wrappedValue: DetailModel(item: item))
    }
    @AppStorage("accent") private var accentName = "red"   // episode cards' hover glow
    @AppStorage("moviePage") private var moviePage = "banner"   // Settings → Libraries → Movie page
    @AppStorage("episodeSubLang") private var epSubLang = ""
    @AppStorage("subAlways") private var subAlwaysOn = false
    @AppStorage("subLang") private var prefSubLang = "english"
    /// First entry of the Subtitles menu: the preferred language when that setting is on, otherwise Off.
    var defaultSubLabel: String { subAlwaysOn ? prefSubLang.capitalized : "Off" }
    // Shared with Settings → Libraries → Episode layout and the Glass theme: "row", "grid" or "list"
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("seasonLayoutTV") private var seasonLayout = "row"   // Settings → Libraries → Season layout
    @AppStorage("showEpisodeDescription") private var showEpDesc = true   // Settings → Libraries → Series
    @AppStorage("similarLayout") private var similarLayout = "row"   // "row", "grid" or "list"; also in Settings → Libraries

    /// Season layout → Cards: the show opens on a banner as big as Home's, the season deck in its bottom-right corner
    /// Decided by the setting alone (not by the seasons, which load a moment later), so the page never shows the
    /// old header first
    /// Movies and collections (Settings → Movie pages → Big banner) open the same way: a movie on the banner
    /// alone, a collection with its movies as the deck.
    var bigBanner: Bool { item.isSeries ? seasonLayout == "deck" : (!item.isEpisode && moviePage == "banner") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if bigBanner { showBanner } else { header }
                if item.isSeries { episodesList }
                if item.isBox { boxGrid }
                castSection.task { _ = await emby.favoritePeople() }   // hearts on the cast photos
                aboutSection
                includedInSection
                similarSection
            }.padding(.bottom, 50)
        }
        .classicScrollBars()   // thin overlay bars, only while scrolling
        .ignoresSafeArea(edges: bigBanner ? .top : [])   // the banner runs up under the floating top bar
        .background(GeometryReader { g in
            Color.clear.onAppear { pageH = g.size.height }.onChange(of: g.size.height) { _, h in pageH = h }
        }.ignoresSafeArea(edges: .top))
        .background(alignment: .top) {
            if !bigBanner { ZStack {
                // Fill the page width without growing it: a filled image sized by its own width made the whole
                // page wider than the window (pushing the Top bar's Search and Settings off screen)
                Color.clear.frame(height: 520)
                    .overlay { ClassicBackdrop(id: item.backdropId ?? item.Id) }
                    .clipped().opacity(0.35)
                LinearGradient(colors: [Color.clear, bg], startPoint: .top, endPoint: .bottom)
            }.frame(height: 520) }
        }
        .background(bg)
        .task { model.bind(emby); await model.load() }
        .onChange(of: model.srcIdx) { model.sourceChanged() }
        .onChange(of: model.season) { model.seasonChanged() }
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: noBack ? nil : { dismiss() }) }
        .classicHideToolbarTitle()
    }

    @State private var pageH: CGFloat = 800

    /// The show as a banner the size of the page (as Home's): backdrop edge to edge, title logo, facts, description
    /// and buttons on a dark fade at the left, the season deck bottom right.
    var showBanner: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: max(pageH, 420))
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: 2560) }.clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.6)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: bg.opacity(0.7), location: 0.8),
                                   .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(item: item, height: 110, font: 56)
                meta
                // A movie keeps its version, audio, subtitle and quality choices (a show picks per episode)
                if !item.isSeries && !model.simple {
                    // A set width, so Version, Audio, Subtitles and Quality fit on one line (left to size itself,
                    // the row was offered the narrow width of the text beside it and wrapped)
                    streamsRow.frame(width: 900, alignment: .leading)
                }
                buttons
                if !item.isSeries, let tag = model.full?.Taglines?.first { Text(tag).cvFont(13, weight: .bold) }
                Text(item.Overview ?? "").cvFont(15).lineLimit(3)
                    .foregroundColor(.white.opacity(0.85)).frame(maxWidth: 520, alignment: .leading)
            }
            .padding(.leading, 80).padding(.bottom, 56).padding(.trailing, item.isSeries || item.isBox ? 600 : 80)
            if item.isBox && !model.boxMovies.isEmpty {
                // A collection's movies as a deck, oldest first, the year under the front one
                let movies = model.boxMovies
                SeasonDeck(numbers: Array(movies.indices), selected: 0,
                           title: { movies[$0].Name },
                           image: { emby.image(movies[$0].posterId, width: 500) },
                           select: { _ in },
                           badge: { _ in nil },
                           seasonItem: { movies[$0] },
                           episodes: { _ in [] },
                           caption: { movies[$0].ProductionYear.map(String.init) },
                           link: { movies[$0] },
                           watched: { emby.isPlayed(movies[$0]) },
                           noun: "movie")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 44).padding(.bottom, 30)
                    .transition(.opacity)
            }
            if model.seasonNumbers.count > 1 {
                SeasonDeck(numbers: model.seasonNumbers, selected: model.currentSeason,
                           title: { model.seasonTitle($0) },
                           image: { n in emby.image(model.seasonItem(n)?.Id ?? item.Id, width: 400) },
                           select: { model.season = $0 },
                       badge: { model.unwatched($0) },
                       seasonItem: { n in model.seasonItem(n) },
                       episodes: { n in model.episodes(inSeason: n) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 44).padding(.bottom, 56)
                    .transition(.opacity)
            }
        }
        .frame(height: max(pageH, 420))
        .foregroundColor(.white)
    }

    // Header: poster + info + pickers + buttons
    var header: some View {
        let deck = item.isSeries && seasonLayout == "deck" && model.seasonNumbers.count > 1
        return headerBody
            .padding(.trailing, deck ? 520 : 0)   // the text stays clear of the deck
            .frame(maxWidth: .infinity, alignment: .leading)   // full page width, so the deck reaches the corner
            .overlay(alignment: .bottomTrailing) {
                // Series, Settings → Season layout → Cards: the seasons as a deck of cards, as on the Home banner;
                // the front season is the one whose episodes are listed below
                if item.isSeries, seasonLayout == "deck", model.seasonNumbers.count > 1 {
                    SeasonDeck(numbers: model.seasonNumbers, selected: model.currentSeason,
                               title: { model.seasonTitle($0) },
                               image: { n in emby.image(model.seasonItem(n)?.Id ?? item.Id, width: 400) },
                               select: { model.season = $0 },
                       badge: { model.unwatched($0) },
                       seasonItem: { n in model.seasonItem(n) },
                       episodes: { n in model.episodes(inSeason: n) })
                    .padding(.trailing, 40)   // in line with the episodes' right edge
                }
            }
    }

    var headerBody: some View {
        HStack(alignment: .top, spacing: 28) {
            CachedImage(url: emby.image(item.id, width: 500)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { ZStack { Color(white: 0.15); Text(item.Name).padding() } }
            .frame(width: item.isEpisode ? 320 : 220, height: item.isEpisode ? 180 : 330)
            .clipped().cornerRadius(10)
            .modifier(ClassicLightCard(radius: 10,
                                       size: item.isEpisode ? CGSize(width: 320, height: 180) : CGSize(width: 220, height: 330)))   // the posters' light glass edge and sheen, as the cards
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 14) {
                Text(item.Name).cvFont(46, weight: .black)
                meta
                if !model.simple { streamsRow }
                buttons
                if let tag = model.full?.Taglines?.first { Text(tag).cvFont(13, weight: .bold) }
                Text(item.Overview ?? "").frame(maxWidth: 760, alignment: .leading)
                let directors = (model.full?.People ?? []).filter { $0.`Type` == "Director" }.map { $0.Name }
                if !directors.isEmpty {
                    (Text("Director: ").foregroundColor(.secondary) + Text(directors.joined(separator: ", ")).bold())
                        .cvFont(12, weight: .regular)
                }
            }
        }.padding(.horizontal, 40).padding(.top, 40)
    }

    var meta: some View {
        HStack(spacing: 12) {
            if let r = model.full?.CommunityRating {
                HStack(spacing: 3) { Image(systemName: "star.fill").foregroundColor(.yellow); Text(String(format: "%.1f", r)) }
            }
            if let c = model.full?.CriticRating { Text("🍅 \(Int(c))%") }
            if let y = item.ProductionYear { Text(String(y)) }
            if let t = model.full?.RunTimeTicks { Text(runtimeText(t)) }
            if let o = model.full?.OfficialRating {
                Text(o).cvFont(10, weight: .regular).padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary))
            }
            if let g = model.full?.Genres?.first { Text(g) }
            if let t = model.full?.RunTimeTicks, !model.simple { Text("Ends at " + endsAtText(t)) }
        }.cvFont(11, weight: .regular).foregroundColor(.secondary)
    }

    /// Wraps onto more lines when the window is narrow, so long version names can't widen the page.
    var streamsRow: some View {
        FlowLayout(hSpacing: 20, vSpacing: 10) {
            if model.sources.count > 1 {
                labeled("Version") {
                    GlassPicker(selection: $model.srcIdx, options: model.sources.indices.map {
                        ($0, model.sources[$0].Name ?? model.sources[$0].Path ?? "Version \($0 + 1)")
                    }, maxWidth: 320)   // long file names are cut with "…"
                }
            }
            if let v = model.streams("Video").first {
                HStack(spacing: 6) { Text("Video").foregroundColor(.secondary); Text(v.DisplayTitle ?? "") }
            }
            if !model.streams("Audio").isEmpty {
                labeled("Audio") {
                    GlassPicker(selection: $model.audioIdx,
                                options: model.streams("Audio").map { ($0.Index, $0.DisplayTitle ?? "Track \($0.Index)") })
                }
            }
            labeled("Subtitles") {
                GlassPicker(selection: $model.subIdx,
                            options: [(-1, "Off")] + model.streams("Subtitle").map { ($0.Index, $0.DisplayTitle ?? "Track \($0.Index)") })
            }
            labeled("Quality") {
                GlassPicker(selection: $model.quality, options: [(0, "Original"), (8_000_000, "1080p · 8 Mbps"),
                                                           (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")])
            }
        }
        .cvFont(12, weight: .regular)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary)
            content()
        }
    }

    var buttons: some View {
        let played = emby.isPlayed(item)
        let fav = emby.isFav(item)
        // All the same size and shape: 44-pt glass pills
        return HStack(spacing: 10) {
            let r = model.resumePoint
            Button { model.playNow(from: r > 0 ? 0 : nil) } label: {
                Label(model.playLabel, systemImage: "play.fill").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton()).accessibilityLabel(r > 0 ? model.playLabel + " from the beginning" : model.playLabel)
            if r > 0 {
                Button { model.playNow() } label: {
                    Label("Resume from \(timeString(r))", systemImage: "arrow.uturn.forward").classicGlassPill(size: 44, iconOnly: false)
                }.buttonStyle(HoverButton())
            }
            WatchTogetherButton(item: model.playTarget, start: r, classic: true)
            if let u = SafeLink.url(model.full?.RemoteTrailers?.first?.Url) {
                Button { Trailer.open(u, item: item, emby: emby) } label: {
                    Label("Trailer", systemImage: "film").classicGlassPill(size: 44).glass3DRoundOutline()
                }.buttonStyle(HoverButton()).helpLabel("Trailer")
            }
            Button { Task { await emby.setPlayed(item.id, !played, name: item.Name) } } label: {
                Label(played ? "Watched" : "Mark as Watched", systemImage: played ? "checkmark.circle.fill" : "checkmark.circle")
                    .classicGlassPill(size: 44).glass3DRoundOutline()
            }.buttonStyle(HoverButton()).helpLabel(played ? "Mark as unwatched" : "Mark as watched")
            Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                Label { Text(fav ? "Favorite" : "Add to Favorites") } icon: {
                    if fav { FavHeart(size: 17) } else { Image(systemName: "heart") }
                }
                .classicGlassPill(size: 44).glass3DRoundOutline()
            }.buttonStyle(HoverButton()).helpLabel(fav ? "Remove from Favorites" : "Add to Favorites")
            // v1.18.4: information after the actions: your ★ rating at the END, set apart by a thin divider
            if RatingButton.isShown(item: item, full: model.full) { DetailRatingTail(item: item, full: model.full) }
        }
    }

    /// Language name from "English (SRT)" etc., so "eng" and "en" tracks group together.
    static func langName(_ st: MStream) -> String { subLangName(st) }   // same rule as "Always load…"




    func seasonPoster(_ n: Int) -> some View {
        let sItem: Item? = model.seasonItem(n)
        let title: String = model.seasonTitle(n)
        let selected: Bool = n == model.currentSeason
        return Button { model.season = n } label: {
            VStack(spacing: 8) {
                CachedImage(url: emby.image(sItem?.Id ?? item.Id, width: 400)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.15); Text(title) }
                }
                .frame(width: 170, height: 255).clipped().cornerRadius(8)
                .modifier(ClassicLightCard(radius: 8, accent: Theme.accent(accentName), size: CGSize(width: 170, height: 255),
                                           tracksHover: true))   // the posters' light glass edge   // glass card, as the posters
                // Selected season: an accent ring (it used to come out white)
                .overlay { if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent(accentName), lineWidth: 2.5) } }
                .classicHoverLift()
                // v1.19.0: ♡ / ✓ badge buttons as on posters (✓ marks the whole season; shows the unwatched count)
                .itemBadges(sItem, .season, children: model.episodes(inSeason: n), unwatched: model.unwatched(n) ?? 0)
                Text(title).cvFont(13, weight: .regular).foregroundColor(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plainHand)
    }

    var seasonRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Glass3DRowHeading(title: "Seasons").padding(.horizontal, 40)
            if seasonLayout == "grid" {
                // All seasons at once, wrapped onto as many lines as needed
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 170), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(model.seasonNumbers, id: \.self) { n in seasonPoster(n) }
                }.padding(.horizontal, 40).padding(.vertical, 8)
            } else {
                ArrowScrollRow(ids: model.seasonNumbers, itemWidth: 170) { n in seasonPoster(n) }
            }
        }
    }

    var episodesHeader: some View {
        let multi: Bool = model.seasonNumbers.count > 1
        let heading: String = multi ? model.seasonTitle(model.currentSeason) : "Episodes"
        return HStack(spacing: 16) {
            Text(heading).cvFont(Glass3DTokens.Text.section, weight: .bold)
            if model.canFilterWatched {
                // A secondary glass pill (no bare accent text as a button)
                Button { model.showAllEps.toggle() } label: {
                    Text(model.showAllEps ? "Hide watched" : "Show all").cvFont(12, weight: .semibold).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .classicGlassPill()
                }.buttonStyle(HoverButton())
            }
            Spacer()
            episodeLayoutToggle
            if !model.epLangs.isEmpty {
                Text("Subtitles").foregroundColor(.secondary)
                GlassPicker(selection: $epSubLang,
                            options: [("", defaultSubLabel)] + (subAlwaysOn ? [("off", "Off")] : [])
                                + model.epLangs.map { ($0.code, $0.name) })
            }
        }.padding(.horizontal, 40).padding(.top, 10)
    }

    /// Netflix-style episode row: big number, clean 16:9 still with progress, title + length, summary.
    func episodeRow(_ ep: Item) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        let hasProgress: Bool = pct > 0 && pct < 100 && !played
        return NavigationLink(value: ep) {
            HStack(alignment: .center, spacing: 18) {
                Text("\(ep.IndexNumber ?? 0)").cvFont(26, weight: .semibold)
                    .foregroundColor(.secondary).frame(width: 40)
                CachedImage(url: emby.image(ep.id, width: 480, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(white: 0.15) }
                .frame(width: 220, height: 124).clipped()
                .overlay { if hasProgress { epProgress(ep, pct) } }
                .cornerRadius(Glass3DTokens.Radius.thumb)
                .modifier(ClassicLightCard(radius: 6, accent: Theme.accent(accentName), size: CGSize(width: 220, height: 124),
                                           tracksHover: true))   // the posters' light glass edge
                .classicHoverLift(play: 36, playTip: ProgressStyle.centreTip(hasProgress: hasProgress)) {
                    model.playEpisode(ep, from: ProgressStyle.centreStart(hasProgress: hasProgress))
                }
                .itemBadges(ep, .episode, inset: 6)   // ♡ / ✓ top right, as on posters
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ep.Name).cvFont(16, weight: .semibold).lineLimit(1)
                        Spacer()
                        if let t = ep.RunTimeTicks, t > 0 { Text(runtimeText(t)).foregroundColor(.secondary) }
                    }
                    if showEpDesc { Text(ep.Overview ?? "").lineLimit(3).cvFont(12, weight: .regular).foregroundColor(.secondary) }
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
            .contentShape(Rectangle())
        }.handCursor()
        .buttonStyle(.plainHand).padding(.horizontal, 40)
    }

    var episodesList: some View {
        let eps: [Item] = model.shownEpisodes
        return VStack(alignment: .leading, spacing: 12) {
            if model.seasonNumbers.count > 1 && seasonLayout != "deck" { seasonRow }   // the deck sits in the header instead
            episodesHeader
            // A new season's episodes cross-fade in as one block (cards sliding and resizing one by one looked glitchy)
            Group {
                if epLayout == "row" {
                    // One line that scrolls sideways
                    ArrowScrollRow(ids: eps.map { $0.id }, itemWidth: 300, spacing: 18) { id in
                        if let ep = eps.first(where: { $0.id == id }) { episodeTile(ep).frame(width: 300) }
                    }
                } else if epLayout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 22) {
                        ForEach(eps) { ep in episodeTile(ep) }
                    }.padding(.horizontal, 40)
                } else {
                    VStack(alignment: .leading, spacing: 12) { ForEach(eps) { ep in episodeRow(ep) } }
                }
            }
            .id(model.currentSeason)
            .transition(.opacity)
        }
    }

    var episodeLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { epLayout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(epLayout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(epLayout == m.0)
                        .modifier(SectionHoverGlow(on: !(epLayout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicTabBarGlass()
    }


    /// "S3·E3" plus " · 42m left" when the episode is partly watched.
    func episodeInfo(_ ep: Item, hasProgress: Bool) -> String {
        var t = "S\(ep.ParentIndexNumber ?? 0)·E\(ep.IndexNumber ?? 0)"
        if hasProgress, let total = ep.RunTimeTicks, total > 0 {
            let left = max(0, total - (ep.UserData?.PlaybackPositionTicks ?? 0))
            t += " · " + runtimeText(left) + " left"
        }
        return t
    }

    /// The bottom glow line and the Resume ring (resumes from the saved position).
    func epProgress(_ ep: Item, _ pct: Double) -> some View {
        ThumbnailProgress(fraction: pct / 100, resumeAt: emby.resumeAt(ep)) {
            model.playEpisode(ep, from: ProgressStyle.ringStart(resumeAt: emby.resumeAt(ep)))
        }
    }

    func episodeTile(_ ep: Item) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        let hasProgress: Bool = pct > 0 && pct < 100 && !played
        return NavigationLink(value: ep) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    CachedImage(url: emby.image(ep.id, width: 520, plain: true)) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color(white: 0.15) }
                    .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    .opacity(played ? 0.6 : 1)
                    ThumbnailScrim()   // soft dark gradient behind the code and the title
                }
                // Episode name in the bottom-left corner of the thumbnail
                .overlay(alignment: .bottomLeading) {
                    // No background: a black outline keeps it readable (as on Continue Watching)
                    Text(ep.Name).cvFont(14, weight: .semibold).foregroundColor(.white).lineLimit(2)
                        .classicBlackOutline()
                        .padding(.leading, 10).padding(.trailing, 10)
                        .padding(.bottom, 9)
                        .modifier(ProgressRingClearance(active: hasProgress))   // clear of the ring
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Episode number in the top-left corner
                .overlay(alignment: .topLeading) {
                    Text(episodeInfo(ep, hasProgress: hasProgress)).cvFont(10, weight: .semibold).foregroundColor(.white)
                        .classicBlackOutline()
                        .padding(10)
                }
                // How far you got: glow line along the bottom, Resume ring bottom-right
                .overlay { if hasProgress { epProgress(ep, pct) } }
                .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb))
                .modifier(ClassicLightCard(radius: 6, accent: Theme.accent(accentName), tracksHover: true))   // the posters' light glass edge
                .classicHoverLift(play: 40, playTip: ProgressStyle.centreTip(hasProgress: hasProgress)) {
                    model.playEpisode(ep, from: ProgressStyle.centreStart(hasProgress: hasProgress))
                }
                // ♡ / ✓ badge buttons in the top-right corner, as on posters (the watched tick lives in ✓ now)
                .itemBadges(ep, .episode, inset: 6)
                if showEpDesc {
                    Text(ep.Overview ?? "").cvFont(10, weight: .regular).foregroundColor(.secondary).lineLimit(2)
                }
            }.contentShape(Rectangle())
        }.handCursor()
        .buttonStyle(.plainHand)
    }


    var boxGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
            ForEach(model.kids) { ClassicPosterCard(item: $0) }
        }.padding(.horizontal, 40)
    }

    @AppStorage("castSize") private var castSize = "normal"
    @ViewBuilder var castSection: some View {
        let people = Array((model.full?.People ?? []).prefix(30))
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Glass3DRowHeading(title: "Cast & Crew").padding(.horizontal, 40)
                ArrowScrollRow(ids: Array(people.indices), itemWidth: CastTile.width(castSize)) { i in
                    NavigationLink(value: PersonRef(id: people[i].Id, name: people[i].Name)) { ClassicCastTile(p: people[i]) }
                        .buttonStyle(.plainHand).accessibilityLabel("Show everything with \(people[i].Name)")   // no tooltip on actors
                }
            }
        }
    }

    func mediaInfo(_ s: MSource, _ f: Full) -> String {
        var info = (s.Container ?? "").uppercased()
        if let z = s.Size { info += "  " + ByteCountFormatter.string(fromByteCount: z, countStyle: .file) }
        if let a = classicParseDate(f.DateCreated) { info += "  Added " + a.formatted(date: .abbreviated, time: .shortened) }
        return info
    }

    func aboutRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).bold()
            Text(text).foregroundColor(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder var aboutSection: some View {
        if let f = model.full {
            VStack(alignment: .leading, spacing: 16) {
                Text("About").cvFont(Glass3DTokens.Text.section, weight: .bold)
                if let d = classicParseDate(f.UserData?.LastPlayedDate) {
                    aboutRow("Date Last Played", d.formatted(date: .abbreviated, time: .shortened))
                }
                if let g = f.Genres, !g.isEmpty { aboutRow("Genres", g.joined(separator: ", ")) }
                if let s = f.Studios, !s.isEmpty { aboutRow("Studios", s.map { $0.Name }.joined(separator: ", ")) }
                if let links = f.ExternalUrls, !links.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Links").bold()
                        HStack(spacing: 10) {
                            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                                if let n = l.Name, let u = SafeLink.url(l.Url) { Link(n, destination: u).handCursor() }
                            }
                        }
                    }
                }
                if let s = model.src {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Media Info").bold()
                        if let p = s.Path { Text(p).foregroundColor(.secondary).textSelection(.enabled) }
                        Text(mediaInfo(s, f)).foregroundColor(.secondary)
                    }
                }
            }.padding(.horizontal, 40).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Included In": the collections this title belongs to; a click opens the collection's page.
    @ViewBuilder var includedInSection: some View {
        if !model.includedIn.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Included In").cvFont(Glass3DTokens.Text.section, weight: .bold).padding(.horizontal, 40)
                ArrowScrollRow(ids: Array(model.includedIn.indices), itemWidth: 150, spacing: 14) { ClassicPosterCard(item: model.includedIn[$0]) }
            }
        }
    }

    @ViewBuilder var similarSection: some View {
        if !model.similar.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("More Like This").cvFont(Glass3DTokens.Text.section, weight: .bold)
                    Spacer()
                    similarLayoutToggle
                }.padding(.horizontal, 40)
                // Extra space below, and the header kept in front: a hovered poster grows a little (hover lift)
                // and could otherwise cover the view buttons and swallow their clicks
                .padding(.bottom, 14).zIndex(1)
                if similarLayout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(model.similar) { ClassicPosterCard(item: $0) }
                    }.padding(.horizontal, 40)
                } else if similarLayout == "list" {
                    LazyVStack(spacing: 6) { ForEach(model.similar) { Glass3DListRow(item: $0) } }.padding(.horizontal, 40)
                } else {
                    ArrowScrollRow(ids: Array(model.similar.indices), itemWidth: 150, spacing: 14) { ClassicPosterCard(item: model.similar[$0]) }
                }
            }
        }
    }

    var similarLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { similarLayout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(similarLayout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(similarLayout == m.0)
                        .modifier(SectionHoverGlow(on: !(similarLayout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicTabBarGlass()
    }
}
