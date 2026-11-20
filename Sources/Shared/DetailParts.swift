import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

func endsAtText(_ t: Int64) -> String {
    Date().addingTimeInterval(Double(t) / 10_000_000).formatted(date: .omitted, time: .shortened)
}

func parseDate(_ s: String?) -> Date? {
    guard let s, s.count >= 19 else { return nil }
    return ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
}

// MARK: - Detail / movie info

struct CastTile: View {
    @EnvironmentObject var emby: Emby
    let p: Full.Person
    @AppStorage("castSize") private var castSize = "normal"   // Settings → Libraries → Movie and show pages
    @State private var hover = false
    @Environment(\.classicGlass) private var classic   // Glass3D: outlined photo, Glass3D type
    var body: some View {
        let big = castSize == "large"
        VStack(spacing: 6) {
            CachedImage(url: emby.image(p.Id, width: big ? 360 : 240)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack { Color(white: 0.18); Image(systemName: "person.fill").coveFont(size: big ? 44 : 30).foregroundColor(.secondary) }
            }
            // Large: a portrait photo card (2:3); Normal: the round photo
            .frame(width: big ? 132 : 88, height: big ? 198 : 88)
            .clipShape(RoundedRectangle(cornerRadius: big ? 10 : 44))
            .overlay {
                if classic {
                    RoundedRectangle(cornerRadius: big ? 10 : 44)
                        .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(big ? 0.45 : 0), radius: 6, y: 3)
            // Favorites show a small heart top left, as posters do
            .overlay(alignment: .topLeading) {
                if emby.isPersonFav(p.Id) {
                    FavHeart(size: 16).padding(big ? 8 : 2)
                }
            }
            // Favorite heart, bottom right on hover, as on posters
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    let fav = emby.isPersonFav(p.Id)
                    ItemActionsButton.circle(fav ? "heart.fill" : "heart", on: fav,
                                             help: fav ? "Remove from Favorites" : "Add to Favorites") {
                        Task { await emby.setFav(p.Id, !fav, name: p.Name) }
                    }.padding(big ? 8 : 0)
                }
            }
            .scrollHover($hover)
            .hoverLift()   // grows a little under the pointer, like posters
            if classic {
                Text(p.Name).cvFont(big ? 13 : Glass3DTokens.Text.meta, weight: .semibold).lineLimit(1)
                Text(p.Role ?? p.`Type` ?? "").cvFont(big ? 11 : 10).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
            } else {
                Text(p.Name).coveFont(size: big ? 12 : 10, weight: .semibold).lineLimit(1)
                Text(p.Role ?? p.`Type` ?? "").coveFont(size: 10).foregroundColor(.secondary).lineLimit(1)
            }
        }.frame(width: CastTile.width(castSize)).multilineTextAlignment(.center)
    }
    /// Tile width for "normal" or "large" (the Cast & Crew row spaces its tiles by this)
    static func width(_ size: String) -> CGFloat { size == "large" ? 152 : 104 }
}

/// Lays children out left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 8

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var sz = v.sizeThatFits(.unspecified)
            if sz.width > width { sz = v.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + sz.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, sz))
            x += sz.width + hSpacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let r = rows(width, subviews)
        var h: CGFloat = 0, w: CGFloat = 0
        for row in r {
            var rowW: CGFloat = 0, rowH: CGFloat = 0
            for (_, sz) in row { rowW += sz.width; rowH = max(rowH, sz.height) }
            rowW += hSpacing * CGFloat(max(0, row.count - 1))
            w = max(w, rowW)
            h += rowH
        }
        h += vSpacing * CGFloat(max(0, r.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let h = row.map(\.1.height).max() ?? 0
            for (i, sz) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + hSpacing
            }
            y += h + vSpacing
        }
    }
}
