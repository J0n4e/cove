import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

// MARK: - Person

struct PersonRef: Hashable { let id: String; let name: String }

/// Everything in the user's libraries featuring one actor / director.
struct PersonView: View {
    @Environment(\.noBack) private var noBack
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let person: PersonRef
    @Environment(\.dismiss) var dismiss
    @State private var items: [Item] = []
    @State private var record: Item?
    @State private var loading = true

    var body: some View {
        let movies = items.filter { !$0.isSeries }
        let shows = items.filter { $0.isSeries }
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
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
        .ignoresSafeArea(edges: .top)          // the backdrop runs up under the title bar
        .background(bg)
        .navigationTitle(person.name)
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: noBack ? nil : { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            async let list = emby.itemsWithPerson(person.id)
            async let me = emby.person(person.id)
            items = await list
            record = await me
            loading = false
        }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text("\(list.count)").font(.system(size: 17)).foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], alignment: .leading, spacing: 24) {
                ForEach(list) { PosterCard(item: $0) }
            }
        }
    }
}

struct PersonHeader: View {
    @Environment(\.classicGlass) private var classic   // Glass3D theme
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let id: String
    let name: String
    let record: Item?
    let items: [Item]
    let loading: Bool

    var bio: String { record?.Overview ?? "" }
    var backdrop: Item? { items.first { $0.backdropId != nil } }

    /// "Born 12 March 1970 · Bucharest, Romania" (and "Died …" when the server has it).
    var facts: String {
        func day(_ s: String?) -> String? {
            guard let s, let d = ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z") else { return nil }
            return d.formatted(date: .long, time: .omitted)
        }
        var f: [String] = []
        if let b = day(record?.PremiereDate) { f.append("Born " + b) }
        if let place = record?.ProductionLocations?.first, !place.isEmpty { f.append(place) }
        if let d = day(record?.EndDate) { f.append("Died " + d) }
        return f.joined(separator: " · ")
    }

    @ViewBuilder func chip(_ text: String) -> some View {
        if classic {
            // Glass3D: glass like the buttons, but still (it is not a button: no hover glow)
            Text(text).font(.cv(13, weight: .semibold)).foregroundColor(.white).padding(.horizontal, 14).frame(height: 30)
                .modifier(ClassicClearGlass(shape: Capsule(), interactive: false))
        } else {
            Text(text).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        }
    }

    var body: some View {
        let movies = items.filter { !$0.isSeries }.count, shows = items.filter { $0.isSeries }.count
        ZStack(alignment: .bottomLeading) {
            // Backdrop: one of their titles, faded into the page
            Color.clear.frame(height: 460).frame(maxWidth: .infinity)
                .overlay {
                    if let b = backdrop {
                        Backdrop(id: b.backdropId ?? b.Id, width: 1600).opacity(0.45)
                    }
                }
                .clipped()
                .overlay(LinearGradient(colors: [bg.opacity(0.2), bg.opacity(0.75), bg], startPoint: .top, endPoint: .bottom))
            // Photo top lines up with the name
            HStack(alignment: .top, spacing: 36) {
                CachedImage(url: emby.image(id, width: 480)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.system(size: 70)).foregroundColor(.secondary) }
                }
                .frame(width: 280, height: 420).clipShape(RoundedRectangle(cornerRadius: 14))
                // Favorite: heart top left when it is one, heart button bottom right on hover (as on cast photos)
                .overlay(alignment: .topLeading) {
                    if emby.isPersonFav(id) {
                        FavHeart(size: 20).padding(12)
                    }
                }
                .modifier(HoverPersonHeart(id: id, name: name))
                .task { _ = await emby.favoritePeople() }   // knows whether this person is a favorite
                .modifier(PersonPhotoFrame(classic: classic))   // Glass3D: the glass card frame
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 12) {
                    Text(name).font(classic ? .cv(42, weight: .bold) : .system(size: 42, weight: .bold)).lineLimit(2)
                    if !facts.isEmpty { Text(facts).font(.system(size: 15)).foregroundColor(.secondary) }
                    HStack(spacing: 8) {
                        if !loading {
                            if movies > 0 { chip("\(movies) Movie\(movies == 1 ? "" : "s")") }
                            if shows > 0 { chip("\(shows) Show\(shows == 1 ? "" : "s")") }
                        }
                    }
                    if !bio.isEmpty {
                        Text(bio).font(.system(size: 15)).lineSpacing(4).foregroundColor(.white.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: 820, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 52).padding(.top, 90)
        }
    }
}
