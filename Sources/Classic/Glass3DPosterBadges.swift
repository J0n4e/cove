import SwiftUI

// Glass3D posters (v1.18.4, owner's option A): the badges at the top ARE the buttons. ♡ toggles the favourite,
// ✓ toggles watched; while the pointer is on the poster, a faint outline ♡ / ✓ shows in the same spot when the
// item isn't a favourite / isn't watched yet, so it can be clicked. No hover pills at the bottom any more.
// Small dark glass circles with white symbols (Glass3DTokens fill / stroke); your Trakt ★ keeps its number.

enum PosterBadges {
    /// Diameter of a badge circle.
    static let size: CGFloat = 23
    static let inset: CGFloat = 8
    /// The faint outline badge (not favourite / not watched, poster hovered).
    static let outlineOpacity = 0.6

    static func favTip(_ fav: Bool) -> String { fav ? "Remove from Favorites" : "Add to Favorites" }
    static func watchedTip(_ played: Bool) -> String { played ? "Mark as unwatched" : "Mark as watched" }

    /// Which favourite badge shows: nil (none), "heart.fill" (favourite), "heart" (faint outline on hover).
    static func favSymbol(fav: Bool, hover: Bool) -> String? { fav ? "heart.fill" : (hover ? "heart" : nil) }
    /// Which watched badge shows: "checkmark" (watched), the unwatched-episode count text ("12", "99+"),
    /// the faint outline "checkmark" on hover, or nil.
    static func watchedContent(played: Bool, unwatched: Int, hover: Bool) -> (text: String, outline: Bool)? {
        if played { return ("checkmark", false) }
        if unwatched > 0 { return (unwatched > 99 ? "99+" : "\(unwatched)", false) }
        return hover ? ("checkmark", true) : nil
    }
}

/// The dark glass backing of a badge (circle or capsule).
struct PosterBadgeGlass<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape.fill(Color.black.opacity(0.55))
            .overlay(shape.fill(Color.white.opacity(Glass3DTokens.Fill.strong)))
            .overlay(shape.strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
            .g3Shadow(Glass3DTokens.shadowSmall)
    }
}

/// One round badge: a white symbol on dark glass (faint when `outline`).
struct PosterBadgeCircle: View {
    let symbol: String
    var outline = false
    var body: some View {
        Image(systemName: symbol).cvFont(PosterBadges.size * 0.46, weight: .bold)
            .foregroundColor(.white)
            .opacity(outline ? PosterBadges.outlineOpacity : 1)
            .frame(width: PosterBadges.size, height: PosterBadges.size)
            .background(PosterBadgeGlass(shape: Circle()))
            .contentShape(Circle())
    }
}

/// ♡ at the top left of a poster: a button toggling the favourite (doesn't open the item).
struct PosterFavBadge: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    let hover: Bool
    var body: some View {
        let fav = emby.isFav(item)
        if let s = PosterBadges.favSymbol(fav: fav, hover: hover) {
            Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                PosterBadgeCircle(symbol: s, outline: !fav)
            }
            .buttonStyle(.plainHand)
            .helpLabel(PosterBadges.favTip(fav))
        }
    }
}

/// ✓ at the top right of a poster: a button toggling watched. Unwatched series show their episode count there.
struct PosterWatchBadge: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    let hover: Bool
    var body: some View {
        let played = emby.isPlayed(item)
        let n = item.isSeries && !played ? (item.UserData?.UnplayedItemCount ?? 0) : 0
        if let c = PosterBadges.watchedContent(played: played, unwatched: n, hover: hover) {
            Button { Task { await emby.setPlayed(item.id, !played, name: item.Name) } } label: {
                if n > 0 {
                    Text(c.text).cvFont(11, weight: .bold).foregroundColor(.white)
                        .padding(.horizontal, 7).frame(minWidth: PosterBadges.size, minHeight: PosterBadges.size)
                        .background(PosterBadgeGlass(shape: Capsule()))
                        .contentShape(Capsule())
                } else {
                    PosterBadgeCircle(symbol: c.text, outline: c.outline)
                }
            }
            .buttonStyle(.plainHand)
            .helpLabel(n > 0 ? "\(n) unwatched episode\(n == 1 ? "" : "s") · \(PosterBadges.watchedTip(played))"
                             : PosterBadges.watchedTip(played))
        }
    }
}

/// Your Trakt rating: ★ and the number on a dark glass capsule. Not a toggle; a click on it does nothing (it
/// doesn't open the item either).
struct PosterRatingBadge: View {
    let item: Item
    @ObservedObject private var trakt = Trakt.shared
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        if let r = trakt.rating(item) {
            Button {} label: {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").cvFont(PosterBadges.size * 0.42, weight: .bold)
                        .foregroundColor(Theme.accent(accentName))
                    Text("\(r)").cvFont(11, weight: .bold).foregroundColor(.white)
                }
                .padding(.horizontal, 7).frame(minWidth: PosterBadges.size, minHeight: PosterBadges.size)
                .background(PosterBadgeGlass(shape: Capsule()))
                .contentShape(Capsule())
            }
            .buttonStyle(.plainHand)
            .helpLabel("Your rating: \(r)/10")
        }
    }
}

/// The top-left group: ♡ then your ★ rating.
struct PosterBadgesLeading: View {
    let item: Item
    let hover: Bool
    var body: some View {
        HStack(spacing: 5) {
            PosterFavBadge(item: item, hover: hover)
            PosterRatingBadge(item: item)
        }
    }
}

/// Both groups placed on a poster of any size (SwiftUI posters).
struct PosterBadgesOverlay: View {
    let item: Item
    let hover: Bool
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.allowsHitTesting(false)
            HStack(alignment: .top, spacing: 0) {
                PosterBadgesLeading(item: item, hover: hover)
                Spacer(minLength: 4)
                PosterWatchBadge(item: item, hover: hover)
            }
            .padding(PosterBadges.inset)
        }
    }
}
