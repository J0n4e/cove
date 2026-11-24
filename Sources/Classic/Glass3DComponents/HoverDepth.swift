import AppKit
import SwiftUI

// UI polish round 2: depth on hover and on hero art.
// - ThumbnailHover: the "an inner control is under the pointer" flag shared by a thumbnail card and its controls
//   (centre Play, Resume ring), so the card's lit border and glow step back for both.
// - PosterShine: the soft light following the pointer over the hovered poster (SwiftUI posters; PosterGrid uses
//   the same math with one shared layer).
// - KenBurnsEffect: the very slow zoom / pan on the Home banner and detail hero backdrops.

// MARK: - Thumbnail inner-control hover

enum ThumbnailHover {
    /// The card's lit border / glow: on while hovered, unless the pointer is on one of its own controls.
    static func cardLit(hover: Bool, innerControl: Bool) -> Bool { hover && !innerControl }
    /// The flag after the card's hover changes: leaving the card clears it (the controls go with the hover).
    static func innerAfterCardHover(_ cardHover: Bool, inner: Bool) -> Bool { cardHover ? inner : false }
}

private struct ThumbnailInnerHoverKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}
private struct ThumbnailInnerHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by a thumbnail card: its controls (Play, Resume ring) report here while the pointer is on them.
    var thumbnailInnerHover: Binding<Bool>? {
        get { self[ThumbnailInnerHoverKey.self] }
        set { self[ThumbnailInnerHoverKey.self] = newValue }
    }
    /// The same flag's value, read by the card's lit edge (ClassicLightCard).
    var thumbnailInnerHovered: Bool {
        get { self[ThumbnailInnerHoveredKey.self] }
        set { self[ThumbnailInnerHoveredKey.self] = newValue }
    }
}

/// The card owning the flag: hands its setter and current value to everything inside it. The owner reads its own
/// state to build this, so a change redraws the card's edge.
struct ThumbnailInnerHoverScope: ViewModifier {
    let flag: Binding<Bool>
    let value: Bool
    func body(content: Content) -> some View {
        content.environment(\.thumbnailInnerHover, flag).environment(\.thumbnailInnerHovered, value)
    }
}

/// Reports the pointer being on this control to the enclosing thumbnail card (nothing outside a card).
struct ReportsThumbnailInnerHover: ViewModifier {
    @Environment(\.thumbnailInnerHover) private var inner
    func body(content: Content) -> some View {
        content.onHover { h in inner?.wrappedValue = h }
            .onDisappear { inner?.wrappedValue = false }
    }
}

extension View {
    /// This control sits on a thumbnail card: while the pointer is on it, the card's border and glow are off.
    func reportsThumbnailInnerHover() -> some View { modifier(ReportsThumbnailInnerHover()) }
}

// MARK: - Poster shine

enum PosterShineMath {
    /// The highlight's centre as a unit point (0…1, y from the top) for a pointer at `location` (points, origin
    /// top-left) over a poster of `size`; the resting point with Reduce Motion or no size.
    static func unit(location: CGPoint, size: CGSize, reduceMotion: Bool) -> CGPoint {
        guard !reduceMotion, size.width > 0, size.height > 0,
              location.x.isFinite, location.y.isFinite else { return Glass3DTokens.Shine.rest }
        return CGPoint(x: min(1, max(0, location.x / size.width)), y: min(1, max(0, location.y / size.height)))
    }

    /// AppKit (PosterGrid): a point in the zoomed card's un-zoomed coordinates (origin bottom-left, `zoom` about
    /// the centre) as a unit point with y from the top.
    static func unit(cardPoint p: CGPoint, size: CGSize, zoom: CGFloat, reduceMotion: Bool) -> CGPoint {
        guard zoom > 0, size.width > 0, size.height > 0 else { return Glass3DTokens.Shine.rest }
        let cx = size.width / 2, cy = size.height / 2
        let x = cx + (p.x - cx) / zoom
        let yUp = cy + (p.y - cy) / zoom
        return unit(location: CGPoint(x: x, y: size.height - yUp), size: size, reduceMotion: reduceMotion)
    }

    /// Radius of the highlight in points.
    static func radius(_ size: CGSize) -> CGFloat { max(size.width, size.height) * Glass3DTokens.Shine.radius }
}

/// A radial highlight following the pointer over a hovered poster, clipped to its rounded shape. Put it after the
/// poster's glass edge and before its badges, so the badges stay on top.
struct PosterShine: ViewModifier {
    let hover: Bool
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var location = CGPoint(x: -1, y: -1)

