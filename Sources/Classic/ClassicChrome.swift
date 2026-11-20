import AppKit
import SwiftUI

// Glass3D chrome: the Glass setting (Settings → General → Glass), the readable edge under the see-through top bar,
// window title bar and traffic lights, thin overlay scroll bars, the empty-state view and the A–Z thinning.

// MARK: - Glass setting

/// Settings → General → Glass. "Follow macOS" (default) leaves the system glass alone, which follows the macOS 27
/// Liquid Glass slider (clear ↔ tinted). Off: cove adds its own frosting (blur + background tint) to the glass
/// controls only, by `glassFrost` (0 clear … 1 tinted). Before macOS 26 there is no system glass: the slider applies.
enum GlassFrost {
    static let followKey = "glassFollowSystem"
    static let frostKey = "glassFrost"
    static let defaultFrost = 0.5

    /// How much of cove's own frosting to draw (0 = none).
    static func amount(follow: Bool, frost: Double, liquidGlass: Bool) -> Double {
        if liquidGlass && follow { return 0 }
        guard frost.isFinite else { return defaultFrost }
        return min(1, max(0, frost))
    }

    /// Opacity of the blur and of the background tint for an amount.
    static func layers(_ a: Double) -> (blur: Double, tint: Double) {
        (blur: min(1, a * 1.6), tint: 0.8 * a)
    }

    static var hasLiquidGlass: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }
}

/// Cove's own frosting under a glass control, read in one place for every Glass3D glass control.
struct ClassicGlassFrost<S: Shape>: View {
    let shape: S
    @AppStorage(GlassFrost.followKey) private var follow = true
    @AppStorage(GlassFrost.frostKey) private var frost = GlassFrost.defaultFrost
    @Environment(\.appBG) private var bg
    var body: some View {
        let a = GlassFrost.amount(follow: follow, frost: frost, liquidGlass: GlassFrost.hasLiquidGlass)
        let l = GlassFrost.layers(a)
        ZStack {
            if a > 0.001 {
                shape.fill(.ultraThinMaterial).opacity(l.blur)
                shape.fill(bg.opacity(l.tint))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The preview in Settings: a strip of colour with a glass pill over it, frosted as set.
struct GlassFrostPreview: View {
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, Theme.accent(accentName), .blue], startPoint: .leading, endPoint: .trailing)
            Text("Glass").cvFont(12, weight: .semibold).foregroundColor(.white)
                .padding(.horizontal, 16).frame(height: 28)
                .modifier(ClassicClearGlass(shape: Capsule(), interactive: false))
        }
        .frame(width: 150, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Readable edge under the see-through top bar

/// macOS 26+: Apple's soft top scroll edge effect (content blurs and dims softly only right under the bar, still
/// see-through). macOS 14/15: a soft fade from the background colour, as tall as the bar.
struct ClassicTopScrollEdge: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.scrollEdgeEffectStyle(.soft, for: .top) }
        else { content.overlay { ClassicTopFade() } }
    }
}

/// The AppKit poster grid is not reached by SwiftUI's edge effect: on macOS 26 it gets the soft fade itself
/// (before 26 the page-wide fade from ClassicTopScrollEdge already covers it).
struct ClassicGridTopFade: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.overlay { ClassicTopFade() } } else { content }
    }
}

