import SwiftUI

// Play collection (Glass3D): the collection page's Play collection / Resume <film> buttons and the player's
// Collection panel (the Episodes panel's look). Logic in Sources/Shared/CollectionPlay.swift.

/// The collection page's play buttons: "Play collection" (film 1 from the start) and, when a film of the collection
/// is in progress, "Resume <film> (1:12:30)", which continues the collection from that film.
struct CollectionPlayButtons: View {
    @EnvironmentObject var emby: Emby
    let collection: Item
    /// The collection's films in the server's order
    let films: [Item]

    var body: some View {
        let resume = CollectionPlay.resumeIndex(films: films, position: { emby.resumeAt($0) }, played: { emby.isPlayed($0) })
        HStack(spacing: Glass3DTokens.Space.m) {
            Button { start(at: 0, from: 0) } label: {
                Label("Play collection", systemImage: "play.fill").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton()).disabled(films.isEmpty)
            if let i = resume {
                let pos = emby.resumeAt(films[i])
                Button { start(at: i, from: pos) } label: {
                    // Short like the film page's Resume (owner): the time only, the film in the tooltip
                    Label(CollectionPlay.clock(pos), systemImage: "arrow.uturn.forward")
                        .lineLimit(1).classicGlassPill(size: 44, iconOnly: false)
                }.buttonStyle(HoverButton())
                .tip(CollectionPlay.resumeLabel(films[i], position: pos))
                .accessibilityLabel(CollectionPlay.resumeLabel(films[i], position: pos))
            }
        }
    }

    private func start(at i: Int, from pos: Double) {
        guard let q = CollectionPlay.queue(collection: collection, films: films, start: i) else { return }
        emby.playCollection(q, start: pos)
    }
}

/// The player's Collection panel: the collection's films (poster, title, year, ✓ watched), the playing one
/// highlighted; a click plays that film, still in collection mode.
struct CollectionPanel: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject var ui: PlayerUIModel
    let current: Item
    let classic: Bool
    let play: (Item) -> Void
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ui.collection?.name ?? "Collection").cvFont(18, weight: .bold).lineLimit(1)
                .padding(.horizontal, Glass3DTokens.Space.xl).padding(.top, Glass3DTokens.Space.l).padding(.bottom, Glass3DTokens.Space.s)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ui.episodes) { film in row(film).id(film.Id) }
                    }.padding(.bottom, Glass3DTokens.Space.m)
                }
                .classicScrollBars()
                .onAppear { proxy.scrollTo(current.Id, anchor: .center) }
            }
        }
        .frame(width: 400)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    private func row(_ film: Item) -> some View {
        let isCurrent = film.Id == current.Id
        let played = emby.isPlayed(film)
        return Button { if !isCurrent { ui.panel = nil; play(film) } } label: {
            HStack(spacing: Glass3DTokens.Space.m) {
                CachedImage(url: emby.image(film.Id, width: 200)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 46, height: 68).clipped().cornerRadius(Glass3DTokens.Radius.thumb)
                .overlay(alignment: .topTrailing) {
                    if played && !isCurrent {
                        Image(systemName: "checkmark.circle.fill").cvFont(12).foregroundColor(.white).shadow(radius: 2).padding(Glass3DTokens.Space.xs)
                    }
                }
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    Text(film.Name).cvFont(14, weight: .semibold).lineLimit(2)
                    if let y = film.ProductionYear { Text(String(y)).cvFont(12).foregroundColor(.secondary) }
                }
                Spacer(minLength: 0)
                if isCurrent { Image(systemName: "speaker.wave.2.fill").cvFont(14) }
            }
            .foregroundColor(.white)
            .padding(.horizontal, Glass3DTokens.Space.l).padding(.vertical, Glass3DTokens.Space.s)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous).fill(Theme.accent(accentName).opacity(0.4))
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
