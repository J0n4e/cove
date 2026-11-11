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
                // blue light glowing in from the edges, darker in the middle
                Capsule().strokeBorder(blue.opacity(0.55), lineWidth: h * 0.18).blur(radius: h * 0.16)
                // light streaks: soft at the top, bright at the bottom
                Ellipse().fill(Color.white.opacity(0.35)).frame(width: w * 0.55, height: 2).blur(radius: 1.5)
                    .position(x: w / 2, y: 1.5)
                Ellipse().fill(Color(red: 0.45, green: 0.7, blue: 1.0)).frame(width: w * 0.5, height: 3).blur(radius: 2)
                    .position(x: w / 2, y: h - 1.5)
                // hairline rim
                Capsule().strokeBorder(LinearGradient(colors: [Color(red: 0.6, green: 0.72, blue: 1.0).opacity(0.75),
                                                               blue.opacity(0.45),
                                                               Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.85)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        // the hovered look, at rest: a little brighter and lifted off the page
        .brightness(0.12)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

extension View {
    /// Classic pill look: white label on blue glass.
    func classicGlassPill() -> some View {
        foregroundColor(.white).background(ClassicGlassPill())
    }
}
