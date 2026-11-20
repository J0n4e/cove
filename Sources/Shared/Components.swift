import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

// MARK: - Theme

private struct BGKey: EnvironmentKey { static let defaultValue = Color.black }

private struct InFavoritesKey: EnvironmentKey { static let defaultValue = false }

private struct NoBackKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True on the Favorites pages, where posters leave out their heart badge
    /// A page opened from search results: it stands on its own, with no Back button
    var noBack: Bool {
        get { self[NoBackKey.self] }
        set { self[NoBackKey.self] = newValue }
    }
    var inFavorites: Bool {
        get { self[InFavoritesKey.self] }
        set { self[InFavoritesKey.self] = newValue }
    }
    var appBG: Color {
        get { self[BGKey.self] }
        set { self[BGKey.self] = newValue }
    }
}

enum Theme {
    static let accents: [(String, Color)] = [
        ("red", Color(red: 0.90, green: 0.04, blue: 0.08)), ("orange", .orange), ("pink", .pink),
        ("purple", .purple), ("blue", .blue), ("teal", .teal), ("green", .green), ("white", .white)
    ]
    static let backgrounds: [(String, Color)] = [
        ("black", .black), ("charcoal", Color(white: 0.11)), ("navy", Color(red: 0.04, green: 0.07, blue: 0.17)),
        ("plum", Color(red: 0.12, green: 0.05, blue: 0.15)), ("forest", Color(red: 0.04, green: 0.12, blue: 0.08))
    ]
    static func accent(_ n: String) -> Color { accents.first { $0.0 == n }?.1 ?? accents[0].1 }
    /// Text color that stays readable on top of the accent color (black on white, white on everything else).
    static func onAccent(_ n: String) -> Color { n == "white" ? .black : .white }
    static func bg(_ n: String) -> Color { backgrounds.first { $0.0 == n }?.1 ?? .black }
}

/// Foreground that contrasts with the accent color (for labels drawn on an accent-colored background).
struct OnAccent: ViewModifier {
    @AppStorage("accent") private var name = "red"
    func body(content: Content) -> some View { content.foregroundColor(Theme.onAccent(name)) }
}

/// Apple TV glass: dark see-through fill, blur and a thin light outline (same as the round Back button).
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.black.opacity(0.4)))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

extension View { func glassCapsule() -> some View { modifier(GlassCapsule()) } }

/// Toolbar button in Apple TV glass; `active` (a filter in use) gets a lighter fill.
struct PillStyle: ViewModifier {
    @AppStorage("accent") private var accentName = "red"
    let active: Bool
    func body(content: Content) -> some View {
        content.coveFont(size: 12, weight: .medium)
            .foregroundStyle(active ? Theme.onAccent(accentName) : Color.white)
            .padding(.horizontal, 16).frame(height: 36)
            .background(Capsule().fill(active ? AnyShapeStyle(TintShapeStyle().opacity(0.8)) : AnyShapeStyle(Color.clear)))
            .glassCapsule()
            .contentShape(Capsule())
    }
}

extension View {
    /// Thin white outline that follows the rounded corners (posters, episode thumbnails, preview card).
    func thinBorder(_ radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
    func pill(active: Bool = false) -> some View { modifier(PillStyle(active: active)) }
    func onAccent() -> some View { modifier(OnAccent()) }
    func circleButton() -> some View {
        self.coveFont(size: 15).frame(width: 44, height: 44)
            .background(Color.white.opacity(0.14)).clipShape(Circle())
    }
}

func runtimeText(_ t: Int64) -> String {
    let m = Int(t / 600_000_000)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

/// A photo's edge (person page, Now Playing): the glass card frame in Glass3D, a faint outline otherwise.
struct PersonPhotoFrame: ViewModifier {
    let classic: Bool
    var radius: CGFloat = 14
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(ClassicLightCard(radius: radius)) }   // the posters' light glass edge
        else if radius == 14 { content.overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.15))) }
        else { content }
    }
}

