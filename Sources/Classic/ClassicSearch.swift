import IOKit.pwr_mgt
import SwiftUI
import AVKit

struct ClassicSearchBar: View {
    @Binding var query: String
    @Environment(\.appBG) var bg
    @ObservedObject private var nav = ClassicNavState.shared
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search movies, shows, people", text: $query).textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: nav.focusSearch) { focused = true }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plainHand)
                }
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .background(ClassicGlassBacking(shape: Capsule()))   // glass field, as the search box
            .frame(width: 280)
        }
        .padding(.horizontal, 32).padding(.vertical, 10)
        .background(bg)
    }
}

struct ClassicSearchView: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.appBG) var bg
    let query: String
    @StateObject private var model = SearchModel()
    private var results: [Item] { model.results }
    private var people: [Item] { model.people }
    private var busy: Bool { model.busy }
    var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results for “\(query)”").cvFont(17, weight: .bold)
            if !people.isEmpty { peopleRow }
            if !people.isEmpty && !results.isEmpty { Text("Titles").cvFont(Glass3DTokens.Text.section, weight: .bold).padding(.top, 8) }
        }
    }

    var body: some View {
        Group {
            if !results.isEmpty {
                // The titles: AppKit grid (see PosterGrid), with the heading and people scrolling above them
                GeometryReader { g in
                    PosterGrid(emby: emby, items: results,
                               insets: NSEdgeInsets(top: 0, left: 40, bottom: 40, right: 40),
                               header: AnyView(heading.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 40).padding(.top, 40)),
                               topInset: g.safeAreaInsets.top, push: { ClassicNavState.shared.push($0) },
                               open: { ClassicNavState.shared.open($0) })
                    .ignoresSafeArea(edges: .top)
                    .modifier(ClassicGridTopFade())   // the AppKit grid: soft fade under the bar
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        if busy { Spinner() }
                        else if people.isEmpty {
                            ClassicEmptyState(symbol: "magnifyingglass", title: "No results",
                                              message: "Nothing matches “\(query)”. Try another title, person or spelling.")
                        }
                    }.padding(40)
                }
                .classicScrollBars()   // thin overlay bars, only while scrolling
            }
        }
        .background(bg)
        .task(id: query) { await model.run(query, source: emby) }
    }

    /// Matching people as poster-sized portraits; each opens the person's page.
    var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").cvFont(Glass3DTokens.Text.section, weight: .bold)
            // In rows like the titles below, not one line that scrolls sideways
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(people) { p in
                        PageLink(value: PersonRef(id: p.Id, name: p.Name)) {
                            VStack(spacing: 6) {
                                CachedImage(url: emby.image(p.Id, width: 360)) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").cvFont(50).foregroundColor(.secondary) }
                                }
                                // Poster-sized portrait, like the other result cards
                                .frame(width: 150, height: 225).clipShape(RoundedRectangle(cornerRadius: 12))
                                .modifier(ClassicLightCard(radius: 12, accent: Theme.accent(accentName), size: CGSize(width: 150, height: 225),
                                           tracksHover: true))   // the posters' light glass edge, and their glow
                                .overlay(alignment: .topLeading) {
                                    if emby.isPersonFav(p.Id) {
                                        FavHeart(size: 16).padding(8)
                                    }
                                }
                                .modifier(HoverPersonHeart(id: p.Id, name: p.Name))
                                .classicHoverLift()
                                Text(p.Name).cvFont(12, weight: .semibold).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(width: 150)
                        }
                        .buttonStyle(.plainHand).accessibilityLabel("Show everything with \(p.Name)")   // no tooltip on actors
                    }
            }.padding(.vertical, 8)
        }
        .task { _ = await emby.favoritePeople() }   // hearts on favorite people
    }
}
