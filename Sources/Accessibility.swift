import SwiftUI
import AppKit

extension View {
    /// Tooltip plus the name VoiceOver reads, for controls that show only an icon (`.help` alone is only a hint).
    func helpLabel(_ text: String) -> some View { tip(text).accessibilityHint(text).accessibilityLabel(text) }

    /// Tooltip drawn by AppKit. SwiftUI's `.help` restarts its timer whenever the view redraws, and cards redraw
    /// on hover (lift, buttons appearing), so its tooltips often never showed. An empty text shows none.
    func tip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}

/// The AppKit tooltip view exists only while the pointer is on the view. Dozens of always-present AppKit views
/// made every window resize (going full screen) slow and made the video stutter.
private struct HoverTip: ViewModifier {
    let text: String
    @State private var hover = false
    @State private var shown = false
    @Environment(\.classicGlass) private var classic   // Classic theme: a glass bubble instead of the AppKit tooltip
    func body(content: Content) -> some View {
        if classic {
            content
                .overlay {
                    if shown && !text.isEmpty {
                        // Centered just below the control, never over it
                        GeometryReader { g in
                            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 24)
                                .classicClearGlass()
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
        } else {
            content
                .overlay { if hover && !text.isEmpty { ToolTipView(text: text) } }
                .onHover { hover = $0 }
        }
    }
}

private struct ToolTipView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView { PassThroughView() }
    func updateNSView(_ v: NSView, context: Context) {
        let t: String? = text.isEmpty ? nil : text
        if v.toolTip != t { v.toolTip = t }
    }
    /// Never takes clicks or hover; only carries the tooltip.
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
