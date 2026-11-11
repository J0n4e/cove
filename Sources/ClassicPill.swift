import SwiftUI

// Classic theme pills, copied from the reference "Play S7:E21" button: see-through navy glass (the page shows
// through), blue light glowing in from the edges, a hairline rim and bright light streaks at the top and the bottom.
// Fixed blue for now; it does not follow the accent color yet.

/// The glass behind a Classic pill.
struct ClassicGlassPill: View {
    private let blue = Color(red: 0.25, green: 0.5, blue: 1.0)
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // thin navy tint: the background stays visible
                Capsule().fill(LinearGradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.36).opacity(0.5),
                                                       Color(red: 0.03, green: 0.07, blue: 0.24).opacity(0.42)],
                                              startPoint: .top, endPoint: .bottom))
                // blue light glowing in from the edges, darker in the middle (kept tight so the edge stays crisp)
                Capsule().strokeBorder(blue.opacity(0.5), lineWidth: h * 0.12).blur(radius: h * 0.07)
                // light streaks: a fine white line at the top, a bright blue line with a small glow at the bottom
                Capsule().fill(Color(red: 0.45, green: 0.7, blue: 1.0).opacity(0.5)).frame(width: w * 0.55, height: 4)
                    .blur(radius: 2).position(x: w / 2, y: h - 1)
                Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.6, height: 1).position(x: w / 2, y: 1)
                Capsule().fill(LinearGradient(colors: [.clear, Color(red: 0.6, green: 0.82, blue: 1.0), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.6, height: 1.5).position(x: w / 2, y: h - 1)
                // crisp rim: a bright hairline outside, a dark hairline just inside it for definition
                Capsule().strokeBorder(LinearGradient(colors: [Color(red: 0.7, green: 0.8, blue: 1.0).opacity(0.9),
                                                               blue.opacity(0.55),
                                                               Color(red: 0.6, green: 0.8, blue: 1.0).opacity(0.95)],
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
    /// Classic pill look: white label on blue glass.
    func classicGlassPill() -> some View {
        foregroundColor(.white).background(ClassicGlassPill())
    }
}