    func body(content: Content) -> some View {
        content
            .overlay {
                if hover {
                    GeometryReader { g in
                        let u = PosterShineMath.unit(location: location.x < 0 ? CGPoint(x: Glass3DTokens.Shine.rest.x * g.size.width,
                                                                                         y: Glass3DTokens.Shine.rest.y * g.size.height)
                                                                              : location,
                                                     size: g.size, reduceMotion: reduceMotion)
                        RadialGradient(colors: [Color.white.opacity(Glass3DTokens.Shine.opacity), .clear],
                                       center: UnitPoint(x: u.x, y: u.y), startRadius: 0,
                                       endRadius: PosterShineMath.radius(g.size))
                            .blendMode(.plusLighter)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .onContinuousHover { phase in
                guard hover, !reduceMotion else { return }
                if case .active(let p) = phase { location = p }
            }
            .animation(Glass3DTokens.Motion.resolved(Glass3DTokens.Motion.fast, reduceMotion: reduceMotion), value: hover)
    }
}

extension View {
    /// The shared poster hover shine (see PosterShine).
    func posterShine(hover: Bool, radius: CGFloat) -> some View { modifier(PosterShine(hover: hover, radius: radius)) }
}

/// AppKit posters (PosterGrid): ONE radial gradient layer, moved onto the hovered cell; only its points change
/// as the pointer moves (no re-raster).
final class PosterShineLayer: CAGradientLayer {
    override init() {
        super.init()
        type = .radial
        colors = [NSColor(white: 1, alpha: Glass3DTokens.Shine.opacity).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        masksToBounds = true
        cornerCurve = .circular
        actions = ["startPoint": NSNull(), "endPoint": NSNull(), "bounds": NSNull(), "position": NSNull(),
                   "frame": NSNull(), "cornerRadius": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    /// Centres the highlight on unit point `u` (y from the top).
    func place(_ u: CGPoint) {
        let s = bounds.size
        guard s.width > 0, s.height > 0 else { return }
        let r = PosterShineMath.radius(s)
        let c = CGPoint(x: u.x, y: 1 - u.y)   // layer unit space: y from the bottom
        startPoint = c
        endPoint = CGPoint(x: c.x + r / s.width, y: c.y + r / s.height)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - Ken Burns

enum KenBurnsMath {
    /// 0 → 1 → 0 over two periods, eased in and out (smooth turnarounds).
    static func phase(elapsed: Double, period: Double = Glass3DTokens.KenBurns.period) -> Double {
        guard period > 0, elapsed.isFinite, elapsed > 0 else { return 0 }
        let t = elapsed.truncatingRemainder(dividingBy: period * 2) / period
        let lin = t <= 1 ? t : 2 - t
        return (1 - cos(lin * Double.pi)) / 2
    }

    /// The zoom for a phase: 1 at rest up to `maxScale`; always 1 with Reduce Motion (static picture).
    static func scale(phase: Double, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let p = CGFloat(min(1, max(0, phase.isFinite ? phase : 0)))
        return 1 + (Glass3DTokens.KenBurns.maxScale - 1) * p
    }

    /// The zoom's anchor for a slide: off-centre towards one of four corners, picked from the slide's id (stable),
    /// so each slide drifts its own way. Inside 0…1, so scaling ≥ 1 never uncovers an edge.
    static func anchor(seed: String) -> CGPoint {
        var h: UInt32 = 5381
        for u in seed.unicodeScalars { h = (h &* 33) &+ u.value }
        let k = Glass3DTokens.KenBurns.pan
        let dx: CGFloat = h % 2 == 0 ? -k : k
        let dy: CGFloat = (h / 2) % 2 == 0 ? -k : k
        return CGPoint(x: 0.5 + dx, y: 0.5 + dy)
    }

    /// Whether the movement runs: not with Reduce Motion, during playback or with the window hidden.
    static func runs(reduceMotion: Bool, playing: Bool, visible: Bool) -> Bool { !reduceMotion && !playing && visible }
}

/// Whether any of the app's windows can be seen (not hidden, minimised away or covered).
final class WindowOcclusion: ObservableObject {
    static let shared = WindowOcclusion()
    @Published private(set) var visible = true
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.visible = NSApp.occlusionState.contains(.visible)
        }
    }
}

/// The slow zoom / pan on a hero backdrop (restarts whenever the view is re-created, i.e. per slide). Draws the
/// picture only: the legibility gradients sit above it, untouched.
struct KenBurnsEffect: ViewModifier {
    let seed: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @ObservedObject private var visibility = WindowOcclusion.shared
    /// One clock per picture: a view that SwiftUI re-creates (hover, a parent redraw) keeps its place in the
    /// zoom instead of jumping back to the start, so every place moves exactly like the Home banner (owner)
    @MainActor private var start: Date { KenBurnsClock.start(for: seed) }

    func body(content: Content) -> some View {
        let running = KenBurnsMath.runs(reduceMotion: reduceMotion, playing: playback.active, visible: visibility.visible)
        let a = KenBurnsMath.anchor(seed: seed)
        return TimelineView(.animation(minimumInterval: Glass3DTokens.KenBurns.frameInterval, paused: !running)) { ctx in
            content.scaleEffect(KenBurnsMath.scale(phase: KenBurnsMath.phase(elapsed: ctx.date.timeIntervalSince(start)),
                                                   reduceMotion: reduceMotion),
                                anchor: UnitPoint(x: a.x, y: a.y))
        }
    }
}

extension View {
    /// Ken Burns on a hero backdrop (see KenBurnsEffect).
    func kenBurns(seed: String) -> some View { modifier(KenBurnsEffect(seed: seed)) }
}


/// When each picture's slow zoom began (kept across view re-creation; a new picture starts at zero).
@MainActor enum KenBurnsClock {
    private static var starts: [String: Date] = [:]
    static func start(for seed: String) -> Date {
        if let d = starts[seed] { return d }
        if starts.count > 64 { starts.removeAll() }
        let d = Date(); starts[seed] = d; return d
    }
    static func reset(_ seed: String) { starts[seed] = nil }
}


/// The Home banner's feeling for a picture that never changes slide (season / collection deck): one slow,
/// eased zoom-in, then the picture softly cross-fades back to the start and zooms in again, so there is no
/// visible turnaround or jump (owner). Same speed and depth as the banner.
enum KenBurnsLoop {
    /// Seconds of the cross-fade back to the start at the end of each zoom
    static let fade: Double = 2.5
    /// Where one loop is: progress 0…1 of the zoom and how far into the closing fade (0 = none, 1 = done).
    static func state(elapsed: Double, period: Double = Glass3DTokens.KenBurns.period) -> (zoom: Double, fade: Double) {
        guard period > fade, elapsed.isFinite, elapsed > 0 else { return (0, 0) }
        let t = elapsed.truncatingRemainder(dividingBy: period)
        let lin = t / period
        let zoom = (1 - cos(lin * Double.pi)) / 2            // eased in and out, like the banner's slides
        let f = max(0, (t - (period - fade)) / fade)          // the last `fade` seconds
        return (zoom, (1 - cos(min(1, f) * Double.pi)) / 2)
    }
}

struct KenBurnsLoopEffect: ViewModifier {
    let seed: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @ObservedObject private var visibility = WindowOcclusion.shared
    @State private var zoomed = false
    @State private var shown = 1.0

    // Driven by SwiftUI animations (not by redraws): the deck card sits inside a button, where a timeline only
    // moved when the card was clicked (owner). An animation runs on its own, inside buttons too.
    func body(content: Content) -> some View {
        let running = KenBurnsMath.runs(reduceMotion: reduceMotion, playing: playback.active, visible: visibility.visible)
        let a = KenBurnsMath.anchor(seed: seed)
        let anchor = UnitPoint(x: a.x, y: a.y)
        return ZStack {
            content   // the copy at rest underneath, revealed as the zoomed one fades away
            content.scaleEffect(zoomed ? Glass3DTokens.KenBurns.maxScale : 1, anchor: anchor).opacity(shown)
        }
        .task(id: running) {
            guard running else { return }
            let period = Glass3DTokens.KenBurns.period, fade = KenBurnsLoop.fade
            while !Task.isCancelled {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { zoomed = false; shown = 1 }
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeInOut(duration: period)) { zoomed = true }
                try? await Task.sleep(nanoseconds: UInt64((period - fade) * 1_000_000_000))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: fade)) { shown = 0 }
                try? await Task.sleep(nanoseconds: UInt64(fade * 1_000_000_000))
            }
        }
    }
}

extension View {
    /// The banner-like loop for a still picture (see KenBurnsLoopEffect).
    func kenBurnsLoop(seed: String) -> some View { modifier(KenBurnsLoopEffect(seed: seed)) }
}
