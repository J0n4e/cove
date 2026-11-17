import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

// MARK: - Favorites

/// Movies and shows marked as favorite, in two sections. Refreshes each time the page is shown,
/// and hides anything un-favorited from the detail page right away.
struct FavoritesView: View {
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
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Favorites").coveFont(size: 22, weight: .bold)
                    if !favs.isEmpty { Text("\(favs.count) Items").foregroundColor(.secondary) }
                }
                if !movies.isEmpty { section("Favorite Movies", movies) }
                if !shows.isEmpty { section("Favorite Shows", shows) }
                if !episodes.isEmpty { section("Favorite Episodes", episodes) }
                if !collections.isEmpty { section("Favorite Collections", collections) }
                let favPeople = people.filter { emby.isFav($0) }
                if !favPeople.isEmpty { peopleSection(favPeople) }
                if loading && items.isEmpty { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if favs.isEmpty && !people.contains(where: { emby.isFav($0) }) {
                    VStack(spacing: 10) {
                        Image(systemName: "heart").coveFont(size: 40).foregroundColor(.secondary)
                        Text("No favorites yet").coveFont(size: 13, weight: .bold)
                        Text("Tap the heart on a movie, show, collection, episode or person to add it here.").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
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
                    Text("Favorite People").coveFont(size: 15, weight: .bold)
                    Image(systemName: "chevron.right").coveFont(size: 15, weight: .bold).foregroundColor(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHand)
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { FavPersonCard(p: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { FavPersonListRow(p: $0, link: PersonRef(id: $0.id, name: $0.Name)) } }
            } else {
                let byId = Dictionary(list.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 170, spacing: 16, inset: 0) { id in
                    if let p = byId[id] { FavPersonCard(p: p) }
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
                    Text(title).coveFont(size: 15, weight: .bold)
                    Image(systemName: "chevron.right").coveFont(size: 15, weight: .bold).foregroundColor(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHand).tip("Show all")
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { PosterCard(item: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { ListRow(item: $0) } }
            } else {
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 170, spacing: 16, inset: 0) { id in
                    if let it = byId[id] { PosterCard(item: it) }
                }
            }
        }
    }
}

/// Full grid for one Favorites section (the › in the heading).
/// A Favorites section ("Favorite Movies ›" and so on) opened as a page.
struct FavoriteGridRef: Hashable {
    let title: String
    let ids: [String]
}

struct FavoriteGridView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let title: String
    let ids: [String]
    @StateObject private var model = FavoriteGridModel()

    var body: some View {
        // AppKit grid (see PosterGrid); the title scrolls with the posters
        GeometryReader { g in
            PosterGrid(emby: emby, items: model.items.filter { emby.isFav($0) }, look: PosterLook(glass3D: false),
                       insets: NSEdgeInsets(top: 0, left: 32, bottom: 24, right: 32),
                       header: AnyView(Text(title).coveFont(size: 22, weight: .bold)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.top, 24)),
                       topInset: g.safeAreaInsets.top, spacing: 16, lineSpacing: 22,
                       open: { NavState.shared.open($0) })
            .ignoresSafeArea(edges: .top)
        }
        .background(bg)
        .environment(\.inFavorites, true)   // no heart on the posters: everything here is a favorite
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { await model.load(emby, ids: ids) }
    }
}

/// "Favorite People ›" opened as a page.
struct FavoritePeopleRef: Hashable {}

/// One favorite person: poster-sized portrait and name; opens their page, heart on hover removes them.
struct FavPersonCard: View {
    @EnvironmentObject var emby: Emby
    let p: Item
    var body: some View {
        NavigationLink(value: PersonRef(id: p.id, name: p.Name)) {
            VStack(spacing: 8) {
                CachedImage(url: emby.image(p.id, width: 360)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").coveFont(size: 50).foregroundColor(.secondary) }
                }
                .frame(width: 170, height: 255).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
                .modifier(HoverPersonHeart(id: p.id, name: p.Name))
                .hoverLift()
                Text(p.Name).coveFont(size: 12, weight: .semibold).lineLimit(1)
            }.frame(width: 170)
        }.buttonStyle(.plainHand)
    }
}

/// A favorite person as a list row (Favorites in List layout): small photo and name; a click opens their page.
struct FavPersonListRow<Link: Hashable>: View {
    @EnvironmentObject var emby: Emby
    let p: Item
    let link: Link
    @State private var hover = false
    var body: some View {
        NavigationLink(value: link) {
            HStack(spacing: 14) {
                CachedImage(url: emby.image(p.id, width: 120)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").foregroundColor(.secondary) }
                }
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
                Text(p.Name).coveFont(size: 13, weight: .semibold).lineLimit(1)
                Spacer(minLength: 0)
                if emby.isFav(p) { FavHeart(size: 15) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.1 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .scrollHover($hover)
    }
}

/// Every favorite person in a grid.
struct FavoritePeopleView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    @StateObject private var model = FavoritePeopleModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Favorite People").coveFont(size: 22, weight: .bold)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(model.people.filter { emby.isFav($0) }) { FavPersonCard(p: $0) }
                }
            }.padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .navigationTitle("Favorite People")
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task(id: emby.favRevision) { await model.load(emby) }
    }
}
