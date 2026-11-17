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
        let underBar = !hero.isEmpty && bannerStyle != "card"
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !hero.isEmpty {
                    ClassicHero(items: hero, pageH: pageH)
                        // The server pill over the banner's top left, below the top bar and the traffic lights
                        .overlay(alignment: .topLeading) {
                            ServerPillMenu(classic: true)
                                .padding(.top, (underBar ? topInset : 0) + 12)
                                .padding(.leading, bannerStyle == "card" ? 44 : 32)
                        }
                } else {
                    ServerPillMenu(classic: true).padding(.leading, 32).padding(.top, 12)
                }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        Glass3DRowHeading(title: row.title, seeAll: row.libId.map { id in { ClassicNavState.shared.sel = id } })
                            .padding(.horizontal, 32)
                        let wide = row.title == "Continue Watching"
                        // Continue Watching has its own Row / Grid choice; every other section follows Home's
                        if (wide ? resumeLayout : homeLayout) == "grid" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 260 : 150), spacing: 14)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(row.items) { it in
                                    if wide { ClassicResumeCard(item: it) } else { ClassicPosterCard(item: it) }
                                }
                            }.padding(.horizontal, 32)
                        } else if wide {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 260, spacing: 14, inset: 32) {
                                ClassicResumeCard(item: row.items[$0])
                            }
                        } else {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 150, spacing: 14, inset: 32) {
                                ClassicPosterCard(item: row.items[$0])
                            }
                        }
                    }
                }
                if model.loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if model.rows.isEmpty, let m = emby.lastFailure {
                    // The server couldn't be reached: say so, instead of an empty page
                    ErrorStateView(message: m, retry: { model.retry() },
                                   switchServer: { emby.switchServer() }).padding(.top, 80)
                }
            }.padding(.bottom, 40)
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
            content.clipShape(RoundedRectangle(cornerRadius: 18))
                .modifier(ClassicLightCard(radius: 18))   // the posters' light glass edge, drawn once per size
                .padding(.horizontal, 32)
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
    @State private var hover = false
    @State private var width: CGFloat = 1200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @ObservedObject private var nav = ClassicNavState.shared
    /// Settings → General → Home banner: "cinematic" (edge to edge), "panel" (text on a glass panel) or "card"
    /// (an inset glass-framed card)
    @AppStorage("classicBannerStyle") private var style = "cinematic"
    /// Settings → General → Banner navigation: "deck" (cards, bottom right) or "bullets" (bottom center)
    @AppStorage("classicBannerNav") private var bannerNav = "deck"
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
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: min(Int(width * 2), 2560)) }.clipped()   // Retina-sharp
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
                        .modifier(ClassicClearGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.35)))
                } else { info(item) }
            }
            .padding(.leading, style == "card" ? 44 : 80).padding(.bottom, 56)
            // Old text fades out quickly, then the new text fades in (they overlapped mid-change)
            .id("t" + item.id)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.3)),
                                    removal: .opacity.animation(.easeIn(duration: 0.25))))
            .zIndex(Double(pos) + 0.6)
            // The coming banners as a deck of cards, bottom right (above the changing picture and text)
            Group {
                if items.count > 1 {
                    if bannerNav == "bullets" {
                        thumbs.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 26)
                    } else {
                        deck.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.trailing, 44).padding(.bottom, 56)
                    }
                }
            }.zIndex(Double(pos) + 1)
        }
        .animation(.easeOut(duration: 0.15), value: hover)
        .frame(height: style == "card" ? max(bannerH - 24, 340) : bannerH)
        .modifier(BannerShape(card: style == "card"))
        .foregroundColor(.white)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        .scrollHover($hover)
        .onChange(of: nav.bannerNudge) { _, n in if let n, !items.isEmpty { go(index + n.dir) } }   // ← → keys
        // Next banner every 9 s, but not under the pointer, not during playback and not with Reduce Motion
        .task(id: "\(pos)-\(hover)-\(playback.active)") {
            guard !hover, !playback.active, !reduceMotion, items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
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
            HStack(spacing: 10) {
                Text(meta(item))
                if let r = item.CommunityRating {
                    HStack(spacing: 3) { Image(systemName: "star.fill"); Text(String(format: "%.1f", r)) }
                }
            }.cvFont(15, weight: .medium).foregroundColor(.white.opacity(0.9))
            Text(item.Overview ?? "").cvFont(15).lineLimit(3).truncationMode(.tail)
                .foregroundColor(.white.opacity(0.8)).frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 12) {
                Button { Task { await emby.playFromHome(item) } } label: {
                    Label(emby.resumeAt(item) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                        .classicGlassPill(size: 46, iconOnly: false)
                }.buttonStyle(HoverButton())
                let fav = emby.isFav(item)
                Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                    Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "checkmark" : "plus")
                        .classicGlassPill(size: 46).glass3DRoundOutline()
                }.buttonStyle(HoverButton()).helpLabel(fav ? "Remove from Favorites" : "Add to Favorites")
                NavigationLink(value: item) {
                    Label("More Info", systemImage: "info").classicGlassPill(size: 46).glass3DRoundOutline()
                }.buttonStyle(HoverButton()).helpLabel("More Info")
            }.padding(.top, 6)
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
        .cornerRadius(12)
        .modifier(ClassicLightCard(radius: 12, accent: Theme.accent(accentName), size: CGSize(width: deckW, height: deckW * 9 / 16),
                                   tracksHover: k == 0))   // the posters' light glass edge; glow on the front card
        .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(Double(k) * 0.22)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// Page bullets: small glass pills; the current one stretches longer and is lit.
    var thumbs: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, _ in
                let on = i == index % items.count
                Button { go(i) } label: {
                    Capsule().fill(Color.white.opacity(on ? 0.85 : 0.25))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.15)],
                                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                        .frame(width: on ? 26 : 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(HoverButton())
                .accessibilityLabel("Banner \(i + 1) of \(items.count): \(items[i].heroTitle)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.25), value: index)
    }

}

