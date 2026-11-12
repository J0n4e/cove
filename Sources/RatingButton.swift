import SwiftUI

/// Your rating next to Play / Resume: ☆ until you rate, then "★ 9". Click it for 1–10 stars; ratings go to Trakt.
/// Hidden when the server has no IMDb, TMDB or TVDB id for the item (Trakt couldn't match it).
struct RatingButton: View {
    let item: Item
    let full: Full?
    /// Glass3D look (glass pill) instead of the Glass theme's round button.
    var classic = false
    @ObservedObject private var trakt = Trakt.shared
    @AppStorage("accent") private var accentName = "red"
    @State private var open = false

    var kind: String { item.isEpisode ? "episode" : "movie" }
    var ids: [String: String] { Trakt.ids(full?.ProviderIds) }

    var body: some View {
        if !ids.isEmpty && !item.isSeries && !item.isBox {
            let r = trakt.rating(kind: kind, ids: ids)
            let help = r.map { "Your rating: \($0)/10" } ?? "Rate"
            Button { open.toggle() } label: { label(r) }
                .buttonStyle(HoverButton()).helpLabel(help)
                .overlay(alignment: .topTrailing) { badge }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    RatingPicker(current: r, connected: trakt.isConnected, accent: Theme.accent(accentName)) { v in
                        open = false
                        Task { await trakt.rate(kind: kind, ids: ids, v) }
                    }
                }
                .task(id: item.id) { await trakt.refresh() }
        }
    }

    @ViewBuilder func label(_ r: Int?) -> some View {
        let star = Image(systemName: r == nil ? "star" : "star.fill")
        if classic {
            if let r { Label { Text("\(r)") } icon: { star }.classicGlassPill(size: 44, iconOnly: false) }
            else { Label("Rate", systemImage: "star").classicGlassPill(size: 44) }
        } else if let r {
            HStack(spacing: 5) { star.foregroundColor(Theme.accent(accentName)); Text("\(r)") }
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 16).frame(height: 46)
                .background(.ultraThinMaterial, in: Capsule())
        } else {
            star.font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
    }

    /// A small dot while the rating hasn't reached Trakt yet.
    @ViewBuilder var badge: some View {
        if trakt.isConnected && trakt.isPending(kind: kind, ids: ids) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 13)).foregroundColor(.orange)
                .background(Circle().fill(.black))
                .offset(x: 3, y: -3)
                .help(trakt.lastError ?? "Waiting to be sent to Trakt")
        }
    }
}

/// The popover: ten stars (hover to preview), the number, and Clear.
struct RatingPicker: View {
    let current: Int?
    let connected: Bool
    let accent: Color
    let pick: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        let shown = hover ?? current ?? 0
        VStack(spacing: 10) {
            Text(shown > 0 ? "\(shown)/10" : "Your rating").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 2) {
                ForEach(1...10, id: \.self) { n in
                    Button { pick(n) } label: {
                        Image(systemName: n <= shown ? "star.fill" : "star")
                            .font(.system(size: 20)).foregroundColor(n <= shown ? accent : .secondary)
                            .frame(width: 26, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHand).accessibilityLabel("\(n) out of 10")
                    .onHover { if $0 { hover = n } else if hover == n { hover = nil } }
                }
            }
            if current != nil { Button("Clear Rating") { pick(0) }.buttonStyle(.plainHand).foregroundColor(.secondary) }
            if !connected {
                Text("Saved on this Mac. Connect Trakt in Settings → Connect to sync it.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 270)
            }
        }
        .padding(14)
    }
}
