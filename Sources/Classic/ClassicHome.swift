import IOKit.pwr_mgt
import SwiftUI
import AVKit

// MARK: - Home

struct ClassicHomeContent: View {
    @AppStorage("classicBannerStyle") private var bannerStyle = "cinematic"
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @AppStorage("homeLayout") private var homeLayout = "row"
    @AppStorage("homeResumeLayout") private var resumeLayout = "row"
    let reloadToken: Int
    private var homeSession: String { HomeModel.sessionKey(server: emby.server, userId: emby.userId) }
    /// Rows, banner items and loading (shared with Glass); Classic doesn't prefetch the rows' pictures (it never did).
    @StateObject private var model = HomeModel(prefetchRows: false)
    @State private var pageH: CGFloat = .infinity
    @State private var topInset: CGFloat = 0   // the top bar / title bar the banner runs up under

    var body: some View {
        let hero = model.heroItems
        ScrollView {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.xxl) {
                if !hero.isEmpty {
                    ClassicHero(items: hero, pageH: pageH)   // the server is in the top bar's profile menu now
                        // A banner refresh swaps in the new set with a crossfade, starting at slide 1
                        .id(model.heroGeneration).transition(.opacity)
                        .animation(.easeInOut(duration: 0.8), value: model.heroGeneration)
                }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        Glass3DRowHeading(title: row.title, seeAll: row.libId.map { id in { ClassicNavState.shared.sel = id } })
                            .padding(.horizontal, Glass3DTokens.Space.page)
                        let wide = HomeCardText.isWideRow(row.feed)   // Continue Watching and Up Next: wide 16:9 cards
                        let resumeRow = row.feed == .resume
                        // Continue Watching has its own Row / Grid choice; every other section follows Home's
                        if (resumeRow ? resumeLayout : homeLayout) == "grid" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 260 : 150), spacing: Glass3DTokens.Space.l)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(row.items) { it in
                                    if wide { ClassicResumeCard(item: it) } else { ClassicPosterCard(item: it) }
                                }
                            }.padding(.horizontal, Glass3DTokens.Space.page)
                        } else if wide {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 260, spacing: Glass3DTokens.Space.l, inset: 32) {
                                ClassicResumeCard(item: row.items[$0])
                            }
                        } else {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 150, spacing: Glass3DTokens.Space.l, inset: 32) {
                                ClassicPosterCard(item: row.items[$0])
                            }
                        }
                    }
                }
                if model.loading {
                    // Rows still loading: poster-shaped blocks, as the rows will be
                    SkeletonShimmer(layout: .posters, rows: model.rows.isEmpty ? 12 : 6).skeletonCrossfade()
                        .padding(.horizontal, Glass3DTokens.Space.page).padding(.vertical, Glass3DTokens.Space.xxl)
                }
                else if model.rows.isEmpty, let m = emby.lastFailure {
                    // The server couldn't be reached: say so, instead of an empty page
                    ErrorStateView(message: m, retry: { model.retry() },
                                   switchServer: { emby.switchServer() }).padding(.top, 80)
                }
            }.padding(.bottom, Glass3DTokens.Space.pageWide)
        }
        .classicScrollBars()   // thin overlay bars, only while scrolling
        // The banner runs up under the floating top bar (not the inset card)
        .ignoresSafeArea(edges: hero.isEmpty || bannerStyle == "card" ? [] : .top)
        // Height of the whole visible page, including the part under the top bar the banner runs up into
        .background(GeometryReader { g in
            Color.clear.onAppear { pageH = g.size.height }.onChange(of: g.size.height) { _, h in pageH = h }
        }.ignoresSafeArea(edges: bannerStyle == "card" ? [] : .top))
        // Height of the top bar / title bar above the page (where the server pill must stay clear of)
        .background(GeometryReader { g in
            Color.clear.onAppear { topInset = g.safeAreaInsets.top }
                .onChange(of: g.safeAreaInsets.top) { _, t in topInset = t }
        })
        .background(bg)
        .task(id: model.taskKey(reloadToken, session: homeSession)) { model.bind(emby); await model.load(session: homeSession) }
    }
}