/// The title's logo image from Emby (Apple TV style); falls back to big bold text when there is none.
struct TitleLogo: View {
    @Environment(\.classicGlass) private var classic   // Classic theme: its chosen font
    @EnvironmentObject var emby: Emby
    let item: Item
    var height: CGFloat = 90
    var font: CGFloat = 54
    var body: some View {
        CachedImage(url: emby.image(item.SeriesId ?? item.Id, "Logo", width: 700)) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: height, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            } else {
                Text(item.heroTitle).coveFont { s in let f = TextScale.scaledSize(base: font, scale: s); return classic ? .cv(f, weight: .heavy) : .system(size: f, weight: .heavy) }.lineLimit(2)
                    .minimumScaleFactor(0.6).frame(maxWidth: 620, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
        }
        .frame(minHeight: 40, alignment: .bottomLeading)
    }
}

struct Backdrop: View {
    @EnvironmentObject var emby: Emby
    let id: String
    var width: Int = 1600   // the Home banner asks for its own size (window width × 2, at most 2560)
    var body: some View {
        CachedImage(url: emby.image(id, "Backdrop", width: width)) { p in
            p.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.1) }
    }
}

/// The search box's glass look (dark tint over blur, thin light edge, soft shadow), shared by the
/// confirmation pill and the player's Skip Intro / Up next cards.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Glass3D: the Glass setting's frosting (controls such as the search pill; not panels)
    var frost = true
    @Environment(\.classicGlass) private var classic   // Classic theme: the Play button's glass instead
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(ClassicClearGlass(shape: shape, frost: frost)) } else { glass(content) }
    }
    func glass(_ content: Content) -> some View {
        content
            .background(shape.fill(Color.black.opacity(0.55)))
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
    }
}

extension View {
    func searchGlass() -> some View { modifier(GlassBackground(shape: Capsule())) }
    func glassPanel(_ radius: CGFloat = 16) -> some View {
        modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), frost: false))
    }
}

/// Heart button in the bottom-right corner on hover, for a person (Favorite People cards).
struct HoverPersonHeart: ViewModifier {
    @EnvironmentObject var emby: Emby
    let id: String
    let name: String
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    let fav = emby.isPersonFav(id)
                    ItemActionsButton.circle(fav ? "heart.fill" : "heart", on: fav,
                                             help: fav ? "Remove from Favorites" : "Add to Favorites") {
                        Task { await emby.setFav(id, !fav, name: name) }
                    }.padding(8)
                }
            }
            .scrollHover($hover)
    }
}

/// Two round buttons on a poster (bottom right) or list row: watched / unwatched and Favorites.
struct ItemActionsButton: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    /// A season's episodes: Watched marks them all, and shows as on only when every one is watched
    var children: [Item] = []
    static func circle(_ icon: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        ActionCircle(icon: icon, on: on, help: help, action: action)
    }

    /// Small round action button on a card. Classic theme: the glass button ("on" shows as the filled icon).
    struct ActionCircle: View {
        let icon: String
        let on: Bool
        let help: String
        let action: () -> Void
        @Environment(\.classicGlass) private var classic
        var body: some View {
            Button(action: action) {
                if classic {
                    if icon == "heart.fill" { Label { Text(help) } icon: { FavHeart(size: 13) }.classicGlassPill(size: 30) }
                    else {
                        Label(help, systemImage: on && !icon.hasSuffix(".fill") ? icon + ".circle.fill" : icon)
                            .classicGlassPill(size: 30)
                    }
                } else if icon == "heart.fill" {
                    FavHeart(size: 13)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .contentShape(Circle())
                } else {
                    Image(systemName: icon).coveFont(size: 12, weight: .bold)
                        .foregroundStyle(on ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .contentShape(Circle())
                }
            }
            .buttonStyle(.plainHand).tip(help)
        }
    }
    var body: some View {
        let played = children.isEmpty ? emby.isPlayed(item) : children.allSatisfy { emby.isPlayed($0) }
        let fav = children.isEmpty ? emby.isFav(item) : emby.isFav(item) && children.allSatisfy { emby.isFav($0) }
        HStack(spacing: 6) {
            Self.circle("checkmark", on: played, help: played ? "Mark as Unwatched" : "Mark as Watched") {
                Task { await emby.setItemPlayed(item, !played, children: children, name: item.Name, rollback: false) }
            }
            Self.circle(fav ? "heart.fill" : "heart", on: fav, help: fav ? "Remove from Favorites" : "Add to Favorites") {
                Task { await emby.setFav(item.id, !fav, children: children, name: item.Name) }
            }
        }
    }
}

