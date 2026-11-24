import IOKit.pwr_mgt
import SwiftUI
import AVKit

// MARK: - Now Playing (active sessions on the server)

// MARK: - Person

/// Everything in the user's libraries featuring one actor / director.
struct ClassicPersonView: View {
    @Environment(\.noBack) private var noBack
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let person: PersonRef
    @Environment(\.dismiss) var dismiss
    @StateObject private var model = PersonModel()

    var body: some View {
        let items = model.items, record = model.record, loading = model.loading
        let movies = model.movies, shows = model.shows
        ScrollView {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.page) {
                // Same header as the Glass theme
                PersonHeader(id: person.id, name: person.name, record: record, items: items, loading: loading)
                Group {
                    if !movies.isEmpty { section("Movies", movies) }
                    if !shows.isEmpty { section("Shows", shows) }
                    if loading { SkeletonShimmer().padding(.vertical, Glass3DTokens.Space.xxl).skeletonCrossfade() }
                    else if items.isEmpty {
                        ClassicEmptyState(symbol: "person.crop.rectangle", title: "No titles",
                                          message: "Nothing in your libraries with \(person.name).")
                    }
                }.padding(.horizontal, 52)
            }
            .padding(.bottom, Glass3DTokens.Space.pageWide)
        }
        .classicScrollBars()   // thin overlay bars, only while scrolling
        .ignoresSafeArea(edges: .top)
        .background(bg)
        .navigationTitle(person.name)
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: noBack ? nil : { dismiss() }) }
        .classicHideToolbarTitle()
        .task { await model.load(person.id, source: emby) }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Glass3DTokens.Space.s) {
                Text3D(text: title, size: 17)
                Text("\(list.count)").cvFont(15, weight: .regular).foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Glass3DTokens.Space.l)], alignment: .leading, spacing: Glass3DTokens.Space.xl) {
                ForEach(list) { ClassicPosterCard(item: $0) }
            }
        }
    }
}
