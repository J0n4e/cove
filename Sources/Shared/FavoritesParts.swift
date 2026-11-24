import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// Full grid for one Favorites section (the › in the heading).
/// A Favorites section ("Favorite Movies ›" and so on) opened as a page.
struct FavoriteGridRef: Hashable {
    let title: String
    let ids: [String]
}

/// "Favorite People ›" opened as a page.
struct FavoritePeopleRef: Hashable {}

/// A favorite person as a list row (Favorites in List layout): small photo and name; a click opens their page.
struct FavPersonListRow<Link: Hashable>: View {
    @EnvironmentObject var emby: Emby
    let p: Item
    let link: Link
    @State private var hover = false
    var body: some View {
        NavigationLink(value: link) {
            HStack(spacing: Glass3DTokens.Space.l) {
                CachedImage(url: emby.image(p.id, width: 120)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").foregroundColor(.secondary) }
                }
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb))
                Text(p.Name).coveFont(size: 13, weight: .semibold).lineLimit(1)
                Spacer(minLength: 0)
                if emby.isFav(p) { FavHeart(size: 15) }
            }
            .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s)
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row).fill(Color.white.opacity(hover ? 0.1 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .scrollHover($hover)
    }
}
