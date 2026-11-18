import SwiftUI

/// Glass3D segmented header tabs: the library header's "Movies | Collections | Genres | Favorites" glass pill,
/// shared with the Now Playing page ("Now Playing | Overview | History") so both look exactly the same.
/// Glossy Text3D labels, the selected one on the quieter selected glass, Glass3DTabHover (no hover background
/// on unselected tabs), inside one clear glass capsule.
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
                }.buttonStyle(.plainHand)
            }
        }.padding(3).frame(height: 38).classicTabBarGlass().opacity(0.92)   // glass that doesn't react to the pointer (owner)
    }
}
