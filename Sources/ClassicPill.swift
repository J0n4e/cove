import SwiftUI

// Classic theme pills: deep see-through glass tinted with the accent from Settings, light pooling along the
// bottom edge and a soft lit rim that is brightest at the bottom.

/// The glass behind a Classic pill.
struct ClassicGlassPill: View {
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        ZStack {
            // dark accent-tinted glass, a touch lighter at the top
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.black.opacity(0.6))
            Capsule().fill(LinearGradient(colors: [accent.opacity(0.42), accent.opacity(0.22)],
                                          startPoint: .top, endPoint: .bottom))
            // light pooling along the bottom edge
            Capsule().fill(LinearGradient(stops: [.init(color: .clear, location: 0.55),
                                                  .init(color: accent.opacity(0.35), location: 1)],
                                          startPoint: .top, endPoint: .bottom))
            // soft lit rim, brightest along the bottom
            Capsule().strokeBorder(LinearGradient(colors: [accent.opacity(0.7), accent.opacity(0.45), accent],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: accent.opacity(0.35), radius: 6)
    }
}

extension View {
    /// Classic pill look: white label on accent glass.
    func classicGlassPill() -> some View {
        foregroundColor(.white).background(ClassicGlassPill())
    }
}