/// Pointer position on a poster in its own and in window coordinates (a class: writes don't redraw the poster).
/// Whether the page is being scrolled right now (a wheel or trackpad tick in the last 0.2 s). While it is, posters
/// sliding under a resting pointer don't light up: each one flipping its hover lift, glow and action buttons on
/// and off for a frame made scrolling a long library stutter.
@MainActor
enum ScrollActivity {
    private static var last = Date.distantPast
    private static var settle: DispatchWorkItem?
    private static let monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
        last = Date()
        // A moment after the last scroll event: the page has stopped (see `ended`)
        settle?.cancel()
        let w = DispatchWorkItem {
            guard !scrolling else { return }
            ended.send()
            nudge(e.window)
        }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        return e
    }
    static var scrolling: Bool { _ = monitor; return Date().timeIntervalSince(last) < 0.2 }
    /// Sent when a scroll has stopped, so the card now under a resting pointer can light up (no mouse move comes)
    static let ended = PassthroughSubject<Void, Never>()
    /// Installs the watcher (called once at launch).
    static func start() { _ = monitor }

    /// A mouse move where the pointer already is, so AppKit checks what is under it again: views made during the
    /// scroll (a row that just appeared) learn the pointer is over them, and the pointer takes their shape.
    private static func nudge(_ window: NSWindow?) {
        guard let window, window.isKeyWindow,
              let e = NSEvent.mouseEvent(with: .mouseMoved, location: window.mouseLocationOutsideOfEventStream,
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 0, pressure: 0) else { return }
        NSApp.postEvent(e, atStart: false)
    }
}

/// Hover that pauses while the page scrolls: a card sliding under a resting pointer doesn't light up on the way,
/// and the one under the pointer when the scrolling stops does, with the hand pointer (macOS only updates the
/// pointer when the mouse moves).
struct ScrollHover: ViewModifier {
    @Binding var hover: Bool
    var animation: Animation? = nil
    var enabled = true
    /// Clickable (a card): the hand pointer when it lights up after a scroll. Off for tooltips.
    var hand = true
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { h in
                guard enabled else { return }
                inside = h
                if !h || !ScrollActivity.scrolling { set(h) }
            }
            .onReceive(ScrollActivity.ended) {
                guard enabled else { return }
                if inside != hover { set(inside) }
                // Also when it lit up in the last moment of the scroll: the pointer still shows the arrow then
                if inside && hand { NSCursor.pointingHand.set() }
            }
    }
    private func set(_ h: Bool) { if let animation { withAnimation(animation) { hover = h } } else { hover = h } }
}

extension View {
    func scrollHover(_ hover: Binding<Bool>, animation: Animation? = nil, enabled: Bool = true, hand: Bool = true) -> some View {
        modifier(ScrollHover(hover: hover, animation: animation, enabled: enabled, hand: hand))
    }
}

/// Page, player and banner buttons: grow a little and brighten under the mouse, and dip
/// when clicked.
struct HoverButton: ButtonStyle {
    /// For bare icons: a soft see-through backing appears under the mouse
    var backing = false
    func makeBody(configuration: Configuration) -> some View { LiftBody(c: configuration, backing: backing) }

    struct LiftBody: View {
        let c: ButtonStyleConfiguration
        let backing: Bool
        @State private var hover = false
        var body: some View {
            c.label
                .padding(backing ? 4 : 0)
                .background(Capsule().fill(Color.white.opacity(backing && hover ? 0.16 : 0)))
                .padding(backing ? -4 : 0)
                .brightness(hover ? 0.12 : 0)
                .scaleEffect(c.isPressed ? 0.95 : hover ? 1.07 : 1)
                .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 8, y: 3)
                .scrollHover($hover)
                .handCursor()
                .animation(.easeOut(duration: 0.15), value: hover)
                .animation(.easeOut(duration: 0.1), value: c.isPressed)
        }
    }
}

