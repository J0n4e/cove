import SwiftUI
import AppKit

extension View {
    /// Tooltip plus the name VoiceOver reads, for controls that show only an icon (`.help` alone is only a hint).
    func helpLabel(_ text: String) -> some View { tip(text).accessibilityHint(text).accessibilityLabel(text) }

    /// Tooltip drawn by AppKit. SwiftUI's `.help` restarts its timer whenever the view redraws, and cards redraw
    /// on hover (lift, buttons appearing), so its tooltips often never showed. An empty text shows none.
    func tip(_ text: String) -> some View { overlay(ToolTipView(text: text)) }
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
