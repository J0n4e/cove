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
            VStack(alignment: .leading, spacing: 34) {
                // Same header as the Glass theme
                PersonHeader(id: person.id, name: person.name, record: record, items: items, loading: loading)
                Group {
                    if !movies.isEmpty { section("Movies", movies) }
                    if !shows.isEmpty { section("Shows", shows) }
                    if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                    else if items.isEmpty {
                        Text("Nothing in your libraries with \(person.name).").foregroundColor(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }.padding(.horizontal, 52)
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(bg)
        .navigationTitle(person.name)
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: noBack ? nil : { dismiss() }) }
        .classicHideToolbarTitle()
        .task { await model.load(person.id, source: emby) }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text3D(text: title, size: 17)
                Text("\(list.count)").cvFont(15, weight: .regular).foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                ForEach(list) { ClassicPosterCard(item: $0) }
            }
        }
    }
}
