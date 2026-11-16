import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

// MARK: - Home

struct HomeContent: View {
    @EnvironmentObject var emby: Emby
    // Not observed: Home only sets the selection, so it shouldn't re-render when the Now Playing count changes
    private var nav: NavState { NavState.shared }

    /// "Title ›" like Apple TV: opens the full list (feed page) or the library.
    @ViewBuilder func rowTitle(_ row: Row) -> some View {
        let label = HStack(spacing: 6) {
            Text(row.title).font(.system(size: 22, weight: .bold))
            Image(systemName: "chevron.right").font(.system(size: 17, weight: .bold)).foregroundColor(.secondary)
        }.contentShape(Rectangle())
        if let f = row.feed {
            NavigationLink(value: f) { label }.buttonStyle(.plainHand).tip("Show all")
        } else if let id = row.libId {
            Button { nav.sel = id } label: { label }.buttonStyle(.plainHand).tip("Open \(row.title)")
        } else {
            Text(row.title).font(.system(size: 22, weight: .bold))
        }
    }
    @Environment(\.appBG) var bg
    @AppStorage("homeLayout") private var homeLayout = "row"
    @AppStorage("homeResumeLayout") private var resumeLayout = "row"
    @State private var pageH: CGFloat = .infinity
    let reloadToken: Int
    /// Rows, banner items and loading (shared with Classic); Glass prefetches the rows' first pictures.
    @StateObject private var model = HomeModel(prefetchRows: true)

    var body: some View {
        let hero = model.heroItems
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !hero.isEmpty { Hero(items: hero, pageH: pageH) }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        rowTitle(row).padding(.leading, 52)
                        let wide = row.feed == .resume || row.feed == .nextUp
                        // Continue Watching has its own Row / Grid choice; every other section follows Home's
                        if (row.feed == .resume ? resumeLayout : homeLayout) == "grid" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 340 : 170), spacing: 22)],
                                      alignment: .leading, spacing: 22) {
                                ForEach(row.items) { it in
                                    if wide { ResumeCard(item: it) } else { PosterCard(item: it) }
                                }
                            }.padding(.horizontal, 52)
                        } else if wide {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 340, spacing: 22, inset: 52) {
                                ResumeCard(item: row.items[$0])
                            }
                        } else {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 170, spacing: 22, inset: 52) {
                                PosterCard(item: row.items[$0])
                            }
                        }
                    }
                }
                if model.loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if model.rows.isEmpty, let m = emby.lastFailure {
                    // The server couldn't be reached: say so, instead of an empty black page
                    ErrorStateView(message: m, retry: { model.retry() },
                                   switchServer: { emby.switchServer() }).padding(.top, 120)
                }
            }.padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)          // banner runs up under the title bar, as in Apple TV
        .background(GeometryReader { g in
            Color.clear.onAppear { pageH = g.size.height }.onChange(of: g.size.height) { _, h in pageH = h }
        })
        .background(bg)
        .task(id: model.taskKey(reloadToken)) { model.bind(emby); await model.load() }
    }
}

struct Hero: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let items: [Item]
    /// Height of the visible page; the banner never grows past it, so the page dots stay on screen
    var pageH: CGFloat = .infinity
    @State private var index = 0
    @State private var hover = false
    @State private var width: CGFloat = 1200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @ObservedObject private var nav = NavState.shared
    var bannerH: CGFloat { min(max(width * 9 / 16, 460), 900, max(pageH - 20, 360)) }

    /// "TV Show · Comedy · Sport", like Apple TV.
    func meta(_ item: Item) -> String {
        var m: [String] = [item.isEpisode || item.isSeries ? "TV Show" : "Movie"]
        m += (item.Genres ?? []).prefix(2)
        return m.joined(separator: " · ")
    }

    func step(_ d: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { index = (index + d + items.count) % items.count }
    }

    var body: some View {
        let item = items[index % items.count]
        ZStack(alignment: .bottomLeading) {
            // The banner takes the picture's own shape (16:9), so the whole backdrop shows instead of a cropped
            // strip; it never gets shorter than 460 pt (narrow windows) or taller than 860 pt (very wide ones)
            // Full window width always; height follows the picture's 16:9 shape (460–900 pt). On very wide
            // windows the picture fills the width and is trimmed a little at top and bottom, never side gaps.
            Color.clear.frame(maxWidth: .infinity).frame(height: bannerH)
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: min(Int(width * 2), 2560)) }.clipped()   // Retina-sharp, not oversized
                .id("b" + item.id).transition(.opacity)
            // Dark fade on the left and at the bottom, so the text reads and the page flows into the rows
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5))
            LinearGradient(colors: [.clear, .clear, bg.opacity(0.6), bg], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                if item.isEpisode {
                    Text("S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0)")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
                }
                TitleLogo(item: item, height: 90, font: 54)
                HStack(spacing: 8) {
                    Text(meta(item))
                    if let y = item.ProductionYear { Text("· \(String(y))") }
                    if let r = item.CommunityRating {
                        HStack(spacing: 3) { Image(systemName: "star.fill"); Text(String(format: "%.1f", r)) }
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.7)))
                            .font(.system(size: 12, weight: .semibold))
                    }
                }.font(.system(size: 16, weight: .medium))
                Text(item.Overview ?? "").font(.system(size: 15)).lineLimit(3)
                    .foregroundColor(.white.opacity(0.8)).frame(maxWidth: 420, alignment: .leading)
                HStack(spacing: 14) {
                    Button { Task { await emby.playFromHome(item) } } label: {
                        Label(emby.resumeAt(item) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 170, height: 46)
                            .background(Capsule().fill(.white)).foregroundColor(.black)
                    }.buttonStyle(HoverButton())
                    let fav = emby.isFav(item)
                    Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                        Image(systemName: fav ? "checkmark" : "plus").font(.system(size: 18, weight: .semibold))
                            .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(HoverButton()).helpLabel(fav ? "Remove from Favorites" : "Add to Favorites")
                    NavigationLink(value: item) {
                        Image(systemName: "info").font(.system(size: 18, weight: .semibold))
                            .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(HoverButton()).helpLabel("More info")
                }.padding(.top, 8)
            }
            .padding(.leading, 52).padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("t" + item.id).transition(.opacity)
            // Page dots, centered at the bottom
            HStack(spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, _ in
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { index = i } } label: {
                        // The current banner's dot stretches into a pill so it stands out
                        Capsule().fill(Color.white.opacity(i == index % items.count ? 1 : 0.4))
                            .frame(width: i == index % items.count ? 16 : 7, height: 7)
                            .contentShape(Rectangle().inset(by: -5))
                    }
                    .buttonStyle(HoverButton())
                    .accessibilityLabel("Banner \(i + 1) of \(items.count): \(items[i].heroTitle)")
                    .accessibilityAddTraits(i == index % items.count ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity).padding(.bottom, 30)
        }
        .overlay {
            if hover && items.count > 1 {
                HStack {
                    heroArrow("chevron.left") { step(-1) }.helpLabel("Previous banner")
                    Spacer()
                    heroArrow("chevron.right") { step(1) }.helpLabel("Next banner")
                }.padding(.horizontal, 14)
            }
        }
        .scrollHover($hover)
        .onChange(of: nav.bannerNudge) { _, n in if let n { step(n.dir) } }   // ← → keys
        .clipped()
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        .foregroundColor(.white)
        // Turns to the next banner every 9 s, but not while the pointer is on it (you may be reading or about
        // to click), not while a video plays (no point downloading big banners then) and not with Reduce Motion
        .task(id: "\(index)-\(hover)-\(playback.active)") {
            guard !playback.active else { return }
            // Look ahead: the next two banners (picture and title logo) download while this one shows
            let w = min(Int(width * 2), 2560)
            var next: [URL?] = []
            for k in 1...2 where items.count > 1 {
                let it = items[(index + k) % items.count]
                next.append(emby.image(it.backdropId ?? it.Id, "Backdrop", width: w))
                next.append(emby.image(it.SeriesId ?? it.Id, "Logo", width: 700))
            }
            ImageCache.shared.prefetch(next)
            guard !hover, !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !Task.isCancelled { step(1) }
        }
    }

    func heroArrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 30, weight: .light))
                .frame(width: 44, height: 80).contentShape(Rectangle())
                .shadow(color: .black.opacity(0.6), radius: 4)
        }.buttonStyle(HoverButton(backing: true))
    }
}

