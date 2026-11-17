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
    struct Shadow { let radius: CGFloat; let y: CGFloat; let opacity: Double }
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

    // MARK: Animation
    enum Motion {
        static let fast = Animation.easeOut(duration: 0.15)
        static let slow = Animation.easeInOut(duration: 0.3)
    }

    // MARK: Pure helpers (tested)

    /// Width of the progress line along a thumbnail's bottom edge: the watched fraction (clamped to 0…1) of the
    /// width; nothing for an unstarted or finished item.
    static func progressWidth(fraction: Double, width: CGFloat) -> CGFloat {
        guard fraction > 0, fraction < 1, width > 0 else { return 0 }
        return (CGFloat(fraction) * width).rounded(.toNearestOrEven)
    }

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
