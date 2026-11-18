import SwiftUI

/// Glass3D segmented header tabs: the library header's "Movies | Collections | Genres | Favorites" glass pill,
/// shared with the Now Playing page ("Now Playing | Overview | History") so both look exactly the same.
/// Glossy Text3D labels, the selected one on the quieter selected glass, Glass3DTabHover plus the chosen hover
/// effect (SectionHoverGlow) on unselected tabs, inside one clear glass capsule.
struct Glass3DSegmentTabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text3D(text: titles[i], size: 12, weight: selection == i ? .bold : .semibold)
                        .padding(.horizontal, 14).frame(height: 32)
                        .classicSelectedGlass(selection == i)   // a step quieter than the top bar's pill
                        .modifier(Glass3DTabHover(on: selection == i))   // as the top bar's tabs
                        .modifier(SectionHoverGlow(on: !(selection == i)))   // accent glow on hover (Settings → Hover effect), as the top bar
                }.buttonStyle(.plainHand)
            }
        }.padding(3).frame(height: 38).classicClearGlass().opacity(0.92)   // interactive clear glass, as the top bar
    }
}
