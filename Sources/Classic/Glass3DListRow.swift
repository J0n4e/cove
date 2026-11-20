import SwiftUI

/// A Glass3D library row in the List layout (v1.18.6): as the shared ListRow, but with the posters' ♡ ★ ✓ badges
/// at its end, always shown and the same on hover (no hover buttons, no green watched badge).
struct Glass3DListRow: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false
    var body: some View {
        let played = emby.isPlayed(item)
        NavigationLink(value: item) {
            HStack(alignment: .top, spacing: 16) {
                CachedImage(url: emby.image(item.posterId, width: 160)) { p in
                    p.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(white: 0.15) }
                .frame(width: 60, height: 90).clipped().cornerRadius(4)
                .watchedDim(played)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.Name).coveFont(size: 13, weight: .bold).lineLimit(1)
                    if let y = item.ProductionYear { Text(String(y)).coveFont(size: 11).foregroundColor(.secondary) }
                    Text(item.Overview ?? "").coveFont(size: 10).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                PosterBadgesInline(item: item)
            }
            .padding(8)
            .background(Color.white.opacity(hover ? 0.08 : 0.03)).cornerRadius(6)
            .contentShape(Rectangle())
            .scrollHover($hover)
        }.buttonStyle(.plainHand)
    }
}