/// Landscape card for the Continue Watching row: still image, accent progress bar, time left.
struct ClassicResumeCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false
    /// The pointer is on the play button: only the button glows then, not the card (as the episode cards)
    @State private var onPlay = false
    @AppStorage("accent") private var accentName = "red"

    var progress: Double { min(1, max(0, (item.UserData?.PlayedPercentage ?? 0) / 100)) }
    var timeLeft: String? {
        guard let total = item.RunTimeTicks, total > 0 else { return nil }
        let left = max(0, total - (item.UserData?.PlaybackPositionTicks ?? 0))
        return runtimeText(left) + " left"
    }
    var subtitle: String? {
        if item.isEpisode { return "S\(item.ParentIndexNumber ?? 0)·E\(item.IndexNumber ?? 0)" + (timeLeft.map { " · " + $0 } ?? "") }
        return timeLeft
    }
    /// Card click: an episode opens its series page on that episode's season; a movie opens its own page.
    func openPage() { emby.openPage(item) }

    /// Episodes have a landscape primary image; movies use their backdrop.
    var imageURL: URL? {
        item.isEpisode ? emby.image(item.Id, width: 520, plain: true) : emby.image(item.backdropId ?? item.Id, "Backdrop", width: 520)
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: imageURL) { p in
                    p.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.15); Text(item.heroTitle).cvFont(10, weight: .regular).padding(6) }
                }
                .frame(width: 260, height: 146).clipped()
                .overlay { ThumbnailScrim() }   // soft dark gradient behind the code, time left and title
                // Title, bottom-left
                .overlay(alignment: .bottomLeading) {
                    // No background: a black outline keeps it readable
                    Text(item.heroTitle)
                        .cvFont(12, weight: .semibold).foregroundColor(.white).lineLimit(1)
                        .classicBlackOutline()
                        .padding(.leading, 10).padding(.trailing, 10).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Series info (S3·E3 · 42m left), top-left
                .overlay(alignment: .topLeading) {
                    if let subtitle {
                        Text(subtitle).cvFont(10, weight: .semibold).foregroundColor(.white)
                            .classicBlackOutline().padding(10)
                    }
                }
                // How far you got, bottom-right
                .overlay { ThumbnailProgressLine(fraction: progress) }   // thin accent line (was a ring)
                // Play button: resumes playback; clicking anywhere else on the card opens the page
                .overlay {
                    if hover {
                        Button { Task { await emby.playFromHome(item) } } label: {
                            Label("Resume", systemImage: "play.fill").classicGlassPill(size: 46)
                        }.buttonStyle(.plainHand).accessibilityLabel("Resume")
                        .onHover { onPlay = $0 }
                    }
                }
                .cornerRadius(8)
                .modifier(ClassicLightCard(radius: 8, hover: hover && !onPlay, accent: Theme.accent(accentName),
                                           size: CGSize(width: 260, height: 146)))   // the posters' light glass edge
                .classicHoverLift()
            }
            .frame(width: 260, alignment: .leading)
            .contentShape(Rectangle())
            .scrollHover($hover)
            .onChange(of: hover) { _, h in if !h { onPlay = false } }   // the button goes with the hover
            .onTapGesture { openPage() }.handCursor()
            // Keyboard and VoiceOver: one element that opens the page (Return), with Resume as an action; the
            // Resume button itself only shows under the pointer
            .focusable()
            .focusEffectDisabled()   // no blue macOS focus ring after a click
            .onKeyPress(.return) { openPage(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(timeLeft ?? "")
            .accessibilityAction { openPage() }
            .accessibilityAction(named: "Resume") { Task { await emby.playFromHome(item) } }
            .accessibilityLabel(item.isEpisode ? "\(item.heroTitle) — \(item.Name)" : item.Name)   // no tooltip on these cards
        }
    }
}
