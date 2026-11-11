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

/// Tooltip bubbles of one window. They are drawn in a layer on top of the whole window (`tipLayer()` on the
/// root view), so text and pictures drawn after the control never cover them.
final class TipCenter: ObservableObject {
    struct Tip: Equatable { let id: UUID; let text: String; let frame: CGRect }
    @Published var tip: Tip?
    func show(_ t: Tip) { tip = t }
    func hide(_ id: UUID) { if tip?.id == id { tip = nil } }
}

private struct TipCenterKey: EnvironmentKey { static let defaultValue: TipCenter? = nil }
extension EnvironmentValues {
    var tipCenter: TipCenter? {
        get { self[TipCenterKey.self] }
        set { self[TipCenterKey.self] = newValue }
    }
}

/// The bubble: white text on the background color chosen in Settings, slightly see-through, with a thin light edge.
private struct TipBubble: View {
    let text: String
    @Environment(\.appBG) private var bg
    @Environment(\.classicGlass) private var classic   // Classic theme: the same glass as the buttons
    var body: some View {
        if classic {
            // Glass pill like the buttons, over a dark tint so the text always reads
            Text(text).font(.cv(12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(bg.opacity(0.6)))
                .classicClearGlass()
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .fixedSize()
        } else {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.white).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(bg.opacity(0.85)))   // a little see-through
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .fixedSize()
        }
    }
}

/// Draws the window's tooltip on top of everything, centered just below its control (kept inside the window).
private struct TipLayer: View {
    @ObservedObject var center: TipCenter
    var body: some View {
        GeometryReader { g in
            if let t = center.tip {
                let below = t.frame.maxY + 8 + 24 <= g.size.height
                TipBubble(text: t.text)
                    .position(x: min(max(t.frame.midX, 80), max(g.size.width - 80, 80)),
                              y: below ? t.frame.maxY + 8 + 14 : t.frame.minY - 8 - 14)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: center.tip)
    }
}

private struct TipLayerModifier: ViewModifier {
    @StateObject private var center = TipCenter()
    func body(content: Content) -> some View {
        content
            .environment(\.tipCenter, center)
            .coordinateSpace(name: "tipLayer")
            .overlay { TipLayer(center: center) }
    }
}

extension View {
    /// Root of a window: tooltips inside it are drawn over everything else.
    func tipLayer() -> some View { modifier(TipLayerModifier()) }
}

/// The bubble exists only while the pointer rests on the view, so idle controls carry nothing extra. Inside a
/// `tipLayer()` it is drawn on top of the window; elsewhere (sheets) under the control itself.
private struct HoverTip: ViewModifier {
    let text: String
    @State private var hover = false
    @State private var shown = false
    @State private var id = UUID()
    @Environment(\.tipCenter) private var center
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    if shown && !text.isEmpty {
                        if let center {
                            let f = g.frame(in: .named("tipLayer"))
                            Color.clear
                                .onAppear { center.show(.init(id: id, text: text, frame: f)) }
                                .onDisappear { center.hide(id) }
                        } else {
                            TipBubble(text: text).position(x: g.size.width / 2, y: g.size.height + 8 + 12)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .zIndex(shown ? 1 : 0)
            .onHover { hover = $0; if !$0 { shown = false } }
            .onDisappear { center?.hide(id) }
            // Shows after the pointer rests a moment, as a system tooltip does
            .task(id: hover) {
                guard hover else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled { shown = true }
            }
    }
}

