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
            if let r { Label { Text("Your rating: \(r)") } icon: { starred(r) }.classicGlassPill(size: size - 2) }
            else { Label("Rate", systemImage: "star").classicGlassPill(size: size - 2) }
        } else if let r {
            starred(r)
                .frame(width: size, height: size).background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        } else {
            star.font(font)
                .frame(width: size, height: size).background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
    }

    func starred(_ r: Int) -> some View { RatedStar(rating: r, width: size - (classic ? 2 : 0)) }

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

/// The rating on a big white star, the number white with a black outline. `width`: the round button or badge
/// it sits in; `fill`: how much of it the star takes.
struct RatedStar: View {
    let rating: Int
    let width: CGFloat
    var fill: CGFloat = 0.8
    /// Drawn straight on a picture (posters): a glossy star in the accent color with a thin black outline,
    /// instead of a white star in a bubble.
    var outlined = false
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let w = width
        // The number takes the same share of the star at every size (readable on a poster badge too), with a
        // thin outline that grows a little with the size
        // "10" condensed, so two digits can be as tall as one
        let number = Text("\(rating)").font(.system(size: w * fill * 0.46, weight: .heavy).width(rating == 10 ? .condensed : .standard))
        let line = max(0.6, w * 0.018)
        ZStack {
            // A star's body sits below the middle of its outline box (the top point sticks up): raised so the
            // body is in the middle of the button, where the number goes
            let star = Image(systemName: "star.fill").font(.system(size: w * fill))
            Group {
                if outlined {
                    ZStack {
                        ForEach(0..<8, id: \.self) { i in
                            let a = Double(i) * .pi / 4
                            star.foregroundColor(.black.opacity(0.85)).offset(x: cos(a) * 0.9, y: sin(a) * 0.9)
                        }
                        Glossy(symbol: star, color: Theme.accent(accentName))
                    }
                } else {
                    star.foregroundColor(.white)
                }
            }
            .offset(y: -w * fill * 0.06)
            // Black outline: the number drawn in black around itself, then in white on top
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                number.foregroundColor(.black).offset(x: cos(a) * line, y: sin(a) * line)
            }
            number.foregroundColor(.white)
        }
    }
}

/// A filled symbol with a little 3D: the color lit from above (a shine on top, shade at the bottom) and a soft
/// drop shadow. For the poster heart and rating star.
struct Glossy<Symbol: View>: View {
    let symbol: Symbol
    let color: Color
    var body: some View {
        ZStack {
            symbol.foregroundStyle(color)
            symbol.foregroundStyle(LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                          .init(color: .white.opacity(0.1), location: 0.45),
                                                          .init(color: .black.opacity(0.35), location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
        }
        .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1.5)
    }
}

/// The favorite heart everywhere (posters, cast, cards, favorite buttons): glossy, in the accent color.
struct FavHeart: View {
    var size: CGFloat = 14
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        Glossy(symbol: Image(systemName: "heart.fill").font(.system(size: size)), color: Theme.accent(accentName))
    }
}

/// Watched (Glass3D posters and seasons): a glossy white check-circle with a thin black outline, the size of
/// the heart and rating star.
struct GlossyCheck: View {
    var size: CGFloat = 23
    var body: some View {
        let mark = Image(systemName: "checkmark.circle.fill").font(.system(size: size, weight: .semibold))
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                mark.foregroundColor(.black.opacity(0.85)).offset(x: cos(a) * 0.9, y: sin(a) * 0.9)
            }
            // Check cut out of a white disc: the poster shows through it, so the check reads on any picture
            Glossy(symbol: mark, color: .white)
        }
    }
}

/// Unwatched episodes (Glass3D posters): the count in a glossy white capsule, matching GlossyCheck.
struct GlossyCount: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .heavy)).foregroundColor(.black)
            .padding(.horizontal, 7).frame(minWidth: 23, minHeight: 23)
            .background {
                ZStack {
                    Capsule().fill(Color.white)
                    Capsule().fill(LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                          .init(color: .white.opacity(0.1), location: 0.45),
                                                          .init(color: .black.opacity(0.3), location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
                }
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.85), lineWidth: 0.9))
                .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1.5)
            }
    }
}

/// Your Trakt rating on a poster (the number on a glossy accent star), next to the favorite heart; nothing when
/// it isn't rated.
struct MyRatingBadge: View {
    let item: Item
    @ObservedObject private var trakt = Trakt.shared
    var body: some View {
        if let r = trakt.rating(item) {
            let d: CGFloat = 28
            RatedStar(rating: r, width: d, fill: 0.92, outlined: true).frame(width: d, height: d)
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
