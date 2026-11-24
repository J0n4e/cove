import SwiftUI

// UI polish round 4: the shared micro-interactions, built only from existing tokens.
// - press: brightness −0.08 plus a soft inner shade, on Motion.fast; never a scale (size never changes)
// - specular top edge: the elevation recipe's 1 pt light edge, for any surface of level ≥ 2
// - ♡ / ✓ symbol swap: `.contentTransition(.symbolEffect(.replace))`
// - keyboard focus: a subtle accent ring, only where the focus effect is enabled (dialogs keep none)
// - skeleton → content: a crossfade on Motion.standard

extension Glass3DTokens {
    enum Press {
        /// Brightness of a pressed control (darker; hover brightening is separate)
        static let brightness = -0.08
        /// The soft inner shade along the inside edge while pressed
        static let shadeOpacity = 0.28
        static let shadeWidth: CGFloat = 3
        static let shadeBlur: CGFloat = 2
        /// Press feedback has no scale: any pressed scale is 1
        static let scale: CGFloat = 1
        static let animation: Animation = Glass3DTokens.Motion.fast
    }

    /// The 1 pt light edge along the top of raised surfaces.
    enum Specular {
        static let lineWidth: CGFloat = 1
        /// Surfaces from this elevation level up get the edge
        static let minLevel = 2
        /// The edge's opacity at `level` (the elevation token's highlight), 0 below `minLevel`.
        static func opacity(level: Int) -> Double {
            level >= minLevel ? Glass3DTokens.elevation(level).highlight : 0
        }
    }

    /// The keyboard focus ring (Full Keyboard Access / Tab): a thin accent line with a soft glow.
    enum FocusRing {
        static let lineWidth: CGFloat = 1.5
        static let opacity = 0.7
        static let glowOpacity = 0.35
        static let glowBlur: CGFloat = 3
        static let animation: Animation = Glass3DTokens.Motion.fast
    }

    /// Skeleton / empty state ↔ content.
    enum Crossfade {
        static let animation: Animation = Glass3DTokens.Motion.standard
    }
}

// MARK: Press

/// Darkens the control a little and lays a soft inner shade along `shape`'s inside edge while pressed.
struct PressFeedback<S: Shape>: ViewModifier {
    let pressed: Bool
    let shape: S
    /// false: brightness only (bare labels / glyphs, where an edge shade would draw a ring)
    var shade = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .brightness(pressed ? Glass3DTokens.Press.brightness : 0)
            .overlay {
                if shade {
                    shape.stroke(Color.black.opacity(pressed ? Glass3DTokens.Press.shadeOpacity : 0),
                                 lineWidth: Glass3DTokens.Press.shadeWidth)
                        .blur(radius: Glass3DTokens.Press.shadeBlur)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
            .animation(Glass3DTokens.Motion.resolved(Glass3DTokens.Press.animation, reduceMotion: reduceMotion),
                       value: pressed)
    }
}

// MARK: Specular top edge

/// The fine light edge at the top of a raised surface: white at the top fading to clear by the middle, at the
/// elevation token's highlight opacity. Draws nothing below level 2; never changes the content's size.
struct SpecularEdge<S: InsettableShape>: ViewModifier {
    let level: Int
    let shape: S
    func body(content: Content) -> some View {
        let o = Glass3DTokens.Specular.opacity(level: level)
        return content.overlay {
            if o > 0 {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(o), .clear],
                                                  startPoint: .top, endPoint: .center),
                                   lineWidth: Glass3DTokens.Specular.lineWidth)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: Keyboard focus ring

/// An accent ring around `shape` while `focused`, only where the focus effect is enabled (button rows in
/// dialogs call `.focusEffectDisabled()` and so keep no visible ring).
struct FocusGlow<S: Shape>: ViewModifier {
    let focused: Bool
    let shape: S
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.isFocusEffectEnabled) private var effectEnabled

    static func shows(focused: Bool, effectEnabled: Bool) -> Bool { focused && effectEnabled }

    func body(content: Content) -> some View {
        let on = Self.shows(focused: focused, effectEnabled: effectEnabled)
        let accent = Theme.accent(accentName)
        return content
            .overlay {
                ZStack {
                    shape.stroke(accent.opacity(on ? Glass3DTokens.FocusRing.glowOpacity : 0),
                                 lineWidth: Glass3DTokens.FocusRing.lineWidth * 2)
                        .blur(radius: Glass3DTokens.FocusRing.glowBlur)
                    shape.stroke(accent.opacity(on ? Glass3DTokens.FocusRing.opacity : 0),
                                 lineWidth: Glass3DTokens.FocusRing.lineWidth)
                }
                .allowsHitTesting(false)
            }
            .animation(Glass3DTokens.FocusRing.animation, value: on)
    }
}

/// A text field that shows the accent focus ring around `shape` while it has keyboard focus.
struct FocusGlowField<S: Shape>: ViewModifier {
    let shape: S
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).modifier(FocusGlow(focused: focused, shape: shape))
    }
}

// MARK: Symbol swap

enum SymbolSwap {
    /// The ♡ / ✓ toggles swap their SF Symbol with the replace effect (macOS 14+, the deployment target).
    static let usesReplaceEffect = true
}

extension View {
    func pressFeedback<S: Shape>(_ pressed: Bool, in shape: S, shade: Bool = true) -> some View {
        modifier(PressFeedback(pressed: pressed, shape: shape, shade: shade))
    }

    /// The 1 pt specular top edge of an elevation-`level` surface in `shape` (nothing below level 2).
    func specularEdge<S: InsettableShape>(level: Int, in shape: S) -> some View {
        modifier(SpecularEdge(level: level, shape: shape))
    }

    func focusGlow<S: Shape>(_ focused: Bool, in shape: S) -> some View {
        modifier(FocusGlow(focused: focused, shape: shape))
    }

    /// For a text field: tracks its own keyboard focus and rings `shape` in the accent while focused.
    func focusGlowField<S: Shape>(in shape: S) -> some View { modifier(FocusGlowField(shape: shape)) }

    /// A ♡ / ✓ symbol that swaps with the replace effect when its name changes (badge size unchanged).
    func symbolSwap() -> some View { contentTransition(.symbolEffect(.replace)) }

    /// Skeleton / empty state ↔ content: crossfade on Motion.standard. Put it on the
    /// placeholder; the content it gives way to fades in with the same transaction.
    func skeletonCrossfade() -> some View { transition(.opacity.animation(Glass3DTokens.Crossfade.animation)) }
}
