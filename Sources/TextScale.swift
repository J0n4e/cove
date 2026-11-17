import SwiftUI

// Text size (Settings → General → Text size, times the system text size where macOS passes one to the app).
// Every fixed-size font in the views goes through `.coveFont(size:...)` (Glass and shared windows) or
// `.cvFont(...)` (Classic, through `Font.cv`'s ClassicFont). At the default setting the factor is exactly 1.0, so
// every point size is the one written in the code.

enum TextScale {
    /// (setting value, name shown in Settings)
    static let choices: [(String, String)] = [
        ("smaller", "Smaller"), ("default", "Default"), ("larger", "Larger"), ("largest", "Largest"),
    ]
    static let range: ClosedRange<CGFloat> = 0.8...2.0

    /// The in-app choice as a factor; anything unknown is the default.
    static func inApp(_ value: String) -> CGFloat {
        switch value {
        case "smaller": return 0.9
        case "larger": return 1.15
        case "largest": return 1.3
        default: return 1.0
        }
    }

    /// The system text size as a factor; `.large` (the default) is 1.0.
    static func system(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.88
        case .small: return 0.94
        case .medium: return 0.97
        case .large: return 1.0
        case .xLarge: return 1.12
        case .xxLarge: return 1.24
        case .xxxLarge: return 1.36
        case .accessibility1: return 1.5
        case .accessibility2: return 1.6
        case .accessibility3: return 1.7
        case .accessibility4: return 1.75
        case .accessibility5: return 1.8
        @unknown default: return 1.0
        }
    }

    /// System × in-app, kept to a range where the layouts still hold.
    static func combined(system: CGFloat, inApp: CGFloat) -> CGFloat {
        min(max(system * inApp, range.lowerBound), range.upperBound)
    }

    /// A base point size at a factor. At 1.0 it's the base size itself, bit for bit.
    static func scaledSize(base: CGFloat, scale: CGFloat) -> CGFloat {
        scale == 1 ? base : (base * scale).rounded(.toNearestOrEven)
    }
}

/// Applies a font made at the current text size. Reads the setting and the system size itself, so it works in
/// every window and hosting view (Settings, About, Update, Trailer, AppKit-hosted rows) without injecting
/// anything at their roots, and re-renders as soon as the setting changes.
struct CoveScaledFont: ViewModifier {
    @AppStorage("textSize") private var textSize = "default"
    // Read here so every text re-renders as soon as the Font or Theme setting changes (before, only views that
    // happened to redraw, like Settings, picked up a new font)
    @AppStorage("classicFont") private var classicFont = "rounded"
    @AppStorage("theme") private var theme = "classic"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Scale, and whether the Glass3D font family applies (Glass3D theme)
    let make: (CGFloat, Bool) -> Font

    func body(content: Content) -> some View {
        let scale = TextScale.combined(system: TextScale.system(dynamicTypeSize), inApp: TextScale.inApp(textSize))
        content.font(make(scale, theme == "classic"))
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` that follows the text size; `adjust` for Font modifiers
    /// (`{ $0.monospacedDigit() }`).
    func coveFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                  _ adjust: @escaping (Font) -> Font = { $0 }) -> some View {
        // Glass3D: every text uses the chosen Font (Settings → General → Font), so shared windows (Settings, About,
        // Software Update, errors, pills) match the rest; monospaced/serif/rounded designs written in the code stay
        modifier(CoveScaledFont { scale, glass3D in
            let px = TextScale.scaledSize(base: size, scale: scale)
            return adjust(glass3D && design == .default ? ClassicFont.font(px, weight) : .system(size: px, weight: weight, design: design))
        })
    }

    /// `.font(.cv(size, weight:))` (the Classic font) that follows the text size.
    func cvFont(_ size: CGFloat, weight: Font.Weight = .regular, _ adjust: @escaping (Font) -> Font = { $0 }) -> some View {
        modifier(CoveScaledFont { scale, _ in adjust(.cv(TextScale.scaledSize(base: size, scale: scale), weight: weight)) })
    }

    /// Any font built from the current factor (for the few places that pick between two fonts).
    func coveFont(_ make: @escaping (CGFloat) -> Font) -> some View {
        modifier(CoveScaledFont { scale, _ in make(scale) })
    }
}
