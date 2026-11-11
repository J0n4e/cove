import SwiftUI

// Classic theme pills, copied from the reference "Play S7:E21" button and tinted with the accent from Settings:
// flat frosted glass (the page shows through, blurred), crisp hairline rim and fine light lines at the top and the
// bottom.

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
    /// Set: the pill is this tall and, with only its icon showing, a circle of this size.
    var size: CGFloat? = nil
    @State private var hover = false
    func body(content: Content) -> some View {
        sized(content)
            .labelStyle(ClassicHoverLabelStyle())
            .environment(\.pillHover, hover)
            .foregroundColor(.white).background(ClassicGlassPill())
            .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }
    @ViewBuilder func sized(_ content: Content) -> some View {
        if let size {
            content.font(.system(size: size * 0.36, weight: .medium))
                .padding(.horizontal, hover ? size * 0.38 : 0)
                .frame(minWidth: size, minHeight: size, maxHeight: size)
        } else { content }
    }
}

extension View {
    /// Classic pill look: white label on accent glass, title shown on hover.
    func classicGlassPill(size: CGFloat? = nil) -> some View { modifier(ClassicGlassPillStyle(size: size)) }
}
