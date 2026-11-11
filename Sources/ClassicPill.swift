import SwiftUI

// Classic theme pills: glassmorphism capsule. A semi-transparent accent gradient that lets the page show through,
// a soft inner backlight glow, and light catching the rim at the top and the bottom. Bold white label.

/// The glass behind a Classic pill.
struct ClassicGlassPill: View {
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        ZStack {
            // semi-transparent accent gradient: deeper at the top, the background shows through
            Capsule().fill(LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.3)],
                                          startPoint: .top, endPoint: .bottom))
            Capsule().fill(Color.black.opacity(0.25))
            // soft inner backlight
            GeometryReader { g in
                Capsule().fill(RadialGradient(colors: [accent.opacity(0.55), .clear], center: .center,
                                              startRadius: 0, endRadius: g.size.width * 0.5))
                    .blur(radius: 6)
            }
            // rim lit at the top and the bottom, darker along the sides
            Capsule().strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.7), location: 0),
                                                          .init(color: accent.opacity(0.4), location: 0.3),
                                                          .init(color: accent.opacity(0.4), location: 0.7),
                                                          .init(color: .white.opacity(0.45), location: 1)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .clipShape(Capsule())
        .shadow(color: accent.opacity(0.4), radius: 8)
    }
}

extension View {
    /// Classic pill look: bold white label on accent glass.
    func classicGlassPill() -> some View {
        fontWeight(.bold).foregroundColor(.white).background(ClassicGlassPill())
    }
}
