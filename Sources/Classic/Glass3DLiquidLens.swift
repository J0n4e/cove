import SwiftUI
import AppKit

/// Settings → General → Hover effect (key "classicHover"). The stored value "glass" (once "Glass pill") now means
/// the Liquid lens, so a saved choice carries over.
enum HoverStyle {
    static let options: [(String, String)] = [("fog", "Fogged mirror"), ("glow", "Soft glow"), ("glass", "Liquid lens"),
                                              ("slide", "Sliding light"), ("spot", "Spotlight"), ("underline", "Underline glow"),
                                              ("frost", "Frosted rise"), ("pulse", "Colour pulse")]
    /// A known value as it is; anything else (missing, old or mistyped) is the default, "fog".
    static func normalized(_ raw: String?) -> String {
        guard let raw, options.contains(where: { $0.0 == raw }) else { return "fog" }
        return raw
    }
    /// The Liquid lens grows from 0.9 to 1 as it appears; with Reduce Motion it only fades.
    static func lensScale(shown: Bool, reduceMotion: Bool) -> CGFloat { shown || reduceMotion ? 1 : 0.9 }
}

/// Liquid lens: a real Liquid Glass capsule (macOS 26+; ultra-thin material before) with a thin bright top edge and
/// a faint accent glow low down. Lighter and more see-through than the selected tab's pill; it fades (the caller's
/// opacity) and scales in with a soft spring. Only drawn behind the label: the label itself never scales.
struct Glass3DLiquidLens: View {
    var shown = true
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ZStack {
            Capsule().fill(Color.black.opacity(0.10))   // just enough to keep white bold text readable
            Glass3DLensGlass()
            Capsule().fill(RadialGradient(colors: [accent.opacity(0.10), accent.opacity(0)],
                                          center: .bottom, startRadius: 0, endRadius: 44))
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .environment(\.colorScheme, .dark)
        .scaleEffect(HoverStyle.lensScale(shown: shown, reduceMotion: reduce))
        .animation(Glass3DTabHover.spring, value: shown)
        .allowsHitTesting(false)
    }
}

/// The lens's glass: Apple's clear Liquid Glass on macOS 26+, ultra-thin material on 14/15.
private struct Glass3DLensGlass: View {
    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear, in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial).opacity(0.85)
        }
    }
}
