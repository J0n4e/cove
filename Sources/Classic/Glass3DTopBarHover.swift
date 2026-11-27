import SwiftUI
import AppKit

// The five newer Hover effect looks (Settings → Appearance → Hover effect): Sliding light, Spotlight, Underline glow,
// Frosted rise and Colour pulse. Fogged mirror, Soft glow and Liquid lens live in ClassicPill.swift / Glass3DLiquidLens.

extension HoverStyle {
    /// Sliding light: one shared highlight in the top bar instead of one per section.
    static func slides(_ style: String) -> Bool { normalized(style) == "slide" }
    /// Spotlight: where the light sits (unit point). Reduce Motion or no pointer: the centre.
    static func spotCentre(_ location: CGPoint?, in size: CGSize, reduceMotion: Bool) -> UnitPoint {
        guard !reduceMotion, let location, size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(x: min(1, max(0, location.x / size.width)), y: min(1, max(0, location.y / size.height)))
    }
    /// Frosted rise: lifts a little while shown; with Reduce Motion it only fades.
    static func riseScale(shown: Bool, reduceMotion: Bool) -> CGFloat {
        shown && !reduceMotion ? Glass3DTokens.TopBarHover.riseScale : 1
    }
    /// Colour pulse: extra brightness at the peak (0 with Reduce Motion: a plain fade).
    static func pulseBrightness(peak: Bool, reduceMotion: Bool) -> Double {
        peak && !reduceMotion ? Glass3DTokens.TopBarHover.pulsePeak : 0
    }
    /// Underline glow: the line's share of the label width (grows in; Reduce Motion: full width, fade only).
    static func underlineWidth(shown: Bool, reduceMotion: Bool) -> CGFloat {
        shown || reduceMotion ? Glass3DTokens.TopBarHover.underlineWidth : 0
    }
}

/// The Sliding light's shared state in one top bar: which section is under the pointer, and the namespace the
/// highlight glides in.
final class TopBarSlideState: ObservableObject {
    @Published var id: String?
    func hover(_ id: String, _ on: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if on {
            withAnimation(reduce ? Glass3DTokens.Motion.fast : Glass3DTokens.TopBarHover.slide) { self.id = id }
        } else {
            // Left the section: clear only if no other section took it meanwhile (moving along the bar glides)
            DispatchQueue.main.asyncAfter(deadline: .now() + Glass3DTokens.TopBarHover.slideLeaveDelay) {
                guard self.id == id else { return }
                withAnimation(Glass3DTokens.Motion.fast) { self.id = nil }
            }
        }
    }
}

struct TopBarSlide {
    let ns: Namespace.ID
    let state: TopBarSlideState
}

private struct TopBarSlideKey: EnvironmentKey { static let defaultValue: TopBarSlide? = nil }
extension EnvironmentValues {
    /// Set by the classic top bar: sections there share one Sliding light.
    var topBarSlide: TopBarSlide? {
        get { self[TopBarSlideKey.self] }
        set { self[TopBarSlideKey.self] = newValue }
    }
}

/// Sliding light's fill: a soft accent capsule (also its plain-fade look outside the top bar).
struct SlidingLight: View {
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let a = Theme.accent(accentName)
        Capsule().fill(a.opacity(Glass3DTokens.TopBarHover.slideFill))
            .overlay(Capsule().strokeBorder(a.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
            .allowsHitTesting(false)
    }
}

/// One section's place in the Sliding light: draws the shared highlight while it is the hovered one.
struct TopBarSlideHighlight: View {
    let id: String
    let slide: TopBarSlide
    @ObservedObject var state: TopBarSlideState
    var body: some View {
        ZStack {
            if state.id == id {
                SlidingLight()
                    .matchedGeometryEffect(id: "topBarHover", in: slide.ns)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Spotlight: a soft radial accent light at the pointer, clipped to the capsule.
struct HoverSpotlight: View {
    var location: CGPoint?
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let a = Theme.accent(accentName)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        GeometryReader { g in
            ZStack {
                Capsule().fill(a.opacity(Glass3DTokens.TopBarHover.spotBase))
                Capsule().fill(RadialGradient(colors: [a.opacity(Glass3DTokens.TopBarHover.spotOpacity), a.opacity(0)],
                                              center: HoverStyle.spotCentre(location, in: g.size, reduceMotion: reduce),
                                              startRadius: 0, endRadius: Glass3DTokens.TopBarHover.spotRadius))
            }
            .clipShape(Capsule())
        }
        .allowsHitTesting(false)
    }
}

/// Underline glow: no fill, a short glowing accent line under the label that grows in.
struct HoverUnderline: View {
    var shown = true
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let a = Theme.accent(accentName)
        let t = Glass3DTokens.TopBarHover.self
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        GeometryReader { g in
            Capsule().fill(a)
                .frame(width: g.size.width * HoverStyle.underlineWidth(shown: shown, reduceMotion: reduce),
                       height: t.underlineHeight)
                .modifier(AccentGlowShadow(color: a.opacity(t.underlineGlowOpacity), radius: t.underlineGlow))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, t.underlineInset)
        }
        .animation(Glass3DTokens.Motion.resolved(Glass3DTokens.Motion.standard, reduceMotion: reduce), value: shown)
        .allowsHitTesting(false)
    }
}

/// Frosted rise: bright frosted glass (material + white tint) that lifts a little with a soft shadow.
struct HoverFrostedRise: View {
    var shown = true
    var body: some View {
        let t = Glass3DTokens.TopBarHover.self
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ZStack {
            Capsule().fill(.regularMaterial)
            Capsule().fill(Color.white.opacity(t.frostTint))
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(t.frostStroke), .white.opacity(0)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .environment(\.colorScheme, .dark)
        .g3Shadow(t.riseShadow)
        .scaleEffect(HoverStyle.riseScale(shown: shown, reduceMotion: reduce))
        .animation(Glass3DTokens.Motion.resolved(Glass3DTokens.Motion.spring, reduceMotion: reduce), value: shown)
        .allowsHitTesting(false)
    }
}

/// Colour pulse: the accent fill fades in, brightens once (peak ~0.25 s) and settles. Once per hover, no loop.
struct HoverColourPulse: View {
    var shown = true
    @AppStorage("accent") private var accentName = "red"
    @State private var peak = false
    var body: some View {
        let a = Theme.accent(accentName)
        let t = Glass3DTokens.TopBarHover.self
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Capsule().fill(a.opacity(t.pulseFill))
            .brightness(HoverStyle.pulseBrightness(peak: peak, reduceMotion: reduce))
            .allowsHitTesting(false)
            .task(id: shown) {
                guard shown, !reduce else { peak = false; return }
                withAnimation(t.pulseUp) { peak = true }
                try? await Task.sleep(nanoseconds: UInt64(t.pulsePeakSeconds * 1_000_000_000))
                withAnimation(t.pulseSettle) { peak = false }
            }
    }
}

/// A soft coloured glow (the accent light of the underline); colour shadows have no elevation token.
private struct AccentGlowShadow: ViewModifier {
    let color: Color
    let radius: CGFloat
    func body(content: Content) -> some View { content.shadow(color: color, radius: radius) }
}