/// Pointing-hand cursor over anything clickable.
struct HandCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.link)
        } else {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active: inside = true; NSCursor.pointingHand.set()
                    case .ended: inside = false; NSCursor.arrow.set()
                    }
                }
                // Removed while under the mouse (e.g. a button that closes its panel): don't leave the hand behind
                .onDisappear { if inside { NSCursor.arrow.set() } }
        }
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursor()) }
}

/// `.plain` with the pointing-hand cursor: the style of Cove's own buttons and links.
struct PlainHand: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1).handCursor()
    }
}

extension ButtonStyle where Self == PlainHand {
    static var plainHand: PlainHand { PlainHand() }
}

/// Green badge: a check when the count is 0, otherwise the number.
/// Classic badge: a check (`count` nil) or the number of unwatched episodes on a small glass pill: dark
/// see-through fill lit a little at the top, a thin edge that catches the light. No blur or shadow, so posters stay
/// light to scroll.
struct TubeBadge: View {
    let count: Int?
    var body: some View {
        // Glossy like the heart and rating star beside it: a check when watched, else the unwatched count
        if let n = count { GlossyCount(text: n > 99 ? "99+" : "\(n)") } else { GlossyCheck() }
    }
    var tube: some View {
        Group {
            if let n = count {
                Text(n > 99 ? "99+" : "\(n)").coveFont(size: 12, weight: .bold)
            } else {
                Image(systemName: "checkmark").coveFont(size: 11, weight: .heavy)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 22)
        .glassTube()
    }
    func glyph<V: View>(_ v: V) -> some View {
        v.foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.85), radius: 1, y: 0.5)
    }
}

