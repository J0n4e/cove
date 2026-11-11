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
    /// Under the mouse the accent rises from the bottom like a flame and fades out before the top.
    var hoverTint: some View {
        GeometryReader { g in
            ZStack {
                Capsule().fill(LinearGradient(stops: [.init(color: accent.opacity(0.75), location: 0),
                                                      .init(color: accent.opacity(0.3), location: 0.45),
                                                      .init(color: .clear, location: 0.85)],
                                              startPoint: .bottom, endPoint: .top))
                // bright core at the base of the flame
                Ellipse().fill(RadialGradient(colors: [Color.white.opacity(0.35), accent.opacity(0.5), .clear],
                                              center: .center, startRadius: 0, endRadius: g.size.width * 0.35))
                    .frame(width: g.size.width * 0.7, height: g.size.height * 0.8)
                    .position(x: g.size.width / 2, y: g.size.height)
                    .blur(radius: 4)
            }
            .clipShape(Capsule())
        }
        .opacity(hover ? 1 : 0)
    }
    @ViewBuilder func styled(_ content: Content) -> some View {
        if #available(macOS 26, *) {
            // System glass, untinted: lenses the page behind it, with light catching the edges and reacting to the
            // pointer
            sized(content).foregroundColor(.white)
                .background(hoverTint)
                .background(ClassicGlassBacking(shape: Capsule()))
                .glassEffect(.clear.interactive(), in: Capsule())   // the clearest glass
        } else {
            sized(content).foregroundColor(.white).background(hoverTint).background(ClassicGlassPill())
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
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(ClassicGlassBacking(shape: shape)).glassEffect(.clear.interactive(), in: shape)
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
            .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
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
