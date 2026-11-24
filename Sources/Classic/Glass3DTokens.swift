import SwiftUI

// Glass3D (key "classic") design values: one place for the radii, glass strengths, shadows, type sizes, greys and
// animation speeds the Glass3D pages use. Text sizes are base sizes: views pass them through `.cvFont(...)`, so the
// Text size setting still scales them (Default = exactly these sizes).

enum Glass3DTokens {
    // MARK: Corner radius
    enum Radius {
        static let card: CGFloat = 12
        static let panel: CGFloat = 14
        static let row: CGFloat = 10
        static let field: CGFloat = 8
        static let thumb: CGFloat = 6
        static let tag: CGFloat = 4
        /// Text buttons (GlassButtonStyle primary / secondary / destructive)
        static let button: CGFloat = 9
        /// Pop-up glass menus, floating panels
        static let window: CGFloat = 16
        /// Hero / banner art and the big feature panels
        static let hero: CGFloat = 18
        /// The Home banner's info panel
        static let banner: CGFloat = 22
        /// Year in review share image cards (rendered at a fixed large pixel size)
        static let shareCard: CGFloat = 32
    }

    // MARK: Glass fill / outline
    enum Fill {
        static let subtle = 0.05
        static let strong = 0.10
    }
    enum Stroke {
        static let subtle = 0.10
        static let strong = 0.22
    }

    // MARK: Shadows (radius, y, opacity)
    struct Shadow: Equatable { let radius: CGFloat; let y: CGFloat; let opacity: Double }
    static let shadowSmall = Shadow(radius: 2, y: 1, opacity: 0.35)
    static let shadowMedium = Shadow(radius: 8, y: 3, opacity: 0.4)
    static let shadowLarge = Shadow(radius: 16, y: 6, opacity: 0.45)

    // MARK: Text sizes (base points, scaled by Text size through cvFont)
    enum Text {
        static let pageTitle: CGFloat = 30
        static let section: CGFloat = 22
        static let cardTitle: CGFloat = 15
        static let meta: CGFloat = 12
    }

    // MARK: Greys (text over the dark background)
    enum Grey {
        static let primary = Color.white.opacity(0.92)
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.42)
    }

    // MARK: Spacing (padding / stack spacing scale)
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let xl: CGFloat = 20
    }

    // MARK: Animation
    /// Three speeds and one spring. Views that animate on their own should go through `resolved(_:reduceMotion:)`
    /// (or `.g3Animation`), so Reduce Motion turns movement into an instant change.
    enum Motion {
        enum Speed: CaseIterable { case fast, standard, slow }
        static func duration(_ s: Speed) -> Double {
            switch s { case .fast: return 0.15; case .standard: return 0.22; case .slow: return 0.3 }
        }
        /// The duration actually used: 0 with Reduce Motion on.
        static func duration(_ s: Speed, reduceMotion: Bool) -> Double { reduceMotion ? 0 : duration(s) }

        static let fast = Animation.easeOut(duration: duration(.fast))
        static let standard = Animation.easeInOut(duration: duration(.standard))
        static let slow = Animation.easeInOut(duration: duration(.slow))
        /// Panels, pop-ups: a soft spring without bounce.
        static let springResponse: Double = 0.32
        static let springDamping: Double = 0.86
        static let spring = Animation.spring(response: springResponse, dampingFraction: springDamping)
        /// Shimmer sweep of skeleton placeholders (one pass).
        static let shimmerPeriod: Double = 1.4

        static func animation(_ s: Speed) -> Animation {
            switch s { case .fast: return fast; case .standard: return standard; case .slow: return slow }
        }
        /// nil (no animation) with Reduce Motion on.
        static func resolved(_ a: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : a }
        /// Whether a looping effect (shimmer, Ken Burns) may run.
        static func allowsLoop(reduceMotion: Bool) -> Bool { !reduceMotion }
    }

    // MARK: Status colours (accent-independent)
    /// ONE fixed red for every destructive / error / unread use, whatever the accent; success, warning, info likewise.
    enum Status {
        static let danger = Color(red: 1, green: 0.27, blue: 0.27)
        static let success = Color(red: 0.30, green: 0.82, blue: 0.42)
        static let warning = Color(red: 1, green: 0.62, blue: 0.04)
        static let info = Color(red: 0.35, green: 0.65, blue: 1)
    }

    // MARK: Icons
    enum Icon {
        /// Default SF Symbol weight next to text.
        static let weight: Font.Weight = .semibold
    }

    // MARK: Elevation 0–4 (fill + stroke + top highlight + shadow)
    /// 0 flat rows · 1 inline rows, chips, fields · 2 cards · 3 popovers, menus, toasts · 4 windows, hero panels.
    struct ElevationRecipe: Equatable {
        /// White fill opacity over what's behind
        let fill: Double
        /// Background colour (Settings → Background) fill opacity underneath, for floating surfaces (0 = none)
        let backgroundFill: Double
        let stroke: Double
        /// Top-edge specular highlight opacity (fades out towards the middle)
        let highlight: Double
        let shadow: Shadow?
    }
    static func elevation(_ level: Int) -> ElevationRecipe {
        switch min(4, max(0, level)) {
        case 0: return ElevationRecipe(fill: 0, backgroundFill: 0, stroke: 0, highlight: 0, shadow: nil)
        case 1: return ElevationRecipe(fill: 0.05, backgroundFill: 0, stroke: 0.10, highlight: 0.10, shadow: nil)
        case 2: return ElevationRecipe(fill: 0.07, backgroundFill: 0, stroke: 0.14, highlight: 0.22,
                                       shadow: Shadow(radius: 8, y: 3, opacity: 0.35))
        case 3: return ElevationRecipe(fill: 0.04, backgroundFill: 0.75, stroke: 0.18, highlight: 0.28,
                                       shadow: Shadow(radius: 16, y: 6, opacity: 0.45))
        default: return ElevationRecipe(fill: 0.04, backgroundFill: 0.75, stroke: 0.22, highlight: 0.30,
                                        shadow: Shadow(radius: 28, y: 12, opacity: 0.5))
        }
    }

    // MARK: Pure helpers (tested)

    /// The library sort button's text: "Sort: Name ↑".
    static func sortLabel(field: String, ascending: Bool) -> String {
        "Sort: \(field) \(ascending ? "↑" : "↓")"
    }

    /// "1,170 items" (grouped number; "1 item").
    static func itemCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return "\(f.string(from: NSNumber(value: n)) ?? String(n)) \(n == 1 ? "item" : "items")"
    }
}