extension View {
    /// The Glass3D badge look: a glass tube bent into a capsule.
    func glassTube() -> some View {
        background(Capsule().fill(LinearGradient(colors: [Color(white: 0.3).opacity(0.75), Color.black.opacity(0.65)],
                                                 startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12), .white.opacity(0.3)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

struct WatchBadge: View {
    let item: Item
    let played: Bool
    /// Neutral badge fill (dark, with a light ring), so "watched" doesn't compete with the accent color.
    static let green = Color.black.opacity(0.7)

    @Environment(\.classicGlass) private var classic   // Classic theme: glass tubes, as the progress ring

    var body: some View {
        if classic { tubeBadge } else { plainBadge }
    }

    /// Watched: an empty glass tube ring around a glass check. Unwatched episodes: the count in a glass tube bent
    /// into a capsule.
    @ViewBuilder var tubeBadge: some View {
        if played { TubeBadge(count: nil).helpLabel("Watched") }
        else if item.isSeries, let n = item.UserData?.UnplayedItemCount, n > 0 {
            TubeBadge(count: n).helpLabel("\(n) unwatched episode\(n == 1 ? "" : "s")")
        }
    }

    @ViewBuilder var plainBadge: some View {
        if played {
            Image(systemName: "checkmark").coveFont(size: 12, weight: .heavy).foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Self.green)).overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .helpLabel("Watched")
        } else if item.isSeries, let n = item.UserData?.UnplayedItemCount, n > 0 {
            Text(n > 99 ? "99+" : "\(n)").coveFont(size: 12, weight: .bold).foregroundColor(.white)
                .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
                .background(Capsule().fill(Self.green)).overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .helpLabel("\(n) unwatched episode\(n == 1 ? "" : "s")")
        }
    }
}

/// 1:02:03 / 12:34 style time.
func timeString(_ t: Double) -> String {
    let s = Int(max(0, t)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Horizontal row with ‹ › buttons that page through items that don't fit on screen.
/// Arrow visibility and paging use the real scroll offset of the underlying NSScrollView, so they stay
/// correct at any window size (including full screen) and each arrow hides once that end is reached.
struct ArrowScrollRow<ID: Hashable, Content: View>: View {
    let ids: [ID]
    let itemWidth: CGFloat
    var spacing: CGFloat = 18
    var inset: CGFloat = 40
    @ViewBuilder let content: (ID) -> Content
    @StateObject private var finder = ScrollFinder()
    @State private var dragStart: CGFloat?
    @Environment(\.classicGlass) private var classic   // Classic theme: glass arrow buttons
    /// Glass3D: the arrows show only while the pointer is over the row
    @State private var rowHover = false
    var arrowsShown: Bool { !classic || rowHover }

    var body: some View {
        // No scrollbar: the arrows page the row; trackpad / wheel scrolling still works.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(ids, id: \.self) { id in content(id).id(id) }
            }
            // Room for a hovered card's glow and zoom (the scroll view clips at its edges); the row is pulled back by
            // the extra 12 pt below, so the layout stays as it was and doesn't reach the section title above
            .padding(.vertical, 20)
            .background(ScrollFinderView(finder: finder))
            // Click-and-drag to scroll with the mouse; a plain click still opens the item.
            .highPriorityGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        guard let sv = finder.scrollView else { return }
                        let clip = sv.contentView
                        if dragStart == nil { dragStart = clip.bounds.origin.x }
                        let maxX = max(0, (sv.documentView?.frame.width ?? 0) - clip.bounds.width)
                        let x = min(max(0, dragStart! - g.translation.width), maxX)
                        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
                        sv.reflectScrolledClipView(clip)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .scrollIndicators(.never)
        .contentMargins(.horizontal, inset, for: .scrollContent)
        .padding(.vertical, -12)
        .overlay(alignment: .leading) {
            if finder.canBack && arrowsShown {
                arrow("chevron.left", help: "Previous") { finder.page(-1, step: itemWidth + spacing) }.padding(.leading, 6)
            }
        }
        .overlay(alignment: .trailing) {
            if finder.canFwd && arrowsShown {
                arrow("chevron.right", help: "Next") { finder.page(1, step: itemWidth + spacing) }.padding(.trailing, 6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: finder.canBack)
        .animation(.easeOut(duration: 0.15), value: finder.canFwd)
        .animation(.easeOut(duration: 0.15), value: rowHover)
        .onHover { rowHover = $0 }
    }

    func arrow(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if classic {
                Label(help, systemImage: icon).classicGlassPill(size: 44)
                    .background(Circle().fill(Color.black.opacity(0.35)))   // reads over bright posters
            } else {
                Image(systemName: icon).coveFont(size: 18, weight: .bold).foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.7)))
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(HoverButton()).helpLabel(help)
        .transition(.opacity)
    }
}

/// Finds the NSScrollView behind a SwiftUI ScrollView (for mouse dragging and arrow paging) and
/// publishes whether there is more content to the left / right of what is currently visible.
final class ScrollFinder: ObservableObject {
    weak var scrollView: NSScrollView?
    @Published var canBack = false
    @Published var canFwd = false
    private var tokens: [NSObjectProtocol] = []

    func attach(_ sv: NSScrollView?) {
        guard let sv, sv !== scrollView else { return }
        scrollView = sv
        let nc = NotificationCenter.default
        for t in tokens { nc.removeObserver(t) }
        tokens = []
        // Scrolling and window / full-screen resizes change the clip view's bounds
        sv.contentView.postsBoundsChangedNotifications = true
        tokens.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        // Content loading or changing size changes the document view's frame
        if let doc = sv.documentView {
            doc.postsFrameChangedNotifications = true
            tokens.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
    }

    deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }

    func refresh() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let ins = sv.contentInsets
        let lo = -ins.left
        let hi = doc.frame.width + ins.right
        let back = clip.bounds.minX > lo + 1
        let fwd = clip.bounds.maxX < hi - 1
        if back != canBack { canBack = back }
        if fwd != canFwd { canFwd = fwd }
    }

    /// Slides the row by `step` points in the given direction, stopping at either end.
    func page(_ dir: Int, step: CGFloat) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let ins = sv.contentInsets
        let lo = -ins.left
        let hi = max(lo, doc.frame.width + ins.right - clip.bounds.width)
        let x = min(max(lo, clip.bounds.origin.x + CGFloat(dir) * step), hi)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        }, completionHandler: { [weak sv] in
            if let sv { sv.reflectScrolledClipView(sv.contentView) }
        })
    }
}

