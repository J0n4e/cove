import SwiftUI

// Classic theme pills, copied from the reference "Play S7:E21" button and tinted with the accent from Settings:
// flat frosted glass that fades from left to right until almost clear, crisp hairline rim and fine light lines at the top and the
// bottom.

/// The glass behind a Classic pill on macOS before 26 (drawn by hand).
struct ClassicGlassPill: View {
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // frosted, dark accent-tinted glass on the left, fading to almost clear on the right
                Group {
                    Capsule().fill(.ultraThinMaterial).opacity(0.6)
                    Capsule().fill(Color.black.opacity(0.25))
                    Capsule().fill(accent.opacity(0.35))
                }.mask(Capsule().fill(LinearGradient(colors: [.black, .black.opacity(0.05)], startPoint: .leading, endPoint: .trailing)))
                // light lines: a fine white one at the top, a bright accent one at the bottom
                Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.6, height: 1).position(x: w / 2, y: 1)
                Capsule().fill(LinearGradient(colors: [.clear, accent, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.6, height: 1.5).position(x: w / 2, y: h - 1)
                Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.45, height: 1).position(x: w / 2, y: h - 1)
                // crisp rim: accent hairline lit white at the top and bottom, a dark hairline just inside it
                Capsule().strokeBorder(accent.opacity(0.8), lineWidth: 1)
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .clear, .white.opacity(0.35)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5).padding(1)
            }
            .clipShape(Capsule())
        }
        .brightness(0.08)
        .shadow(color: .black.opacity(0.4), radius: 1, y: 1)    // tight contact shadow for a sharp outline
    }
}

/// White label on accent glass.
struct ClassicGlassPillStyle: ViewModifier {
    /// Set: this tall; with `iconOnly` a circle showing just the icon (the title is the tooltip).
    var size: CGFloat? = nil
    var iconOnly = true
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    func body(content: Content) -> some View {
        styled(content)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
    /// Under the mouse: Settings → General → Hover effect (fogged mirror or soft accent glow).
    var hoverTint: some View { ClassicHoverEffect().opacity(hover ? 1 : 0) }
    @ViewBuilder func styled(_ content: Content) -> some View {
        if #available(macOS 26, *) {
            // System glass, untinted: lenses the page behind it, with light catching the edges and reacting to the
            // pointer
            sized(content).glossyLettering()
                .background(hoverTint)
                .background(ClassicGlassBacking(shape: Capsule()))
                .glassEffect(.clear.interactive(), in: Capsule())   // the clearest glass
        } else {
            sized(content).glossyLettering().background(hoverTint).background(ClassicGlassPill())
        }
    }
    private var accent: Color { Theme.accent(accentName) }
    @ViewBuilder func sized(_ content: Content) -> some View {
        if let size, iconOnly {
            content.labelStyle(.iconOnly).font(.cv(size * 0.36, weight: .medium))
                .frame(width: size, height: size)
        } else if let size {
            content.font(.cv(size * 0.36, weight: .medium))
                .padding(.horizontal, size * 0.38)
                .frame(minWidth: size, minHeight: size, maxHeight: size)
        } else { content }
    }
}

/// Play-button glass behind any shape (the top bar's sections, search box, info pill); a faint fill on macOS
/// before 26.
struct ClassicClearGlass<S: Shape>: ViewModifier {
    let shape: S
    /// false: still glass that does not react to the pointer (labels, not buttons)
    var interactive = true
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(ClassicGlassBacking(shape: shape)).glassEffect(interactive ? .clear.interactive() : .clear, in: shape)
        }
        else { content.background(shape.fill(Color.white.opacity(0.1))) }
    }
}

/// Faint light under the glass: a top-lit fill and a hairline rim. Clear glass over a plain background (the top
/// bar, the search box once results fill the page) otherwise shows almost nothing; with this it keeps the look it
/// has over a picture.
struct ClassicGlassBacking<S: Shape>: View {
    let shape: S
    var body: some View {
        shape.fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08), .white.opacity(0.2)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

/// Cards framed as a pane of glass: light catches the edge at the top-left and bottom-right corners (fading along
/// the sides), the edge itself looks frosted (a soft light bevel just inside it), and a faint sheen lies over the
/// top. Under the mouse the edge lights up and the card gives off a soft accent glow.
struct ClassicGlassCard: ViewModifier {
    let radius: CGFloat
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        let accent = Theme.accent(accentName)
        let lit = hover ? 1.0 : 0.7
        return content
            .overlay {
                ZStack {
                    // faint sheen over the upper part
                    shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.12), location: 0),
                                                      .init(color: .clear, location: 0.4)],
                                              startPoint: .top, endPoint: .bottom))
                    // frosted bevel: soft light just inside the edge, as stacked strokes (a blur per card made
                    // scrolling drag)
                    let bevel = hover ? 0.08 : 0.05
                    shape.strokeBorder(Color.white.opacity(bevel), lineWidth: 7)
                    shape.strokeBorder(Color.white.opacity(bevel), lineWidth: 4)
                    shape.strokeBorder(Color.white.opacity(bevel), lineWidth: 2)
                    // edge light: bright at the top-left and bottom-right corners, fading along the sides
                    shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.9 * lit), location: 0),
                                                              .init(color: .white.opacity(0.12 * lit), location: 0.3),
                                                              .init(color: .white.opacity(0.06 * lit), location: 0.5),
                                                              .init(color: .white.opacity(0.12 * lit), location: 0.7),
                                                              .init(color: .white.opacity(0.9 * lit), location: 1)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            // accent glow behind a hovered card; drawn only then (a shadow on every card made scrolling drag)
            .background { if hover { shape.fill(accent.opacity(0.45)).blur(radius: 14) } }
            .onHover { h in if h && ScrollActivity.scrolling { return }; withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }
}

