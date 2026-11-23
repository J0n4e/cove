import SwiftUI

/// Glass3D segmented header tabs: the library header's "Movies | Collections | Genres | Favorites" glass pill,
/// shared with the Now Playing page ("Now Playing | Overview | History") so both look exactly the same.
/// Glossy Text3D labels, the selected one on the quieter selected glass, Glass3DTabHover plus the chosen hover
/// effect (SectionHoverGlow) on unselected tabs, inside one clear glass capsule.
struct Glass3DSegmentTabs: View {
    let titles: [String]
    @Binding var selection: Int
    /// Dock-style red badges by tab index (e.g. unread notifications)
    var badges: [Int: String] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text3D(text: titles[i], size: 12, weight: selection == i ? .bold : .semibold)
                        .padding(.horizontal, 14).frame(height: 32)
                        .classicSelectedGlass(selection == i)   // a step quieter than the top bar's pill
                        .modifier(Glass3DTabHover(on: selection == i))   // as the top bar's tabs
                        .modifier(SectionHoverGlow(on: !(selection == i)))   // accent glow on hover (Settings → Hover effect), as the top bar
                        // the count sits on the tab's top-right corner, like the Activity dot in the top bar (owner)
                        .overlay(alignment: .topTrailing) {
                            if let b = badges[i] { DockBadge(text: b, small: true).offset(x: 4, y: -5).allowsHitTesting(false) }
                        }
                }.buttonStyle(.plainHand)
            }
        }.padding(3).frame(height: 38).classicClearGlass().opacity(0.92)   // interactive clear glass, as the top bar
    }
}

/// A red capsule with a white number, like the badges on Dock icons.
struct DockBadge: View {
    let text: String
    var small = false
    var body: some View {
        let d: CGFloat = small ? 15 : 17
        Text(text).font(.system(size: small ? 9 : 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(.white)
            .padding(.horizontal, text.count > 1 ? 4 : 0).frame(minWidth: d, minHeight: d)
            .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.19)))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .fixedSize()
    }
}