/// Landscape card for the Continue Watching row: still image, accent progress bar, time left.
struct ResumeCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false

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

    /// "42m" (time left), as on Apple TV's cards.
    var leftShort: String? {
        guard let total = item.RunTimeTicks, total > 0 else { return nil }
        return runtimeText(max(0, total - (item.UserData?.PlaybackPositionTicks ?? 0)))
    }

    var body: some View {
        CachedImage(url: imageURL) { p in
            p.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack { Color(white: 0.15); Text(item.heroTitle).font(.caption).padding(6) }
        }
        .frame(width: 340, height: 191).clipped()
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.heroTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if item.isEpisode {
                    Text("S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0) · \(item.Name)")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                }
                // Apple TV's bottom line: ▶ short progress bar, time left
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    if progress > 0 && progress < 1 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.35))
                            Capsule().fill(Color.white).frame(width: 34 * progress)
                        }.frame(width: 34, height: 4)
                    }
                    if let l = leftShort { Text(l).font(.system(size: 13, weight: .medium)) }
                    Spacer()
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.top, 36).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            if hover {
                Button { Task { await emby.playFromHome(item) } } label: {
                    Image(systemName: "play.fill").font(.system(size: 22)).foregroundColor(.white)
                        .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
                }.buttonStyle(.plainHand).accessibilityLabel("Resume")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .thinBorder(12)
        .hoverLift()
        .frame(width: 340, alignment: .leading)
        .contentShape(Rectangle())
        .scrollHover($hover)
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

/// Full page for Continue Watching, Up Next or Recently Added.
struct FeedView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let feed: Feed
    var root = false
    @State private var items: [Item] = []
    @State private var loading = true
    var landscape: Bool { feed != .recent }

    var title: some View { Text(feed.rawValue).font(.system(size: 30, weight: .bold)) }

    var body: some View {
        Group {
            if !landscape && !items.isEmpty {
                // Recently Added: AppKit grid (see PosterGrid); the title scrolls with the posters
                GeometryReader { g in
                    PosterGrid(emby: emby, items: items, look: PosterLook(glass3D: false),
                               insets: NSEdgeInsets(top: 0, left: 52, bottom: 24, right: 52),
                               header: AnyView(title.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 52).padding(.top, 24)),
                               topInset: g.safeAreaInsets.top, spacing: 16, lineSpacing: 22,
                               open: { NavState.shared.open($0) })
                    .ignoresSafeArea(edges: .top)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        title
                        if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                        else if items.isEmpty { Text("Nothing here yet.").foregroundColor(.secondary) }
                        if landscape {   // Continue Watching and Up Next: wide cards, few of them
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 22)], alignment: .leading, spacing: 22) {
                                ForEach(items) { ResumeCard(item: $0) }
                            }
                        }
                    }
                    .padding(.horizontal, 52).padding(.vertical, 24)
                }
            }
        }
        .background(bg)
        .task { items = await emby.feed(feed); loading = false }
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: root ? nil : { dismiss() }) }
        .hideToolbarTitle()
    }
}
