import SwiftUI

// The ONE hover / press effect every glass pill and button shares (GlassButtonStyle text / icon / lift kinds,
// HoverButton, ClassicGlassPillStyle, the top bar items and the segment tabs). Chosen in
// Settings → Appearance → Pill hover. It only draws on top of each pill's own look: nothing changes at rest, the
// layout never moves (scale is visual only) and the hit area stays the caller's contentShape.

/// Settings → Appearance → Pill hover → Hover effect (key "pillHover").
enum PillHoverStyle: String, CaseIterable {
    case edge, sweep, glow, lift, none

    static let key = "pillHover"
    static let softPressKey = "pillSoftPress"
    static let defaultValue: PillHoverStyle = .edge
    static let defaultSoftPress = true

    /// Unknown or empty stored values fall back to the default.
    static func resolve(_ raw: String) -> PillHoverStyle { PillHoverStyle(rawValue: raw) ?? defaultValue }

    var title: String {
        switch self {
        case .edge: return "Accent edge"
        case .sweep: return "Light sweep"
        case .glow: return "Glow"
        case .lift: return "Lift"
        case .none: return "None"
        }
    }
    static var options: [(String, String)] { allCases.map { ($0.rawValue, $0.title) } }

    /// The pill's visual scale: soft press while pressed, the lift under the pointer, 1 otherwise and always 1
    /// with Reduce Motion.
    static func scale(_ s: PillHoverStyle, hover: Bool, pressed: Bool, softPress: Bool, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return 1 }
        if pressed && softPress { return Glass3DTokens.PillFX.pressScale }
        if hover && s == .lift { return Glass3DTokens.PillFX.liftScale }
        return 1
    }
    /// Whether the light sweep runs (never with Reduce Motion).
    static func sweeps(_ s: PillHoverStyle, reduceMotion: Bool) -> Bool { s == .sweep && !reduceMotion }
    /// Edge / glow are light only, so they stay with Reduce Motion (just without the fade).
    static func drawsEdge(_ s: PillHoverStyle, hover: Bool) -> Bool { s == .edge && hover }
    static func drawsGlow(_ s: PillHoverStyle, hover: Bool) -> Bool { s == .glow && hover }
}

/// Set by an inner pill that already draws the effect, so an outer button style wrapping it (HoverButton around a
/// classicGlassPill label) adds only the press and not a second edge / sweep / glow.
struct PillHoverClaimedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct PillHoverEffect<S: InsettableShape>: ViewModifier {
    let hover: Bool
    let pressed: Bool
    let shape: S
    @AppStorage(PillHoverStyle.key) private var raw = PillHoverStyle.defaultValue.rawValue
    @AppStorage(PillHoverStyle.softPressKey) private var softPress = PillHoverStyle.defaultSoftPress
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An inner pill draws the hover look already
    @State private var claimed = false
    /// Sweep position: −1 (off the leading edge) … 1 (past the trailing edge)
    @State private var sweep: CGFloat = -1

    func body(content: Content) -> some View {
        let fx = Glass3DTokens.PillFX.self
        let style = claimed ? PillHoverStyle.none : PillHoverStyle.resolve(raw)
        let accent = Theme.accent(accentName)
        let scale = PillHoverStyle.scale(claimed ? .none : style, hover: hover, pressed: pressed,
                                         softPress: softPress, reduceMotion: reduceMotion)
        let fade = Glass3DTokens.Motion.resolved(Glass3DTokens.Motion.fast, reduceMotion: reduceMotion)
        return content
            .onPreferenceChange(PillHoverClaimedKey.self) { claimed = $0 }
            .overlay {
                if style == .edge {
                    shape.inset(by: fx.edgeInset)
                        .strokeBorder(accent.opacity(fx.edgeOpacity), lineWidth: fx.edgeWidth)
                        .opacity(PillHoverStyle.drawsEdge(style, hover: hover) ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if style == .sweep {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(fx.sweepOpacity), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .frame(width: g.size.width * fx.sweepBand, height: g.size.height)
                            .offset(x: sweep * g.size.width)
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
            .modifier(PillGlow(on: PillHoverStyle.drawsGlow(style, hover: hover), active: style == .glow, accent: accent))
            .modifier(PillLiftShadow(on: hover && style == .lift && !reduceMotion, active: style == .lift))
            .animation(fade, value: hover)
            .scaleEffect(scale)
            .animation(Glass3DTokens.Motion.resolved(Glass3DTokens.Motion.spring, reduceMotion: reduceMotion), value: scale)
            .onChange(of: hover) { _, h in
                guard h, PillHoverStyle.sweeps(style, reduceMotion: reduceMotion) else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { sweep = -1 }
                DispatchQueue.main.async { withAnimation(fx.sweepAnimation) { sweep = 1 } }
            }
            .preference(key: PillHoverClaimedKey.self, value: true)
    }
}

/// Soft accent glow around the pill; only attached when Glow is the chosen effect.
private struct PillGlow: ViewModifier {
    let on: Bool
    let active: Bool
    let accent: Color
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.shadow(color: accent.opacity(on ? Glass3DTokens.PillFX.glowOpacity : 0), radius: Glass3DTokens.PillFX.glowRadius)
        } else {
            content
        }
    }
}

/// The lift's slightly deeper shadow; only attached when Lift is the chosen effect.
private struct PillLiftShadow: ViewModifier {
    let on: Bool
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            let s = Glass3DTokens.PillFX.liftShadow
            content.g3Shadow(Glass3DTokens.Shadow(radius: s.radius, y: s.y, opacity: on ? s.opacity : 0))
        } else {
            content
        }
    }
}

extension View {
    /// The shared pill hover / press effect (Settings → Appearance → Pill hover).
    func pillHoverEffect<S: InsettableShape>(hover: Bool, pressed: Bool = false, in shape: S) -> some View {
        modifier(PillHoverEffect(hover: hover, pressed: pressed, shape: shape))
    }
}

/// Settings preview: a sample pill and a sample button with the current choice.
struct PillHoverPreview: View {
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            Button {} label: { Label("Play", systemImage: "play.fill") }.buttonStyle(GlassButtonStyle(.secondary))
            Button {} label: { Label("Sample", systemImage: "sparkles").classicPill() }.buttonStyle(HoverButton())
        }
    }
}
