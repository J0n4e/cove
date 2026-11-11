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
                // frosted glass: the page shows through, blurred
                Capsule().fill(.ultraThinMaterial)
                // thin dark accent tint
                Capsule().fill(Color.black.opacity(0.3))
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
                // glass reflection on the upper half, with a clean lower edge
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w - h * 0.3, height: h * 0.48).position(x: w / 2, y: h * 0.27)
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

/// True while the pointer is on a Classic pill.
private struct PillHoverKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var pillHover: Bool {
        get { self[PillHoverKey.self] }
        set { self[PillHoverKey.self] = newValue }
    }
}

/// Classic pills show only their icon; the title slides out while the pointer is on the pill.
struct ClassicHoverLabelStyle: LabelStyle {
    @Environment(\.pillHover) private var hover
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: hover ? 6 : 0) {
            configuration.icon
            configuration.title.fixedSize().frame(maxWidth: hover ? nil : 0, alignment: .leading).clipped()
                .opacity(hover ? 1 : 0)
        }
    }
}

/// White label on accent glass; a Label inside shows just its icon until the pointer is on the pill.
struct ClassicGlassPillStyle: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .labelStyle(ClassicHoverLabelStyle())
            .environment(\.pillHover, hover)
            .foregroundColor(.white).background(ClassicGlassPill())
            .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }
}

extension View {
    /// Classic pill look: white label on accent glass, title shown on hover.
    func classicGlassPill() -> some View { modifier(ClassicGlassPillStyle()) }
}