extension View {
    /// The thin outline round glass buttons get next to Play / Resume, so they read as one set of the same height.
    func glass3DRoundOutline() -> some View {
        overlay(Circle().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 1).allowsHitTesting(false))
    }
    func g3Shadow(_ s: Glass3DTokens.Shadow) -> some View {
        shadow(color: .black.opacity(s.opacity), radius: s.radius, y: s.y)
    }
}

// MARK: - Thumbnails

/// A soft dark gradient at the bottom and top of a thumbnail, behind its code / time left / title, so the text reads
/// over bright frames.
struct ThumbnailScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(maxHeight: .infinity)
            Color.clear.frame(maxHeight: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Rows

/// A Home / page row heading at the section size, with an optional "See all ›" glass pill on the right.
struct Glass3DRowHeading: View {
    let title: String
    var seeAll: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SwiftUI.Text(title).cvFont(Glass3DTokens.Text.section, weight: .bold)
            Spacer(minLength: 12)
            if let seeAll {
                Button(action: seeAll) {
                    HStack(spacing: 3) {
                        SwiftUI.Text("See all")
                        Image(systemName: "chevron.right").cvFont(10, weight: .bold)
                    }
                    .cvFont(Glass3DTokens.Text.meta, weight: .semibold)
                    .foregroundColor(Glass3DTokens.Grey.primary)
                    .padding(.horizontal, 12).frame(height: 26)
                    .modifier(ClassicClearGlass(shape: Capsule()))
                }
                .buttonStyle(HoverButton())
                .helpLabel("See all \(title)")
            }
        }
    }
}

// MARK: - Settings

/// Glass3D Settings tab: a glass pill with the accent icon and name when selected; a faint hover fill otherwise.
struct Glass3DSettingsTab: View {
    let title: String
    let icon: String
    let on: Bool
    let action: () -> Void
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    var body: some View {
        let accent = Theme.accent(accentName)
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).coveFont(size: 18).foregroundColor(on ? accent : .secondary)
                SwiftUI.Text(title).coveFont(size: 11, weight: on ? .semibold : .regular)
                    .foregroundColor(on ? .white : .secondary)
            }
            .frame(minWidth: 62).padding(.horizontal, 6).padding(.vertical, 6)
            .background {
                let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous)
                if on {
                    shape.fill(Color.white.opacity(Glass3DTokens.Fill.strong))
                        .overlay(shape.strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
                } else if hover {
                    shape.fill(Color.white.opacity(Glass3DTokens.Fill.subtle))
                        .overlay(shape.strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.75))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand).focusEffectDisabled()
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
