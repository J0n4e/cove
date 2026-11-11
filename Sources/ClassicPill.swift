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
    /// Set: the pill is this tall.
    var size: CGFloat? = nil
    @AppStorage("accent") private var accentName = "red"
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // System glass: lenses the page behind it, with light catching the edges and reacting to the pointer;
            // the accent tints it from the left, fading to clear on the right
            sized(content).foregroundColor(.white)
                .background(Capsule().fill(LinearGradient(colors: [accent.opacity(0.1), accent.opacity(0.0)],
                                                          startPoint: .leading, endPoint: .trailing)))
                .glassEffect(.clear.interactive(), in: Capsule())   // the clearest glass
        } else {
            sized(content).foregroundColor(.white).background(ClassicGlassPill())
        }
    }
    private var accent: Color { Theme.accent(accentName) }
    @ViewBuilder func sized(_ content: Content) -> some View {
        if let size {
            content.font(.system(size: size * 0.36, weight: .medium))
                .padding(.horizontal, size * 0.38)
                .frame(minWidth: size, minHeight: size, maxHeight: size)
        } else { content }
    }
}

extension View {
    /// Classic pill look: white label on accent glass.
    func classicGlassPill(size: CGFloat? = nil) -> some View { modifier(ClassicGlassPillStyle(size: size)) }
}
