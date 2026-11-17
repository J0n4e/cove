import IOKit.pwr_mgt
import SwiftUI
import AVKit

// MARK: - Favorites

/// Movies and shows marked as favorite, in two sections. Refreshes each time the page is shown,
/// and hides anything un-favorited from the detail page right away.
struct ClassicFavoritesView: View {
    @EnvironmentObject var emby: Emby
    /// "row" (scrolling row per section), "grid" or "list"; set in Settings → Libraries.
    @AppStorage("favoritesLayout") private var layout = "row"
    @Environment(\.appBG) var bg
    @StateObject private var model = FavoritesModel()

    var body: some View {
        let items = model.items, people = model.people, loading = model.loading
        let favs = items.filter { emby.isFav($0) }
        let s = FavoritesModel.sections(favs)
        let movies = s.movies, shows = s.shows, episodes = s.episodes, collections = s.collections
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Count as small grey text under the title, as on library pages
                VStack(alignment: .leading, spacing: 4) {
                    ClassicPageTitle(text: "Favorites", icon: "heart.fill")
                    if !favs.isEmpty {
                        Text(Glass3DTokens.itemCount(favs.count))
                            .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                }
                if !movies.isEmpty { section("Favorite Movies", movies) }
                if !shows.isEmpty { section("Favorite Shows", shows) }
                if !episodes.isEmpty { section("Favorite Episodes", episodes) }
                if !collections.isEmpty { section("Favorite Collections", collections) }
                let favPeople = people.filter { emby.isFav($0) }
                if !favPeople.isEmpty { peopleSection(favPeople) }
                if loading && items.isEmpty { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if favs.isEmpty && !people.contains(where: { emby.isFav($0) }) {
                    ClassicEmptyState(symbol: "heart", title: "No favorites yet",
                                      message: "Tap the heart on a movie, show, collection, episode or person to add it here.")
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .classicScrollBars()   // thin overlay bars, only while scrolling
        .background(bg)
        .environment(\.inFavorites, true)   // no heart on the posters: everything here is a favorite
        // Loads on appear and again when something was added or removed elsewhere (a cast photo, an episode).
        // .task(id:) cancels the previous fetch on each change and when the page goes away, so an older
        // response can't land last and overwrite a newer one.
        .task(id: emby.favRevision) { await model.load(emby) }
    }

    /// Emby-style row: "Favorite Movies ›" heading (opens the full grid) and a scrolling row of posters.
    /// Portrait photos of favorite actors and directors, poster-sized; a click opens their page.
    /// Follows the Favorites layout (Row, Grid or List) like the other sections.
    func peopleSection(_ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Favorite People ›" opens all of them on their own page, like the other sections
            NavigationLink(value: FavoritePeopleRef()) {
                HStack(spacing: 6) {
                    Text("Favorite People").cvFont(Glass3DTokens.Text.section, weight: .bold)
                    Image(systemName: "chevron.right").cvFont(17, weight: .bold).foregroundColor(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHand)
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { ClassicFavPersonCard(p: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { FavPersonListRow(p: $0, link: PersonRef(id: $0.id, name: $0.Name)) } }
            } else {
                let byId = Dictionary(list.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 150, spacing: 16, inset: 0) { id in
                    if let p = byId[id] { ClassicFavPersonCard(p: p) }
                }
            }
        }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        let byId = Dictionary(list.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 8) {
            // Opened through the page path (like every other page), so Back shows and the top bar can leave it
            NavigationLink(value: FavoriteGridRef(title: title, ids: list.map(\.Id))) {
                HStack(spacing: 6) {
                    Text3D(text: title, size: 16)
                    Text3D(image: Image(systemName: "chevron.right"), size: 16)
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHand).tip("Show all")
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { ClassicPosterCard(item: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { ListRow(item: $0) } }
            } else {
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 150, spacing: 16, inset: 0) { id in
                    if let it = byId[id] { ClassicPosterCard(item: it) }
                }
            }
        }
    }
}

struct ClassicFavoriteGridView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let title: String
    let ids: [String]
    @StateObject private var model = FavoriteGridModel()

    var body: some View {
        // AppKit grid (see PosterGrid); the title scrolls with the posters
        GeometryReader { g in
            PosterGrid(emby: emby, items: model.items.filter { emby.isFav($0) },
                       insets: NSEdgeInsets(top: 0, left: 32, bottom: 24, right: 32),
                       header: AnyView(ClassicPageTitle(text: title, icon: "heart.fill")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.top, 24)),
                       topInset: g.safeAreaInsets.top, spacing: 16, lineSpacing: 22,
                       open: { ClassicNavState.shared.open($0) })
            .ignoresSafeArea(edges: .top)
            .modifier(ClassicGridTopFade())   // the AppKit grid: soft fade under the bar
        }
        .background(bg)
        .environment(\.inFavorites, true)   // no heart on the posters: everything here is a favorite
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: { dismiss() }) }
        .classicHideToolbarTitle()
        .task { await model.load(emby, ids: ids) }
    }
}

/// One favorite person: poster-sized portrait and name; opens their page, heart on hover removes them.
struct ClassicFavPersonCard: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    let p: Item
    var body: some View {
        NavigationLink(value: PersonRef(id: p.id, name: p.Name)) {
            VStack(spacing: 8) {
                CachedImage(url: emby.image(p.id, width: 360)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").cvFont(50).foregroundColor(.secondary) }
                }
                .frame(width: 150, height: 225).clipShape(RoundedRectangle(cornerRadius: 12))
                .modifier(ClassicLightCard(radius: 12, accent: Theme.accent(accentName), size: CGSize(width: 150, height: 225),
                                           tracksHover: true))   // the posters' light glass edge, and their glow
                .modifier(HoverPersonHeart(id: p.id, name: p.Name))
                .classicHoverLift()
                Text(p.Name).cvFont(12, weight: .semibold).lineLimit(1)
            }.frame(width: 150)
        }.buttonStyle(.plainHand)
    }
}

/// Every favorite person in a grid.
struct ClassicFavoritePeopleView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    @StateObject private var model = FavoritePeopleModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClassicPageTitle(text: "Favorite People", icon: "person.2.fill")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(model.people.filter { emby.isFav($0) }) { ClassicFavPersonCard(p: $0) }
                }
            }.padding(.horizontal, 32).padding(.vertical, 24)
        }
        .classicScrollBars()   // thin overlay bars, only while scrolling
        .background(bg)
        .navigationTitle("Favorite People")
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: { dismiss() }) }
        .classicHideToolbarTitle()
        .task(id: emby.favRevision) { await model.load(emby) }
    }
}