/// The banner's outline: full width (cinematic, panel) or an inset card with the glass frame.
private struct BannerShape: ViewModifier {
    let card: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if card {
            content.clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.hero))
                .modifier(ClassicLightCard(radius: 18))   // the posters' light glass edge, drawn once per size
                .padding(.horizontal, Glass3DTokens.Space.page)
        } else {
            content.clipped()
        }
    }
}

/// Home banner, cinematic: the picture runs edge to edge up under the floating top bar, the title logo, facts,
/// description and glass buttons sit on a dark fade at the left; glass page bullets at the bottom and glass arrows at
/// the sides on hover.
struct ClassicHero: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let items: [Item]
    var pageH: CGFloat = .infinity
    /// Banners moved through so far (back = −1); never wraps, so each card in the deck keeps its own identity
    @State private var pos = 0
    var index: Int { items.isEmpty ? 0 : ((pos % items.count) + items.count) % items.count }
    @State private var leaving: Item?       // the deck's front card while it fades away
    @State private var busy = false
    @State private var leavingGone = false
    /// Pointer on the text + buttons or on the cards/bullets: the banner waits (not the whole picture, which fills
    /// the page, so a resting pointer anywhere on Home stopped it, owner)
    @State private var hoverInfo = false
    @State private var hoverNav = false
    var hover: Bool { hoverInfo || hoverNav }
    @State private var width: CGFloat = 1200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @ObservedObject private var nav = ClassicNavState.shared
    /// Settings → General → Home banner: "cinematic" (edge to edge), "panel" (text on a glass panel) or "card"
    /// (an inset glass-framed card)
    @AppStorage("classicBannerStyle") private var style = "cinematic"
    /// Settings → General → Banner navigation: "deck" (cards, bottom right) or "bullets" (bottom center)
    @AppStorage(Glass3DBannerNav.key) private var bannerNav = Glass3DBannerNav.defaultValue
    /// The whole visible page, so the rows (Continue Watching…) start just below it and show once you scroll
    var bannerH: CGFloat { pageH.isFinite ? max(pageH, 360) : max(width * 9 / 16, 520) }

    func meta(_ item: Item) -> String {
        var m: [String] = [item.isEpisode || item.isSeries ? "TV Show" : "Movie"]
        m += (item.Genres ?? []).prefix(2)
        if let y = item.ProductionYear { m.append(String(y)) }
        return m.joined(separator: " · ")
    }

    /// Shows banner `i` (any integer; wraps). One back steps back; anything else moves forward through the deck.
    func go(_ i: Int) {
        let n = items.count
        guard n > 0, !busy else { return }
        if !reduceMotion {
            busy = true   // clicks during a move wait for it to finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { busy = false }
        }
        let d = (((i - index) % n) + n) % n
        let back = d == n - 1 && n > 2
        // Moving forward: keep the front card on screen as a copy and fade it away over the deck
        if !back && d > 0 && n > 1 && !reduceMotion {
            leaving = items[(index + 1) % n]
            leavingGone = false
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.7)) { leavingGone = true }
            }
            let id = leaving?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { if leaving?.id == id { leaving = nil } }
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { pos += back ? -1 : d }
    }

    var body: some View {
        let item = items[index % items.count]
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: bannerH)
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: min(Int(width * 2), 2560)).kenBurns(seed: item.id) }.clipped()   // Retina-sharp; slow zoom per slide
                // The new picture fades in over the old one, which stays solid underneath until it is covered (both
                // half see-through at once made the banner dim mid-change)
                .id("b" + item.id)
                .transition(.asymmetric(insertion: .opacity,
                                        removal: .opacity.animation(.linear(duration: 0.05).delay(0.7))))
                .zIndex(Double(pos))
            fades.zIndex(Double(pos) + 0.5)
            Group {
                if style == "panel" {
                    info(item).padding(24)
                        .modifier(ClassicClearGlass(shape: RoundedRectangle(cornerRadius: Glass3DTokens.Radius.banner, style: .continuous)))
                        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.banner, style: .continuous).fill(Color.black.opacity(0.35)))
                } else { info(item) }
            }
            .padding(.leading, style == "card" ? 44 : 80).padding(.bottom, 56)
            .scrollHover($hoverInfo)
            // Old text fades out quickly, then the new text fades in (they overlapped mid-change)
            .id("t" + item.id)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.3)),
                                    removal: .opacity.animation(.easeIn(duration: 0.25))))
            .zIndex(Double(pos) + 0.6)
            // The coming banners as a deck of cards, bottom right (above the changing picture and text)
            Group {
                if items.count > 1 {
                    // The hover is tracked on the bullets/cards themselves, BEFORE the full-size frame: on the frame
                    // it covered the whole banner and a resting pointer stopped the cycle (owner)
                    if bannerNav == "bullets" {
                        thumbs.scrollHover($hoverNav).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, Glass3DTokens.Space.xxl)
                    } else {
                        deck.scrollHover($hoverNav).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.trailing, 44).padding(.bottom, 56)
                    }
                }
            }
            .zIndex(Double(pos) + 1)
        }
        .animation(Glass3DTokens.Motion.fast, value: hover)
        .frame(height: style == "card" ? max(bannerH - 24, 340) : bannerH)
        .modifier(BannerShape(card: style == "card"))
        .foregroundColor(.white)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width; HomeModel.bannerImageWidth = min(Int(g.size.width * 2), 2560) }
                .onChange(of: g.size.width) { _, w in width = w; HomeModel.bannerImageWidth = min(Int(w * 2), 2560) }
        })
        .onChange(of: nav.bannerNudge) { _, n in if let n, !items.isEmpty { go(index + n.dir) } }   // ← → keys
        // Next banner every 9 s, but not under the pointer (text/buttons/cards), not during playback and not with
        // Reduce Motion. Restarts when the items change (loaded later, banner refresh); a click or ← → changes `pos`,
        // so the full 9 s start again. A move skipped while one is still animating waits for it (it used to be lost
        // and the banner stopped for good).
        .task(id: "\(pos)-\(hover)-\(playback.active)-\(items.map(\.id).joined(separator: ","))") {
            guard !hover, !playback.active, !reduceMotion, items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            while busy && !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            if !Task.isCancelled { go(index + 1) }
        }
    }

    /// Dark fades so the text reads: from the left and into the page (cinematic), only at the bottom (panel: the
    /// glass panel carries the text), or inside the card.
    @ViewBuilder var fades: some View {
        if style != "panel" {
            LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.6)],
                           startPoint: .leading, endPoint: .trailing)
        }
        if style == "card" {
            LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: bg.opacity(0.7), location: 0.8),
                                   .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }

    func info(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.isEpisode {
                Text("S\(item.ParentIndexNumber ?? 0) · E\(item.IndexNumber ?? 0)").cvFont(13, weight: .semibold)
                    .foregroundColor(.white.opacity(0.85))
            }
            TitleLogo(item: item, height: style == "cinematic" ? 110 : 90, font: style == "cinematic" ? 56 : 46)
            HStack(spacing: Glass3DTokens.Space.m) {
                Text(meta(item))
                if let r = item.CommunityRating {
                    HStack(spacing: 3) { Image(systemName: "star.fill"); Text(String(format: "%.1f", r)) }
                }
            }.cvFont(15, weight: .medium).foregroundColor(.white.opacity(0.9))
            Text(item.Overview ?? "").cvFont(15).lineLimit(3).truncationMode(.tail)
                .foregroundColor(.white.opacity(0.8)).frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 12) {
                // In progress: the same short Resume as the film pages (↻ 4:01, full text in the tooltip)
                let r = emby.resumeAt(item)
                Button { Task { await emby.playFromHome(item) } } label: {
                    Label(r > 0 ? timeString(r) : "Play", systemImage: r > 0 ? "arrow.uturn.forward" : "play.fill")
                        .classicGlassPill(size: 46, iconOnly: false)
                }.buttonStyle(HoverButton())
                .tip(r > 0 ? "Resume from \(timeString(r))" : "")
                .accessibilityLabel(r > 0 ? "Resume from \(timeString(r))" : "Play")
                let fav = emby.isFav(item)
                Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                    Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "checkmark" : "plus")
                        .classicGlassPill(size: 46).glass3DRoundOutline()
                }.buttonStyle(HoverButton()).helpLabel(fav ? "Remove from Favorites" : "Add to Favorites")
                NavigationLink(value: item) {
                    Label("More Info", systemImage: "info").classicGlassPill(size: 46).glass3DRoundOutline()
                }.buttonStyle(HoverButton()).helpLabel("More Info")
            }.padding(.top, Glass3DTokens.Space.s)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// The coming banners stacked like playing cards: the next one in front, the ones after it peeking out behind, each a
    /// little smaller, further right and dimmer. Moving on, the front card fades away (growing slightly) and the one
    /// beneath slides up into its place. Clicking a card shows that banner.
    var deck: some View {
        let shown = min(items.count - 1, 4)
        return ZStack(alignment: .leading) {
            // Drawn back to front, so the next banner's card ends up on top
            ForEach(Array(((pos + 1)..<(pos + 1 + shown)).reversed()), id: \.self) { p in
                let k = p - pos - 1
                let i = ((p % items.count) + items.count) % items.count
                Button { go(i) } label: { deckCard(items[i], k: k) }
                    .buttonStyle(.plainHand)
                    .accessibilityLabel(items[i].heroTitle)   // no tooltip: the card shows its title
                    .scaleEffect(1 - CGFloat(k) * 0.08, anchor: .trailing)
                    .offset(x: CGFloat(k) * 26)
                    // The front card leaves at once (its fading copy takes over; two fading copies overlapped into a
                    // ghost); a card at the back fades in or out instead of popping
                    .transition(.asymmetric(insertion: .opacity, removal: k == 0 ? .identity : .opacity))
            }
            // Moving forward: the card that was in front, drawn over the deck, fading away (growing slightly and
            // drifting left) while the one beneath takes its place
            if let l = leaving {
                deckCard(l, k: 0)
                    .scaleEffect(leavingGone ? 1.08 : 1)
                    .offset(x: leavingGone ? -30 : 0)
                    .opacity(leavingGone ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: deckW + CGFloat(shown - 1) * 26, height: deckW * 9 / 16, alignment: .leading)
    }

    private let deckW: CGFloat = 300
    @AppStorage("accent") private var accentName = "red"

    func deckCard(_ it: Item, k: Int) -> some View {
        CachedImage(url: emby.image(it.backdropId ?? it.Id, "Backdrop", width: 520)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.15) }
        .frame(width: deckW, height: deckW * 9 / 16).clipped()   // no name on the card (the banner beside it says it)
        .cornerRadius(Glass3DTokens.Radius.card)
        .modifier(ClassicLightCard(radius: 12, accent: Theme.accent(accentName), size: CGSize(width: deckW, height: deckW * 9 / 16),
                                   tracksHover: k == 0))   // the posters' light glass edge; glow on the front card
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card).fill(Color.black.opacity(Double(k) * 0.22)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// Page bullets: small dots centred under the banner; the current one wider in the accent.
    var thumbs: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, _ in
                let on = i == index % items.count
                Glass3DBannerDot(on: on, accent: Theme.accent(accentName)) { go(i) }
                .accessibilityLabel("Banner \(i + 1) of \(items.count): \(items[i].heroTitle)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.25), value: index)
    }

}

/// Wide card for the Continue Watching and Up Next rows: the series-page grid episode card (glass panel, picture
/// with only Play + Resume ring on it, title and one grey line under it).
struct ClassicResumeCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false
    /// The pointer is on the play button or the Resume ring: only that control glows then, not the card
    @State private var onPlay = false
    @AppStorage("accent") private var accentName = "red"

    var progress: Double { emby.progressFraction(item) }
    var hasProgress: Bool { progress > 0 && progress < 1 }
    /// The ring: resume from the saved position
    func resume() { Task { await emby.playFromHome(item, from: ProgressStyle.ringStart(resumeAt: emby.resumeAt(item))) } }
    /// The centre play button: from the beginning when partly watched
    func playCentre() { Task { await emby.playFromHome(item, from: ProgressStyle.centreStart(hasProgress: hasProgress)) } }
    /// Time left, only once started (Up Next: an episode you haven't begun shows no "left")
    var timeLeft: String? {
        guard let total = item.RunTimeTicks, total > 0 else { return nil }
        let pos = emby.positionTicks(item)
        guard pos > 0 else { return nil }
        return runtimeText(max(0, total - pos)) + " left"
    }
    /// Grey line under the title: "S2·E3 · Episode name · 23m left" / "1h 12m left" / year
    var subtitle: String {
        HomeCardText.subtitle(isEpisode: item.isEpisode, season: item.ParentIndexNumber, episode: item.IndexNumber,
                              name: item.Name, timeLeft: timeLeft, year: item.ProductionYear)
    }
    /// Card click: an episode opens its series page on that episode's season; a movie opens its own page.
    func openPage() { emby.openPage(item) }

    /// Episodes have a landscape primary image; movies use their backdrop.
    var imageURL: URL? {
        item.isEpisode ? emby.episodeImage(item, width: 520) : emby.image(item.backdropId ?? item.Id, "Backdrop", width: 520)
    }

    /// The card keeps its old outer width (260); the picture sits inside the glass panel (padding s + 2 pt room)
    static let cardWidth: CGFloat = 260

    var body: some View {
        Group {
            // Same card as the series page's episode grid (owner): glass panel with big corners, the picture with its
            // own rounded corners, and ALL text under the picture. On the picture: only Play (hover) and the Resume ring.
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                Color.clear.frame(minWidth: 0, maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedImage(url: imageURL) { p in
                            p.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color(white: 0.15) }
                        .modifier(ZoomInsideOnHover())   // zooms inside its frame on hover, the card keeps its size
                    }
                    .clipped()
                    // How far you got: glow line along the bottom, Resume ring bottom-right
                    .overlay { ThumbnailProgress(fraction: progress, resumeAt: emby.resumeAt(item), onResume: resume) }
                    // Play button: from the beginning when partly watched; clicking anywhere else on the card opens the page
                    .overlay {
                        if hover {
                            Button(action: playCentre) {
                                Label("Play", systemImage: "play.fill").classicGlassPill(size: 46)
                            }.buttonStyle(.plainHand)
                            .tip(ProgressStyle.centreTip(hasProgress: hasProgress) ?? "")
                            .accessibilityLabel(ProgressStyle.centreTip(hasProgress: hasProgress) ?? "Play")
                            .reportsThumbnailInnerHover()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous))
                    .modifier(ClassicLightCard(radius: Glass3DTokens.Radius.card, accent: Theme.accent(accentName)))   // the card's edge lights instead
                    .classicHoverLift(lift: false)   // no lift out of the card; passes the hover down for the zoom
                // Under the picture: bold title, then one grey line
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    Text(item.heroTitle).cvFont(14, weight: .semibold).foregroundColor(Glass3DTokens.Grey.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle.isEmpty ? " " : subtitle).cvFont(12, weight: .regular).foregroundColor(Glass3DTokens.Grey.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(EpisodeGridPanel(active: true))
            .frame(width: Self.cardWidth, alignment: .leading)
            .contentShape(Rectangle())
            .scrollHover($hover)
            .onChange(of: hover) { _, h in onPlay = ThumbnailHover.innerAfterCardHover(h, inner: onPlay) }   // the controls go with the hover
            // Play and the Resume ring share one flag: on either, only that control glows, not the card
            .modifier(ThumbnailInnerHoverScope(flag: $onPlay, value: onPlay))
            .onTapGesture { openPage() }.handCursor()
            // Keyboard and VoiceOver: one element that opens the page (Return), with Resume as an action; the
            // Resume button itself only shows under the pointer
            .focusable()
            .focusEffectDisabled()   // no blue macOS focus ring after a click
            .onKeyPress(.return) { openPage(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(subtitle)
            .accessibilityAction { openPage() }
            .accessibilityAction(named: "Resume") { resume() }
            .accessibilityAction(named: "Play from the beginning") { playCentre() }
            .accessibilityLabel(item.isEpisode ? "\(item.heroTitle) — \(item.Name)" : item.Name)   // no tooltip on these cards
        }
    }
}

/// Settings → Home → Banner → Navigation: "deck" (Cards, the stacked previews; default) or "bullets" (dots).
enum Glass3DBannerNav {
    static let key = "classicBannerNav"
    static let defaultValue = "deck"
    static let options: [(String, String)] = [("deck", "Cards"), ("bullets", "Bullets")]
}

/// One banner bullet: the current one wider and in the accent, the others white at half strength; a light
/// brightening under the pointer. Clicking jumps to that banner.
struct Glass3DBannerDot: View {
    let on: Bool
    let accent: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Capsule().fill(on ? accent : Color.white.opacity(hover ? 0.8 : 0.5))
                .frame(width: on ? 24 : 8, height: 8)
                .brightness(hover && !on ? 0.15 : 0)   // light only, no growth (owner)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plainHand)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
    }
}
