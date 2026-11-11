import SwiftUI
import AppKit

extension View {
    /// Tooltip plus the name VoiceOver reads, for controls that show only an icon (`.help` alone is only a hint).
    func helpLabel(_ text: String) -> some View { tip(text).accessibilityHint(text).accessibilityLabel(text) }

    /// Tooltip: a small bubble under the control in the background color from Settings. SwiftUI's `.help`
    /// restarts its timer whenever the view redraws, and cards redraw on hover, so its tooltips often never showed.
    /// An empty text shows none.
    func tip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}

/// The bubble exists only while the pointer rests on the view, so idle controls carry nothing extra.
private struct HoverTip: ViewModifier {
    let text: String
    @State private var hover = false
    @State private var shown = false
    @Environment(\.appBG) private var bg   // the background color chosen in Settings
    func body(content: Content) -> some View {
        content
            .overlay {
                if shown && !text.isEmpty {
                    // Centered just below the control, never over it; solid background so it always reads
                    GeometryReader { g in
                        Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(bg))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.75))
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                            .fixedSize()
                            .position(x: g.size.width / 2, y: g.size.height + 8 + 12)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .zIndex(shown ? 1 : 0)
            .onHover { hover = $0; if !$0 { shown = false } }
            // Shows after the pointer rests a moment, as a system tooltip does
            .task(id: hover) {
                guard hover else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
            }
    }
}

