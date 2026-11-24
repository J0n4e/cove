import SwiftUI

// Glass3D posters (v1.18.4, owner's option A): the badges at the top ARE the buttons. ♡ toggles the favourite,
// ✓ toggles watched. Both are always shown and never change on hover (owner): empty ♡ / dim ✓ when not set. No hover pills at the bottom any more.
// Small dark glass circles with white symbols (Glass3DTokens fill / stroke); your Trakt ★ keeps its number.

enum PosterBadges {
    /// Diameter of a badge circle.
    static let size: CGFloat = 23
    static let inset: CGFloat = 8
    /// The dim ✓ of a not-watched item (always shown).
    static let outlineOpacity = 0.35

    static func favTip(_ fav: Bool) -> String { fav ? "Remove from Favorites" : "Add to Favorites" }
    static func watchedTip(_ played: Bool) -> String { played ? "Mark as unwatched" : "Mark as watched" }
    /// The ✓ badge's tooltip: a series' count, a collection's "Mark all N films watched", else watchedTip.
    @MainActor static func watchedHelp(_ item: Item, played: Bool, unwatched n: Int, emby: Emby) -> String {
        if item.isBox { return CollectionWatched.tip(played: played, count: emby.boxFilms[item.id]?.count ?? item.ChildCount) }
        return n > 0 ? "\(n) unwatched episode\(n == 1 ? "" : "s") · \(watchedTip(played))" : watchedTip(played)
    }

    /// The favourite badge, always shown and never changed by hover (owner): "heart.fill" (favourite) or the
    /// empty "heart" (not a favourite). Always there, so the ★ next to it never moves.
    static func favSymbol(fav: Bool, hover: Bool) -> String? { fav ? "heart.fill" : "heart" }
    /// The watched badge, always shown and never changed by hover: "checkmark" (watched), the unwatched-episode
    /// count ("12", "99+"), or an empty-looking circle with a dim ✓ (outline = true: not watched).
    static func watchedContent(played: Bool, unwatched: Int, hover: Bool) -> (text: String, outline: Bool)? {
        if played { return ("checkmark", false) }
        if unwatched > 0 { return (unwatched > 99 ? "99+" : "\(unwatched)", false) }
        return ("checkmark", true)
    }
}

/// v1.19.0: the badges change at once; when the server refuses (or doesn't answer) they flip back with a message.
enum BadgeRollback {
    static let failureText = "Couldn\u{2019}t update \u{2014} try again"
    /// A new toast each time (its id), so a second failure shows again.
    static var failureToast: Emby.Toast { Emby.Toast(text: failureText, icon: "exclamationmark.triangle.fill") }
    /// The server took the change: HTTP 2xx.
    static func accepted(_ status: Int?) -> Bool { status.map { (200..<300).contains($0) } ?? false }
}

/// Season posters and episode thumbnails (v1.19.0): which badges they carry and where.
enum ItemBadgeRules {
    enum Kind { case season, episode }
    /// Seasons: ♡ (top left, as posters) and ✓ with the unwatched count (top right). Episodes: ♡ and ✓ together at
    /// the top right (the episode code sits top left, the Resume ring bottom right).
    static func badges(_ k: Kind) -> [String] { ["fav", "watched"] }
    static func favAtTopRight(_ k: Kind) -> Bool { k == .episode }
    /// The watched badge's count: seasons show their unwatched episodes, episodes never a count.
    static func unwatched(_ k: Kind, played: Bool, count: Int) -> Int { k == .season && !played ? max(0, count) : 0 }
}

/// The dark glass backing of a badge (circle or capsule).
/// Hovered card: a soft dark ring around each badge. The library grid gets it from the holes cut in its lit
/// hover edge around the badges (PosterGridCell.litMask, 3 pt out); SwiftUI cards draw it here (owner: "that nice shadow").
private struct PosterBadgeHaloKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var posterBadgeHalo: Bool {
        get { self[PosterBadgeHaloKey.self] }
        set { self[PosterBadgeHaloKey.self] = newValue }
    }
}

