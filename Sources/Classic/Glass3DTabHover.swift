import SwiftUI
import AppKit

/// Glass3D tab look and hover (top bar sections, library header tabs).
/// Unselected: no background; brighter text with a soft dark shadow so it reads over bright posters. Under the
/// pointer the label goes full white and a light glass sheen appears. Selected: hover only adds the sheen.
/// Pressed: 0.97. No scaling with Reduce Motion. Apply it to the label after its own selected glass.
struct Glass3DTabHover: ViewModifier {
    let on: Bool
    @State private var hover = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content
            .opacity(Glass3DTabHover.labelOpacity(on: on, hover: hover))
            // No background on unselected tabs (owner): a soft dark shadow keeps the text readable over posters
            .shadow(color: .black.opacity(on ? 0 : 0.9), radius: 1.5, x: 0, y: 0.5)
            .shadow(color: .black.opacity(on ? 0 : 0.6), radius: 5, x: 0, y: 0)
            .scaleEffect(reduce ? 1 : Glass3DTabHover.scale(on: on, hover: hover, pressed: pressed))
            .onHover { h in withAnimation(Glass3DTabHover.spring) { hover = h } }
            // No press gesture here: a DragGesture on the label competed with the tab's own click and
            // swallowed some clicks (owner: top bar items didn't always respond)
    }

    /// A soft spring on the Glass3D fast speed (0.15 s).
    static let spring = Animation.spring(response: 0.15 * 2, dampingFraction: 0.75)

    /// Dark fill of an unselected tab: 0.30 at rest, 0.45 under the pointer.
    static func fill(hover: Bool) -> Double { hover ? 0.45 : 0.30 }
    /// Label: full white when selected or hovered, secondary otherwise.
    static func labelOpacity(on: Bool, hover: Bool) -> Double { 1 }
    /// Pressed 0.97; an unselected tab under the pointer 1.03; otherwise 1.
    static func scale(on: Bool, hover: Bool, pressed: Bool) -> CGFloat {
        if pressed { return 0.97 }
        return 1
    }
}

/// The hover sheen: a light top highlight and a faint inner stroke.
private struct Glass3DTabSheen: View {
    var body: some View {
        Capsule().fill(LinearGradient(stops: [.init(color: .white.opacity(0.14), location: 0),
                                              .init(color: .clear, location: 0.5)],
                                      startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .padding(0.75))
    }
}