/// A soft fade from the background colour over the top safe area (the bar, the title bar), see-through below.
struct ClassicTopFade: View {
    @Environment(\.appBG) private var bg
    var body: some View {
        GeometryReader { g in
            let h = g.safeAreaInsets.top
            if h > 0 {
                LinearGradient(stops: [.init(color: bg.opacity(0.7), location: 0),
                                       .init(color: bg.opacity(0.45), location: 0.6),
                                       .init(color: bg.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: g.size.width, height: h + 16)
                    .offset(y: -h)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Window: transparent title bar, traffic lights

/// Glass3D: the main window's title bar is transparent, so the banners and the video run to the top edge with the
/// traffic lights over them. Restored when the theme changes.
struct ClassicWindowChrome: NSViewRepresentable {
    final class V: NSView {
        weak var styled: NSWindow?
        var was = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, styled !== w else { return }
            restore()
            styled = w; was = w.titlebarAppearsTransparent
            w.titlebarAppearsTransparent = true
        }
        func restore() {
            if let w = styled { w.titlebarAppearsTransparent = was }
            styled = nil
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
    static func dismantleNSView(_ v: V, coordinator: ()) { v.restore() }
}

// MARK: - Scroll bars

/// Glass3D scroll bars: thin overlay scrollers with a light knob for the dark pages, shown only while scrolling.
/// Sits behind a SwiftUI ScrollView (same frame) and styles the NSScrollView that backs it.
struct ClassicOverlayScrollers: NSViewRepresentable {
    final class V: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        private var done = false
        func apply() {
            guard !done, let root = window?.contentView else { return }
            let me = convert(bounds, to: nil)
            guard me.width > 1, me.height > 1 else { return }
            let center = NSPoint(x: me.midX, y: me.midY)
            // The scroll view this sits behind: the smallest one around its centre that is about as big as it
            // (the rows' small horizontal scroll views inside a page don't count)
            var best: NSScrollView?
            func walk(_ v: NSView, _ depth: Int) {
                guard depth < 60 else { return }
                if let s = v as? NSScrollView {
                    let r = s.convert(s.bounds, to: nil)
                    if r.contains(center), r.width * r.height >= me.width * me.height * 0.5,
                       best.map({ let b = $0.convert($0.bounds, to: nil); return r.width * r.height < b.width * b.height }) ?? true {
                        best = s
                    }
                }
                if v is NSCollectionView { return }
                for c in v.subviews { walk(c, depth + 1) }
            }
            walk(root, 0)
            if let best { ClassicOverlayScrollers.style(best); done = true }
        }
        override func layout() { super.layout(); if window != nil { apply() } }
    }
    static func style(_ sv: NSScrollView) {
        if sv.scrollerStyle != .overlay { sv.scrollerStyle = .overlay }
        if sv.scrollerKnobStyle != .light { sv.scrollerKnobStyle = .light }
        if !sv.autohidesScrollers { sv.autohidesScrollers = true }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}

extension View {
    /// Glass3D vertical scroll bars on a ScrollView: thin, overlay, shown only while scrolling (the root hides
    /// the rows' horizontal ones).
    func classicScrollBars() -> some View { modifier(ClassicScrollBars()) }
}

/// Thin overlay scroll bars on pages that scroll vertically.
struct ClassicScrollBars: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollIndicators(.automatic, axes: .vertical)
            .background(ClassicOverlayScrollers().allowsHitTesting(false))
    }
}

// MARK: - Empty state

/// One empty state for Glass3D pages: a symbol, a headline and an optional line of help.
struct ClassicEmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).cvFont(40, weight: .light).foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(title).cvFont(15, weight: .bold).multilineTextAlignment(.center)
            if let message {
                Text(message).cvFont(12).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - A–Z bar

enum AlphaBar {
    /// Height of one letter row (letter + spacing).
    static let rowHeight: CGFloat = 21
    /// The letters that fit `slots` rows: all of them, or every other (every third, …) when they don't fit,
    /// always keeping the first. Empty when nothing fits.
    static func thin(_ letters: [String], slots: Int) -> [String] {
        guard slots > 0, !letters.isEmpty else { return [] }
        if letters.count <= slots { return letters }
        let step = Int((Double(letters.count) / Double(slots)).rounded(.up))
        return letters.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }
    /// Rows that fit a height (minus the strip's padding).
    static func slots(height: CGFloat, padding: CGFloat = 12) -> Int {
        guard height.isFinite, height > padding else { return 0 }
        return Int((height - padding) / rowHeight)
    }
}