/// ClassicGlassCard's look in two layers, for posters in long grids: the top sheen and the bright corner edge,
/// without the bevel strokes, the clip and a hover tracker of its own (the poster passes its hover in). The
/// accent glow is drawn only behind the hovered poster.
struct ClassicLightCard: ViewModifier {
    let radius: CGFloat
    var hover = false
    var accent: Color = .clear
    /// The card's size, when it's fixed: the edge is then drawn once into a picture and reused (see Raster)
    var size: CGSize? = nil
    @Environment(\.displayScale) private var scale
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        let lit = hover ? 1.0 : 0.7
        return content
            .overlay {
                if let size {
                    Raster.view("edge\(size.width)x\(size.height)r\(radius)l\(lit)", scale: scale, pad: 0) {
                        edge(shape, lit: lit).frame(width: size.width, height: size.height)
                    }
                } else {
                    edge(shape, lit: lit)
                }
            }
            .background { if hover { shape.fill(accent.opacity(0.45)).blur(radius: 14) } }
    }

    func edge(_ shape: RoundedRectangle, lit: Double) -> some View {
                ZStack {
                    shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.12), location: 0),
                                                      .init(color: .clear, location: 0.4)],
                                              startPoint: .top, endPoint: .bottom))
                    shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.9 * lit), location: 0),
                                                              .init(color: .white.opacity(0.12 * lit), location: 0.3),
                                                              .init(color: .white.opacity(0.06 * lit), location: 0.5),
                                                              .init(color: .white.opacity(0.12 * lit), location: 0.7),
                                                              .init(color: .white.opacity(0.9 * lit), location: 1)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                }
                .allowsHitTesting(false)
    }
}

/// The Glass3D hover look, as chosen in Settings → General → Hover effect.
struct ClassicHoverEffect: View {
    @AppStorage("classicHover") private var style = "fog"   // "fog" or "glow"
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        if style == "glow" {
            Capsule()
                .fill(RadialGradient(colors: [Theme.accent(accentName).opacity(0.5), Theme.accent(accentName).opacity(0.12)],
                                     center: .bottom, startRadius: 2, endRadius: 50))
                .blur(radius: 6)
        } else {
            FoggedGlass(shape: Capsule())
        }
    }
}

/// A fogged mirror: frosted haze over what is behind, uneven patches of white mist (denser low down, as fog
/// settles), a faint tint of the accent, and a soft clear edge where it fades out. Only drawn while hovered.
struct FoggedGlass<S: Shape>: View {
    let shape: S
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                shape.fill(.ultraThinMaterial)                       // frosted: what is behind goes soft
                shape.fill(Color.white.opacity(0.08))                // thin milky haze
                // uneven mist: thick clouds in some places, almost clear in others, heavier low down
                Ellipse().fill(Color.white.opacity(0.32)).frame(width: w * 0.42, height: h * 1.0)
                    .position(x: w * 0.18, y: h * 0.85).blur(radius: 5)
                Ellipse().fill(Color.white.opacity(0.26)).frame(width: w * 0.30, height: h * 0.8)
                    .position(x: w * 0.62, y: h * 0.95).blur(radius: 4)
                Ellipse().fill(Color.white.opacity(0.20)).frame(width: w * 0.22, height: h * 0.6)
                    .position(x: w * 0.88, y: h * 0.45).blur(radius: 4)
                Ellipse().fill(Color.white.opacity(0.14)).frame(width: w * 0.28, height: h * 0.45)
                    .position(x: w * 0.42, y: h * 0.15).blur(radius: 5)
                Circle().fill(Color.white.opacity(0.22)).frame(width: h * 0.35)
                    .position(x: w * 0.75, y: h * 0.3).blur(radius: 2)
                // clearer streaks wiped through the fog
                Capsule().fill(Color.black.opacity(0.18)).frame(width: w * 0.5, height: h * 0.14)
                    .rotationEffect(.degrees(-8)).position(x: w * 0.5, y: h * 0.5).blur(radius: 3)
                shape.fill(accent.opacity(0.12))                     // a breath of the accent
                shape.fill(LinearGradient(colors: [.clear, .white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(shape)
        }
    }
}

/// True inside the Classic theme: the shared search box and info pill use the Classic glass.
private struct ClassicGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var classicGlass: Bool {
        get { self[ClassicGlassKey.self] }
        set { self[ClassicGlassKey.self] = newValue }
    }
}

extension View {
    /// The top bar's glossy lettering (white fading to light grey, soft shadow) for a button's name and icon.
    /// Parts that set their own color (the rating star, the heart) keep it.
    func glossyLettering() -> some View {
        foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.92), Color(white: 0.62)],
                                       startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 3)
    }
    func classicClearGlass() -> some View { modifier(ClassicClearGlass(shape: Capsule())) }
    /// The banner Play button's glass pill, only when `on` (the selected top-bar section).
    @ViewBuilder func classicSelectedPill(_ on: Bool) -> some View {
        if on { classicGlassPill() } else { self }
    }
    /// The selected option of a strip of choices (top bar sections, view switches): Play-button glass.
    @ViewBuilder func classicSelectedGlass(_ on: Bool) -> some View {
        if on { modifier(ClassicClearGlass(shape: Capsule())) } else { self }
    }
    /// Classic pill look: white label on accent glass.
    func classicGlassPill(size: CGFloat? = nil, iconOnly: Bool = true) -> some View {
        modifier(ClassicGlassPillStyle(size: size, iconOnly: iconOnly))
    }
}
