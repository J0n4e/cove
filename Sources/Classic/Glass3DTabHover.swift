import SwiftUI
import AppKit

/// Glass3D tab look and hover (top bar sections, library header tabs).
/// Unselected: a dark pill a step lighter than the selected one, so it reads over bright posters. Under the pointer
/// it fades stronger (towards the selected look, not equal), a light glass sheen appears, the label goes from
/// secondary to full white and the tab grows slightly (1.03) on a soft spring. Selected: hover only adds the sheen.
/// Pressed: 0.97. No scaling with Reduce Motion. Apply it to the label after its own selected glass.
struct Glass3DTabHover: ViewModifier {
    let on: Bool
    @State private var hover = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content
            .opacity(Glass3DTabHover.labelOpacity(on: on, hover: hover))
            .background {
                if !on {
                    Capsule().fill(Color.black.opacity(Glass3DTabHover.fill(hover: hover)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.75))
                        .allowsHitTesting(false)
                }
            }
            .overlay { Glass3DTabSheen().opacity(hover ? 1 : 0).allowsHitTesting(false) }
            .scaleEffect(reduce ? 1 : Glass3DTabHover.scale(on: on, hover: hover, pressed: pressed))
            .onHover { h in withAnimation(Glass3DTabHover.spring) { hover = h } }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(Glass3DTabHover.spring) { pressed = true } } }
                .onEnded { _ in withAnimation(Glass3DTabHover.spring) { pressed = false } })
    }

    /// A soft spring on the Glass3D fast speed (0.15 s).
    static let spring = Animation.spring(response: 0.15 * 2, dampingFraction: 0.75)

    /// Dark fill of an unselected tab: 0.30 at rest, 0.45 under the pointer.
    static func fill(hover: Bool) -> Double { hover ? 0.45 : 0.30 }
    /// Label: full white when selected or hovered, secondary otherwise.
    static func labelOpacity(on: Bool, hover: Bool) -> Double { on || hover ? 1 : 0.6 }
    /// Pressed 0.97; an unselected tab under the pointer 1.03; otherwise 1.
    static func scale(on: Bool, hover: Bool, pressed: Bool) -> CGFloat {
        if pressed { return 0.97 }
        return hover && !on ? 1.03 : 1
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