struct PosterBadgeGlass<S: InsettableShape>: View {
    let shape: S
    @Environment(\.posterBadgeHalo) private var halo
    var body: some View {
        shape.inset(by: -3).fill(Color.black.opacity(halo ? 0.38 : 0)).blur(radius: 2.5)
            .animation(Glass3DTokens.Motion.fast, value: halo)
            .allowsHitTesting(false)
            .overlay(shape.fill(Color.black.opacity(0.55))
            .overlay(shape.fill(Color.white.opacity(Glass3DTokens.Fill.strong)))
            .overlay(shape.strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
            .g3Shadow(Glass3DTokens.shadowSmall))
            // One look everywhere: the library grid bakes its badges with a dark colour scheme (Raster), so the
            // live badges (Home, Favorites, search, seasons, episodes, lists) render with the same one
            .environment(\.colorScheme, .dark)
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
    /// A season's episodes (their hearts follow it, as the old hover button did)
    var children: [Item] = []
    var body: some View {
        let fav = emby.isFav(item)
        if let s = PosterBadges.favSymbol(fav: fav, hover: hover) {
            Button { Task { await emby.setFavChecked(item.id, !fav, children: children, name: item.Name) } } label: {
                PosterBadgeCircle(symbol: s)   // empty ♡ in full white: clear without looking faded
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
    /// A season's episodes: the server marks them itself; their ticks update on screen right away
    var children: [Item] = []
    /// Seasons: the unwatched count shown in place of the outline (nil: the series' own count)
    var unwatched: Int? = nil
    var body: some View {
        let played = emby.isPlayed(item)
        let n = unwatched ?? (item.isSeries && !played ? (item.UserData?.UnplayedItemCount ?? 0) : 0)
        if let c = PosterBadges.watchedContent(played: played, unwatched: n, hover: hover) {
            Button { Task { await emby.setItemPlayed(item, !played, children: children, name: item.Name) } } label: {
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
            .helpLabel(PosterBadges.watchedHelp(item, played: played, unwatched: n, emby: emby))
            .onAppear { emby.ensureCollectionWatched(item) }
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
            // The ♡ is always shown, so the ★ never moves
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

/// Season posters and episode thumbnails (Glass3D series page, v1.19.0): the same ♡ / ✓ badge buttons as posters,
/// replacing the old hover buttons. Tracks the hover itself (after the overlay, so moving onto a badge keeps it).
struct ItemBadges: ViewModifier {
    let item: Item?   // nil: no badges (a season the server didn't list)
    let kind: ItemBadgeRules.Kind
    var children: [Item] = []
    var unwatched = 0
    var inset: CGFloat = PosterBadges.inset
    @EnvironmentObject var emby: Emby
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let item, !ItemBadgeRules.favAtTopRight(kind) {
                    PosterFavBadge(item: item, hover: hover, children: children).padding(inset)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let item {
                    HStack(spacing: 5) {
                        if ItemBadgeRules.favAtTopRight(kind) { PosterFavBadge(item: item, hover: hover, children: children) }
                        PosterWatchBadge(item: item, hover: hover, children: children,
                                         unwatched: ItemBadgeRules.unwatched(kind, played: emby.isPlayed(item), count: unwatched))
                    }
                    .padding(inset)
                }
            }
            .environment(\.posterBadgeHalo, hover)
            .scrollHover($hover)
    }
}
extension View {
    func itemBadges(_ item: Item?, _ kind: ItemBadgeRules.Kind, children: [Item] = [], unwatched: Int = 0,
                    inset: CGFloat = PosterBadges.inset) -> some View {
        modifier(ItemBadges(item: item, kind: kind, children: children, unwatched: unwatched, inset: inset))
    }
}

// MARK: - v1.18.6: one badge look on every poster kind

/// What a poster shows in its badge slots: the same for movies, TV shows, seasons and collections, and the same at
/// rest and on hover (only the poster's zoom scales it).
struct PosterBadgeState: Equatable {
    enum Kind: CaseIterable { case movie, series, season, collection }
    /// ♡ (top left, always)
    let fav: String
    /// ★ number next to the ♡ (only when rated)
    let rating: Int?
    /// ✓ slot (top right, always): "checkmark", or the unwatched count of a series / season
    let watched: String
    /// The ✓ is the dim one (not watched)
    let dim: Bool
    /// The ✓ slot is a capsule (an unwatched count) rather than a circle
    let capsule: Bool

    static func of(_ kind: Kind, fav: Bool, played: Bool, unwatched: Int = 0, rating: Int? = nil, hover: Bool) -> PosterBadgeState {
        // Only series and seasons carry an unwatched count; movies and collections show ✓ / dim ✓
        let n = (kind == .series || kind == .season) && !played ? max(0, unwatched) : 0
        let w = PosterBadges.watchedContent(played: played, unwatched: n, hover: hover) ?? ("checkmark", true)
        return PosterBadgeState(fav: PosterBadges.favSymbol(fav: fav, hover: hover) ?? "heart", rating: rating,
                                watched: w.text, dim: w.outline, capsule: n > 0)
    }

    static func kind(_ item: Item) -> Kind {
        if item.isSeries { return .series }
        switch item.`Type` {
        case "Season": return .season
        case "BoxSet": return .collection
        default: return .movie
        }
    }
}

/// The badges of a list-view row (Glass3D library list): the same ♡ ★ ✓ components as the posters, in a line at
/// the row's end, always shown (no hover buttons).
struct PosterBadgesInline: View {
    let item: Item
    var body: some View {
        HStack(spacing: 5) {
            PosterBadgesLeading(item: item, hover: false)
            PosterWatchBadge(item: item, hover: false)
        }
    }
}

/// The season / collection card deck's front card (series page, season layout "Cards"; collection pages): the
/// poster badges in place of the old hover buttons and count badge. Seasons: ♡ and ✓ with the unwatched count;
/// a collection's front movie: ♡ ★ ✓ as every movie poster. Cards behind show nothing (seasons) or the ✓ of a
/// watched movie (collections), in the same dark glass circle.
struct DeckCardBadges: ViewModifier {
    let front: Bool
    let item: Item?
    var episodes: [Item] = []
    var unwatched: Int? = nil
    /// Collections: whether this (back) card's movie is watched; nil for seasons
    var watched: Bool? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if front, let item, watched != nil {
            content.overlay { PosterBadgesOverlay(item: item, hover: false) }
        } else if front {
            content.itemBadges(item, .season, children: episodes, unwatched: unwatched ?? 0)
        } else {
            content.overlay(alignment: .topTrailing) {
                if watched == true {
                    PosterBadgeCircle(symbol: "checkmark").helpLabel("Watched").padding(PosterBadges.inset)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
