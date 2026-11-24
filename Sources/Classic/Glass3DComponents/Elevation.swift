import SwiftUI

/// One surface recipe per elevation level (`Glass3DTokens.elevation`): fill, outline, a specular top edge and the
/// level's shadow, drawn behind / over the content in the given rounded shape. Doesn't change the content's size.
struct Elevation: ViewModifier {
    let level: Int
    var radius: CGFloat = Glass3DTokens.Radius.card
    @AppStorage("bg") private var bgName = "black"

    func body(content: Content) -> some View {
        let r = Glass3DTokens.elevation(level)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let shadow = r.shadow ?? Glass3DTokens.Shadow(radius: 0, y: 0, opacity: 0)
        return content
            .background {
                if level > 0 {
                    ZStack {
                        if r.backgroundFill > 0 { shape.fill(Theme.bg(bgName).opacity(r.backgroundFill)) }
                        shape.fill(Color.white.opacity(r.fill))
                    }
                    .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
                }
            }
            .overlay {
                if level > 0 {
                    ZStack {
                        shape.strokeBorder(Color.white.opacity(r.stroke), lineWidth: 0.75)
                        // specular top edge, fading out towards the middle (level 1's own faint edge stays)
                        if level < Glass3DTokens.Specular.minLevel {
                            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(r.highlight), .clear],
                                                              startPoint: .top, endPoint: .center), lineWidth: 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .specularEdge(level: level, in: shape)   // the shared 1 pt top edge of level 2+ surfaces
    }
}

extension View {
    /// The level 0–4 surface (`Glass3DTokens.elevation`) in a rounded shape of `radius`.
    func elevation(_ level: Int, radius: CGFloat = Glass3DTokens.Radius.card) -> some View {
        modifier(Elevation(level: level, radius: radius))
    }

    /// `animation` unless Reduce Motion is on (then the change is instant).
    func g3Animation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReduceMotionAnimation(animation: animation, value: value))
    }
}

private struct ReduceMotionAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(Glass3DTokens.Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}
