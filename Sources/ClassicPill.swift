import SwiftUI

// Classic theme pills, copied from the reference "Play S7:E21" button and tinted with the accent from Settings:
// see-through dark glass (the page shows through), accent light glowing in from the edges, crisp hairline rim and
// fine light lines at the top and the bottom.

/// The glass behind a Classic pill.
struct ClassicGlassPill: View {
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // thin dark accent tint: the background stays visible
                Capsule().fill(Color.black.opacity(0.35))
                Capsule().fill(LinearGradient(colors: [accent.opacity(0.3), accent.opacity(0.2)],
                                              startPoint: .top, endPoint: .bottom))
                // accent light glowing in from the edges, darker in the middle (kept tight so the edge stays crisp)
                Capsule().strokeBorder(accent.opacity(0.5), lineWidth: h * 0.12).blur(radius: h * 0.07)
                // light lines: a fine white one at the top, a bright accent one with a small glow at the bottom
                Capsule().fill(accent.opacity(0.6)).frame(width: w * 0.55, height: 4)
                    .blur(radius: 2).position(x: w / 2, y: h - 1)
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
        // the hovered look, at rest: a little brighter and lifted off the page
        .brightness(0.12)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)    // tight contact shadow for a sharp outline
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}

extension View {
    /// Classic pill look: white label on accent glass.
    func classicGlassPill() -> some View {
        foregroundColor(.white).background(ClassicGlassPill())
    }
}