struct ScrollFinderView: NSViewRepresentable {
    let finder: ScrollFinder
    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        v.finder = finder
        DispatchQueue.main.async { finder.attach(v.enclosingScrollView) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if finder.scrollView == nil { DispatchQueue.main.async { finder.attach(v.enclosingScrollView) } }
    }

    /// Finds its scroll view once it's really in one. Right after creation it often isn't yet, and a row
    /// that never redraws afterwards (a Home poster row) then never showed its arrows.
    final class Probe: NSView {
        weak var finder: ScrollFinder?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.finder?.attach(self?.enclosingScrollView) }
        }
    }
}

/// Loading spinner drawn by SwiftUI. The system ProgressView is an AppKit view that always draws on top,
/// so a spinner on a page behind the player showed through the video.
struct Spinner: View {
    var inPlayer = false
    @ObservedObject private var playback = PlaybackFlag.shared
    @Environment(\.controlSize) private var size
    var d: CGFloat { size == .small || size == .mini ? 16 : size == .large ? 40 : 26 }
    var body: some View {
        // Pages behind the player live in separate AppKit hosting views, so their spinners can show
        // through the video: don't draw them at all while something is playing.
        if playback.active && !inPlayer { EmptyView() } else {
            wheel
        }
    }

    /// Rotation comes from the clock, not a repeatForever animation: such an animation also drives the
    /// view's removal, so the spinner never finished disappearing and stayed over the playing video.
    var wheel: some View {
        TimelineView(.animation) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            Circle()
                .trim(from: 0.08, to: 0.8)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: max(2, d / 9), lineCap: .round))
                .frame(width: d, height: d)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// True while the video player is on screen.
final class PlaybackFlag: ObservableObject {
    static let shared = PlaybackFlag()
    @Published var active = false
    var enteredFullScreen = false
}

/// The poster hover effect: lift 6 % with a shadow, drawn above its neighbours.
struct HoverLift: ViewModifier {
    var hover: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.06 : 1)   // no shadow: one on every card made scrolling drag
            .animation(.easeOut(duration: 0.15), value: hover)
            .zIndex(hover ? 1 : 0)
    }
}

/// HoverLift that tracks the pointer itself; optionally shows a play button on hover (as on Continue Watching).
struct SelfHoverLift: ViewModifier {
    var play: CGFloat = 0
    /// When set, the play icon is a button of its own (the card around it opens the details instead)
    var onPlay: (() -> Void)? = nil
    /// Tooltip of the play button (nil: the default)
    var playTip: String? = nil
    @State private var hover = false
    @Environment(\.classicGlass) private var classic   // Classic theme: the glass play button
    @ViewBuilder var icon: some View {
        if classic {
            Label("Play", systemImage: "play.fill").classicGlassPill(size: play + 6)
        } else {
            Image(systemName: "play.circle.fill").coveFont(size: play).foregroundColor(.white).shadow(radius: 6)
        }
    }
    func body(content: Content) -> some View {
        content
            .overlay {
                if hover && play > 0 {
                    if let onPlay {
                        Button(action: onPlay) { icon.contentShape(Circle()) }.buttonStyle(.plainHand)
                            .tip(playTip ?? (classic ? "" : "Play")).accessibilityLabel(playTip ?? "Play")   // Classic: no default tooltip
                    } else { icon }
                }
            }
            .modifier(HoverLift(hover: hover)).scrollHover($hover)
    }
}

extension View {
    /// `play`: size of the play button shown on hover (0 = none).
    func hoverLift(play: CGFloat = 0, onPlay: (() -> Void)? = nil) -> some View { modifier(SelfHoverLift(play: play, onPlay: onPlay)) }
}
