import SwiftUI

/// Your rating next to Play / Resume: ☆ until you rate, then "★ 9". Click it for 1–10 stars; ratings go to Trakt.
/// Hidden when the server has no IMDb, TMDB or TVDB id for the item (Trakt couldn't match it).
struct RatingButton: View {
    let item: Item
    let full: Full?
    /// Glass3D look (glass pill) instead of the Glass theme's round button.
    var classic = false
    /// Button height: 46 on the detail page, smaller on the hover preview card.
    var size: CGFloat = 46
    @ObservedObject private var trakt = Trakt.shared
    @AppStorage("accent") private var accentName = "red"
    @State private var open = false
    /// The star picker is open: the hover preview card stays open meanwhile (the picker sits outside it).
    @MainActor static var pickerOpen = false

    var kind: String { Trakt.kind(item) ?? "movie" }
    var ids: [String: String] { Trakt.ids(full?.ProviderIds ?? item.ProviderIds) }

    var body: some View {
        if !ids.isEmpty && Trakt.kind(item) != nil {
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
                .onChange(of: open) { _, on in Self.pickerOpen = on }
                .onDisappear { if open { Self.pickerOpen = false } }
                .task(id: item.id) { await trakt.refresh() }
        }
    }

    @ViewBuilder func label(_ r: Int?) -> some View {
        let star = Image(systemName: r == nil ? "star" : "star.fill")
        let font = Font.system(size: size * 0.37, weight: .semibold)
        if classic {
            if let r { Label { Text("\(r)") } icon: { star }.classicGlassPill(size: size - 2, iconOnly: false) }
            else { Label("Rate", systemImage: "star").classicGlassPill(size: size - 2) }
        } else if let r {
            HStack(spacing: 5) { star.foregroundColor(Theme.accent(accentName)); Text("\(r)") }
                .font(font)
                .padding(.horizontal, size * 0.35).frame(height: size)
                .background(.ultraThinMaterial, in: Capsule())
        } else {
            star.font(font)
                .frame(width: size, height: size).background(.ultraThinMaterial, in: Circle())
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

/// Your Trakt rating on a poster ("★ 9"), next to the favorite heart; nothing when it isn't rated.
struct MyRatingBadge: View {
    let item: Item
    @ObservedObject private var trakt = Trakt.shared
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.classicGlass) private var classic   // Glass3D: the same glass tube as the watched badge
    var body: some View {
        if let r = trakt.rating(item) {
            let label = HStack(spacing: 2) {
                Image(systemName: "star.fill").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.accent(accentName))
                Text("\(r)").font(.system(size: classic ? 12 : 11, weight: classic ? .bold : .heavy)).foregroundColor(.white)
            }
            .padding(.horizontal, classic ? 8 : 7).frame(height: 22)
            Group {
                if classic { label.glassTube() }
                else {
                    label.background(Capsule().fill(Color.black.opacity(0.7)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                }
            }
            .helpLabel("Your rating: \(r)/10")
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
