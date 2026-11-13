import AppKit
import Combine
import SwiftUI

/// Library poster grid on NSCollectionView (both themes, see PosterLook). LazyVGrid rebuilds a full SwiftUI card for every poster that
/// scrolls in; here cells are reused and drawn natively: the poster picture, one picture of its badges and glass edge
/// (drawn once per look, see Raster), and two text labels. Hover is done on the cell itself with Core Animation (zoom,
/// brighter edge, accent glow in Glass3D) plus the watched/favorite buttons fading in; nothing is swapped.
/// How the posters of one theme look: size, corners, label fonts and badges.
struct PosterLook: Equatable {
    let glass3D: Bool
    var size: CGSize { glass3D ? CGSize(width: 150, height: 225) : CGSize(width: 170, height: 255) }
    var radius: CGFloat { glass3D ? 8 : 12 }
    var titleFont: NSFont { glass3D ? ClassicFont.nsFont(12, .semibold) : .systemFont(ofSize: 12, weight: .semibold) }
    var yearFont: NSFont { glass3D ? ClassicFont.nsFont(10, .regular) : .systemFont(ofSize: 10, weight: .regular) }
    static let titleH: CGFloat = 16, yearH: CGFloat = 13
}

struct PosterGrid: NSViewRepresentable {
    let emby: Emby
    let items: [Item]
    var look = PosterLook(glass3D: true)
    var insets = NSEdgeInsets(top: 0, left: 40, bottom: 24, right: 92)
    /// The page header (title, tabs, controls): it scrolls with the posters, above them
    var header: AnyView? = nil
    /// Under the posters while the next page loads (a spinner) or failed to (Try Again); nil: nothing
    var footer: AnyView? = nil
    /// Height of the see-through top bar the grid runs under: the content starts below it and scrolls up under it
    var topInset: CGFloat = 0
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 18
    /// Opens any page (a person from the header): links in the header can't reach the NavigationStack themselves
    var push: ((any Hashable) -> Void)? = nil
    /// Called when the item at this index is about to show (for paging).
    var willShow: (Int) -> Void = { _ in }
    let open: (Item) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Extra room on each side of the grid so each poster sits centered in its column, as LazyVGrid's adaptive
    /// columns do: as many columns as fit, the spare width shared out between them.
    static func centering(width: CGFloat, item: CGFloat, spacing: CGFloat) -> CGFloat {
        let n = max(1, floor((width + spacing) / (item + spacing)))
        let column = (width - spacing * (n - 1)) / n
        return max(0, (column - item) / 2)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        let cv = PosterCollectionView()
        cv.collectionViewLayout = layout
        cv.backgroundColors = [.clear]
        cv.isSelectable = false
        cv.register(PosterGridCell.self, forItemWithIdentifier: PosterGridCell.id)
        cv.register(PosterGridFooter.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
                    withIdentifier: PosterGridFooter.id)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.coordinator = context.coordinator
        cv.autoresizingMask = [.width]   // follow the window width (columns re-flow)
        let sv = NSScrollView()
        sv.documentView = cv
        sv.drawsBackground = false
        sv.automaticallyAdjustsContentInsets = false
        sv.hasVerticalScroller = true
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: sv.contentView)
        context.coordinator.cv = cv
        return sv
    }

    /// Take the space offered. Without this SwiftUI asks the scroll view's fittingSize on every frame,
    /// which measures the whole collection view through Auto Layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        if sv.contentInsets.top != topInset {
            let atTop = sv.contentView.bounds.origin.y <= -sv.contentInsets.top + 1
            sv.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            if atTop { sv.contentView.scroll(to: NSPoint(x: 0, y: -topInset)); sv.reflectScrolledClipView(sv.contentView) }
        }
        if let layout = c.cv?.collectionViewLayout as? NSCollectionViewFlowLayout,
           layout.minimumInteritemSpacing != spacing || layout.minimumLineSpacing != lineSpacing {
            layout.minimumInteritemSpacing = spacing
            layout.minimumLineSpacing = lineSpacing
        }
        // On a Favorites page: no heart on the posters, everything there is a favorite
        let inFavorites = context.environment.inFavorites
        if c.inFavorites != inFavorites { c.inFavorites = inFavorites; c.refreshVisible() }
        c.setHeader(header.map {
            AnyView($0.environmentObject(emby).environment(\.classicGlass, look.glass3D)
                .environment(\.pagePush, push).environment(\.inFavorites, inFavorites)
                .environment(\.appBG, context.environment.appBG)
                .tint(Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red")))
        })
        c.setFooter(footer.map {
            AnyView($0.environmentObject(emby).environment(\.classicGlass, look.glass3D)
                .tint(Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red")))
        })
        c.insets = insets
        if c.look != look { c.look = look; c.cv?.reloadData() }
        c.applyLayout()
        c.emby = emby
        c.willShow = willShow
        c.open = open
        c.scale = context.environment.displayScale
        let ids = items.map(\.id)
        if ids != c.ids {
            c.items = items; c.ids = ids
            c.cv?.reloadData()
        } else {
            // Same posters, maybe new state (watched, favorite): refresh the ones on screen
            c.items = items
            c.refreshVisible()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var cv: PosterCollectionView?
        var emby: Emby?
        var items: [Item] = []
        var ids: [String] = []
        var scale: CGFloat = 2
        var insets = NSEdgeInsets()
        var look = PosterLook(glass3D: true)
        var inFavorites = false
        private var watchers: [AnyCancellable] = []
        /// The page header, at the top of the scrolling content (see PosterGrid.header)
        private var headerHost: NSHostingController<AnyView>?
        private var headerH: CGFloat = 0

        /// The footer's content; the footer view itself is the collection view's (see PosterGridFooter)
        private var footer: AnyView?
        func setFooter(_ view: AnyView?) {
            let had = footer != nil
            footer = view
            (cv?.supplementaryView(forElementKind: NSCollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0))
                as? PosterGridFooter)?.show(view)
            guard had != (view != nil), let layout = cv?.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            layout.footerReferenceSize = CGSize(width: 0, height: view == nil ? 0 : 64)
        }

        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at ip: IndexPath) -> NSView {
            let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: PosterGridFooter.id, for: ip) as! PosterGridFooter
            v.show(footer)
            return v
        }

        func setHeader(_ view: AnyView?) {
            guard let view, let cv else { headerHost?.view.removeFromSuperview(); headerHost = nil; headerH = 0; return }
            if let h = headerHost { h.rootView = view } else {
                let h = NSHostingController(rootView: view)
                h.sizingOptions = []
                cv.addSubview(h.view, positioned: .below, relativeTo: nil)   // under the cells
                headerHost = h
            }
            layoutHeader()
        }

        /// Sizes the header to the grid's width; the posters start below it.
        func layoutHeader() {
            guard let h = headerHost, let cv else { return }
            let w = cv.bounds.width
            let height = ceil(h.sizeThatFits(in: CGSize(width: w, height: 10_000)).height)
            h.view.frame = CGRect(x: 0, y: 0, width: w, height: height)   // the collection view is flipped: y 0 is the top
            if abs(height - headerH) > 0.5 { headerH = height; applyLayout() }
        }
        /// The settings the posters are drawn with, to redraw them only when one of these changes
        private var looks = ""

        override init() {
            super.init()
            // Your Trakt rating, and Settings (poster labels, font, accent): redraw the posters on screen
            watchers.append(Trakt.shared.objectWillChange.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshVisible() })
            watchers.append(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.settingsChanged() })
            looks = Self.currentLooks
        }

        private static var currentLooks: String {
            let d = UserDefaults.standard
            return ["posterShowTitle", "posterShowYear", "posterLabelAlign", "classicFont", "accent"]
                .map { "\(d.object(forKey: $0) ?? "")" }.joined(separator: "|")
        }

        private func settingsChanged() {
            let now = Self.currentLooks
            guard now != looks else { return }
            looks = now
            applyLayout()
            refreshVisible()
        }

        /// Cell size: the poster, plus room for the labels that are shown.
        func applyLayout() {
            let d = UserDefaults.standard
            let showTitle = d.object(forKey: "posterShowTitle") as? Bool ?? true
            let showYear = d.object(forKey: "posterShowYear") as? Bool ?? true
            let labelH: CGFloat = (showTitle || showYear)
                ? 6 + (showTitle ? PosterLook.titleH : 0) + (showYear ? PosterLook.yearH : 0) : 0
            guard let cv, let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let size = CGSize(width: look.size.width, height: look.size.height + labelH)
            if layout.itemSize != size { layout.itemSize = size }
            // As LazyVGrid's adaptive columns: the spare width is shared out, so each poster sits centered in
            // its column (the flow layout alone would put the first poster at the very edge)
            let side = PosterGrid.centering(width: cv.bounds.width - insets.left - insets.right,
                                            item: size.width, spacing: layout.minimumInteritemSpacing)
            var inset = insets
            inset.left += side; inset.right += side
            if headerH > 0 { inset.top += headerH + 18 }
            if !NSEdgeInsetsEqual(layout.sectionInset, inset) { layout.sectionInset = inset }
        }

        var willShow: (Int) -> Void = { _ in }
        var open: (Item) -> Void = { _ in }
        /// The poster under the pointer
        private var hoverIndex: Int?

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: PosterGridCell.id, for: ip) as! PosterGridCell
            if let emby { cell.show(items[ip.item], emby: emby, look: look, noHeart: inFavorites, scale: scale) }
            cell.setHover(ip.item == hoverIndex, animated: false)   // a reused cell may come zoomed
            return cell
        }

        func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt ip: IndexPath) { willShow(ip.item) }

        func refreshVisible() {
            guard let cv, let emby else { return }
            for ip in cv.indexPathsForVisibleItems() where ip.item < items.count {
                (cv.item(at: ip) as? PosterGridCell)?.show(items[ip.item], emby: emby, look: look, noHeart: inFavorites, scale: scale)
            }
        }

        /// The zoom would stay on a poster sliding away under the pointer. Only a real scroll: the bounds also
        /// change when the next page of posters loads.
        @objc func scrolled() {
            guard ScrollActivity.scrolling else { return }
            hover(nil)
            // When the scrolling stops, the poster now under a resting pointer lights up (no mouse move comes)
            settle?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.pointerCheck() }
            settle = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
        private var settle: DispatchWorkItem?

        /// Hover and pointer for wherever the mouse is now; waits while the page still scrolls.
        func pointerCheck() {
            guard let cv, let window = cv.window, window.isVisible else { return }
            if ScrollActivity.scrolling {
                let w = DispatchWorkItem { [weak self] in self?.pointerCheck() }
                settle = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
                return
            }
            let p = cv.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard cv.visibleRect.contains(p) else { return }
            let i = item(at: p)
            hover(i)
            if i != nil { NSCursor.pointingHand.set() }
        }

        /// The pointer is over poster `i` (nil: none): that poster zooms in, the previous one zooms out.
        func hover(_ i: Int?) {
            guard i != hoverIndex else { return }
            if let old = hoverIndex { cell(old)?.setHover(false) }
            hoverIndex = i
            if let i { cell(i)?.setHover(true) }
        }

        private func cell(_ i: Int) -> PosterGridCell? { cv?.item(at: IndexPath(item: i, section: 0)) as? PosterGridCell }

        func item(at p: NSPoint) -> Int? {
            // From the layout, not the views: indexPathForItem(at:) hit-tests views (a zoomed neighbour, a button)
            let hit = cv?.collectionViewLayout?.layoutAttributesForElements(in: NSRect(origin: p, size: NSSize(width: 1, height: 1)))
                .first { $0.representedElementCategory == .item && $0.frame.contains(p) }
            guard let i = hit?.indexPath?.item, i < items.count else { return nil }
            return i
        }
    }
}

/// Follows the pointer to zoom the poster under it; a click on a poster opens it.
final class PosterCollectionView: NSCollectionView {
    weak var coordinator: PosterGrid.Coordinator?
    private var tracking: NSTrackingArea?

    /// A new width: the columns' spare space is shared out again (see applyLayout)
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { coordinator?.layoutHeader(); coordinator?.applyLayout() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        guard !ScrollActivity.scrolling, let c = coordinator else { return }
        let i = c.item(at: convert(e.locationInWindow, from: nil))
        c.hover(i)
        if i != nil { NSCursor.pointingHand.set() }
    }

    /// AppKit also sends this when views change under a resting pointer: only a pointer really outside the grid
    /// ends the hover
    override func mouseExited(with e: NSEvent) {
        super.mouseExited(with: e)
        if !visibleRect.contains(convert(e.locationInWindow, from: nil)) { coordinator?.hover(nil) }
    }

    /// The hand pointer over a poster
    override func cursorUpdate(with e: NSEvent) {
        if coordinator?.item(at: convert(e.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
        else { super.cursorUpdate(with: e) }
    }

    /// NSCollectionView's own mouseDown tracks a selection and keeps the mouse-up: a poster click is taken here
    private var downAt: Int?
    override func mouseDown(with e: NSEvent) {
        downAt = coordinator?.item(at: convert(e.locationInWindow, from: nil))
        if downAt == nil { super.mouseDown(with: e) }
    }

    override func mouseUp(with e: NSEvent) {
        defer { downAt = nil }
        guard let c = coordinator, let i = c.item(at: convert(e.locationInWindow, from: nil)), i == downAt
        else { return super.mouseUp(with: e) }
        c.hover(nil)
        c.open(c.items[i])
    }

    /// Leaving the page (a movie opened over it): no poster left zoomed for when it comes back
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.hover(nil) }
    override func viewDidHide() { super.viewDidHide(); coordinator?.hover(nil) }
}

/// The strip under the posters: the next page's spinner, or Try Again.
final class PosterGridFooter: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("PosterGridFooter")
    private var host: NSHostingView<AnyView>?

    func show(_ content: AnyView?) {
        let view = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity))
        if let host { host.rootView = view; return }
        let h = NSHostingView(rootView: view)
        h.sizingOptions = []
        h.frame = bounds
        h.autoresizingMask = [.width, .height]
        addSubview(h)
        host = h
    }
}

/// One poster drawn with layers: picture, badges picture, edge pictures, title and year. On hover the poster part
/// (`card`) zooms 6 %, its edge brightens and the watched/favorite buttons fade in.
final class PosterGridCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PosterGridCell")
    /// The poster part, zoomed on hover: picture, badges and edge (the labels under it stay put)
    private let card = CALayer()
    private let poster = CALayer()
    private let decor = CALayer()
    private let edge = CALayer()
    private let edgeLit = CALayer()     // the brighter hover edge, faded in over `edge`
    /// Glass3D: the accent glow behind the hovered poster, a blurred shadow faded in with the zoom
    private let glow = CALayer()
    /// The watched/favorite buttons, shown on hover (SwiftUI, made the first time this cell is hovered)
    private var buttons: NSHostingView<AnyView>?
    private var item: Item?
    private weak var emby: Emby?
    private(set) var hovered = false
    private let nameLabel = CALayer()
    private let year = CALayer()
    /// Which labels the cell shows now, so a label drawn late for an earlier poster is dropped
    private var labelToken = 0
    private var url: URL?
    private var load: Task<Void, Never>?
    private var look = PosterLook(glass3D: true)

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        poster.cornerCurve = .circular
        poster.masksToBounds = true
        poster.contentsGravity = .resizeAspectFill
        poster.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        glow.shadowOffset = .zero
        glow.shadowRadius = 14
        glow.shadowOpacity = 0.45
        card.addSublayer(glow)   // first: behind the poster
        for l in [poster, decor, edge, edgeLit] { card.addSublayer(l) }
        edgeLit.opacity = 0; glow.opacity = 0
        v.layer?.addSublayer(card)
        for t in [nameLabel, year] {
            t.contentsGravity = .topLeft
            t.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            v.layer?.addSublayer(t)
        }
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Flipped coordinates aren't used: the poster sits at the top of the cell
        let h = view.bounds.height, ps = look.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // bounds and position, not frame: the card may be zoomed
        card.bounds = CGRect(origin: .zero, size: ps)
        card.position = CGPoint(x: ps.width / 2, y: h - ps.height / 2)
        for l in [poster, decor, edge, edgeLit, glow] { l.frame = card.bounds }
        let outline = CGPath(roundedRect: card.bounds, cornerWidth: look.radius, cornerHeight: look.radius, transform: nil)
        glow.shadowPath = outline
        // Only outside the card: a watched poster is see-through, and the shadow under it tinted it
        let hole = CAShapeLayer()
        let p = CGMutablePath(); p.addRect(card.bounds.insetBy(dx: -60, dy: -60)); p.addPath(outline)
        hole.path = p; hole.fillRule = .evenOdd
        glow.mask = hole
        var y = h - ps.height - 6
        if !nameLabel.isHidden { y -= PosterLook.titleH; nameLabel.frame = CGRect(x: 0, y: y, width: ps.width, height: PosterLook.titleH) }
        if !year.isHidden { y -= PosterLook.yearH; year.frame = CGRect(x: 0, y: y, width: ps.width, height: PosterLook.yearH) }
        CATransaction.commit()
        placeButtons()
    }

    @MainActor func show(_ item: Item, emby: Emby, look: PosterLook, noHeart: Bool, scale: CGFloat) {
        if look != self.look { self.look = look; view.needsLayout = true }
        self.item = item; self.emby = emby
        let played = emby.isPlayed(item)
        let fav = emby.isFav(item) && !noHeart
        let rating = Trakt.shared.rating(item)
        let pct = item.UserData?.PlayedPercentage.map { Int($0) } ?? 0
        let progress = (pct > 0 && pct < 100 && !played) ? pct : 0
        let accent = UserDefaults.standard.string(forKey: "accent") ?? "red"
        let unwatched = item.isSeries && !played ? (item.UserData?.UnplayedItemCount ?? 0) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        poster.opacity = played ? 0.6 : 1
        poster.cornerRadius = look.radius
        let key = "gridDecor|\(look.glass3D)|\(played)|\(unwatched)|\(fav)|\(rating ?? 0)|\(progress)|\(accent)"
        decor.contents = Raster.image(key, scale: scale, pad: 0) {
            PosterDecor(item: item, played: played, fav: fav, progress: progress, accent: Theme.accent(accent), look: look)
                .environmentObject(emby).environment(\.classicGlass, look.glass3D)
        }
        for (l, lit) in [(edge, false), (edgeLit, true)] {
            l.contents = Raster.image("gridEdge|\(look.glass3D)|\(lit)", scale: scale, pad: 0) {
                Color.clear.frame(width: look.size.width, height: look.size.height).modifier(PosterDecor.Edge(look: look, lit: lit))
            }
        }
        for l in [poster, decor, edge, edgeLit] { l.contentsScale = scale }
        // Follows the Settings accent; Glass has no glow (as its SwiftUI card)
        glow.shadowColor = look.glass3D ? NSColor(Theme.accent(accent)).cgColor : NSColor.clear.cgColor
        CATransaction.commit()
        if hovered { buttons?.rootView = buttonsView() }

        let d = UserDefaults.standard
        let showTitle = d.object(forKey: "posterShowTitle") as? Bool ?? true
        let showYear = d.object(forKey: "posterShowYear") as? Bool ?? true
        let align: NSTextAlignment = (d.string(forKey: "posterLabelAlign") ?? "center") == "center" ? .center : .left
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Labels are drawn into pictures on another core (CATextLayer loses the chosen font)
        labelToken += 1
        let token = labelToken
        for (t, text, font, color, h) in [(nameLabel, item.Name, look.titleFont, NSColor.white, PosterLook.titleH),
                                          (year, item.yearText, look.yearFont,
                                           NSColor.white.withAlphaComponent(0.55), PosterLook.yearH)] {
            t.contentsScale = scale
            if let img = LabelPicture.cached(text, font, align, scale) { t.contents = img; continue }
            t.contents = nil
            LabelPicture.draw(text, font, color, align, CGSize(width: look.size.width, height: h), scale) { [weak self, weak t] img in
                guard let self, self.labelToken == token else { return }
                t?.contents = img
            }
        }
        nameLabel.isHidden = !showTitle; year.isHidden = !showYear
        CATransaction.commit()
        view.needsLayout = true

        let u = emby.image(item.posterId, width: 360)
        guard u != url else { return }
        url = u; load?.cancel()
        guard let u else { setPicture(nil); return }
        if let img = ImageCache.shared.cached(u) { setPicture(img); return }
        setPicture(BlurHash.preview(for: u))
        load = Task { [weak self] in
            guard let img = await ImageCache.shared.image(u), !Task.isCancelled, let self, self.url == u else { return }
            self.setPicture(img, fade: true)
        }
    }

    /// Zooms the poster in or out over 0.2 s; going the other way mid-way continues from where it is.
    func setHover(_ on: Bool, animated: Bool = true) {
        if on == hovered && animated { return }
        hovered = on
        view.layer?.zPosition = on ? 1 : 0   // over its neighbours while zoomed
        let zoom = on ? CATransform3DMakeScale(1.06, 1.06, 1) : CATransform3DIdentity
        let lit: Float = on ? 1 : 0
        if animated {
            let ease = CAMediaTimingFunction(name: .easeOut)
            let z = CABasicAnimation(keyPath: "transform")
            // As NSValue: a bare CATransform3D is ignored by Core Animation, and the zoom then jumped
            z.fromValue = NSValue(caTransform3D: card.presentation()?.transform ?? card.transform)
            z.toValue = NSValue(caTransform3D: zoom)
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = NSNumber(value: edgeLit.presentation()?.opacity ?? edgeLit.opacity); o.toValue = NSNumber(value: lit)
            for a in [z, o] { a.duration = 0.2; a.timingFunction = ease }
            let g = o.copy() as! CABasicAnimation
            g.fromValue = NSNumber(value: glow.presentation()?.opacity ?? glow.opacity)
            card.add(z, forKey: "zoom"); edgeLit.add(o, forKey: "lit"); glow.add(g, forKey: "lit")
        } else {
            card.removeAnimation(forKey: "zoom"); edgeLit.removeAnimation(forKey: "lit"); glow.removeAnimation(forKey: "lit")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        card.transform = zoom; edgeLit.opacity = lit; glow.opacity = lit
        CATransaction.commit()
        fadeButtons(on, animated: animated)
    }

    private func buttonsView() -> AnyView {
        guard let item, let emby else { return AnyView(EmptyView()) }
        return AnyView(ItemActionsButton(item: item).environmentObject(emby).environment(\.classicGlass, look.glass3D)
            .tint(Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red")).environment(\.colorScheme, .dark)
            .fixedSize())
    }

    private func fadeButtons(_ on: Bool, animated: Bool) {
        if on && buttons == nil {
            let b = NSHostingView(rootView: buttonsView())
            b.alphaValue = 0
            view.addSubview(b)
            buttons = b
        }
        guard let b = buttons else { return }
        if on { b.rootView = buttonsView(); b.isHidden = false; placeButtons() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.2 : 0
            b.animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self, weak b] in
            MainActor.assumeIsolated { if self?.hovered == false { b?.isHidden = true } }   // hidden: no clicks on it
        })
    }

    /// The buttons in the zoomed poster's bottom-right corner, 8 pt in (as on the SwiftUI card)
    private func placeButtons() {
        guard let b = buttons else { return }
        let s = b.fittingSize, ps = look.size, h = view.bounds.height
        let center = CGPoint(x: ps.width / 2, y: h - ps.height / 2)
        let corner = CGPoint(x: center.x + (ps.width / 2 - 8) * 1.06, y: center.y - (ps.height / 2 - 8) * 1.06)
        b.frame = CGRect(x: corner.x - s.width, y: corner.y, width: s.width, height: s.height)
    }

    /// A picture arriving later fades in (the layer's own implicit animation) and goes to the screen with the
    /// next frame, together with the others that arrived meanwhile: an explicit commit here sent each one
    /// to the window server on its own and made the main thread wait for it.
    private func setPicture(_ img: NSImage?, fade: Bool = false) {
        let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if fade { poster.contents = cg; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        poster.contents = cg
        CATransaction.commit()
    }
}

/// A poster's title or year drawn into a picture on a background queue, kept for when it scrolls by again.
enum LabelPicture {
    nonisolated(unsafe) private static let cache = NSCache<NSString, CGImage>()
    private static let queue = DispatchQueue(label: "cove.labels", qos: .userInitiated, attributes: .concurrent)

    private static func key(_ text: String, _ font: NSFont, _ align: NSTextAlignment, _ scale: CGFloat) -> NSString {
        "\(text)|\(font.fontName)|\(font.pointSize)|\(align.rawValue)|\(scale)" as NSString
    }

    static func cached(_ text: String, _ font: NSFont, _ align: NSTextAlignment, _ scale: CGFloat) -> CGImage? {
        cache.object(forKey: key(text, font, align, scale))
    }

    static func draw(_ text: String, _ font: NSFont, _ color: NSColor, _ align: NSTextAlignment, _ size: CGSize,
                     _ scale: CGFloat, done: @escaping @MainActor (CGImage?) -> Void) {
        let k = key(text, font, align, scale)
        queue.async {
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale)
            let p = NSMutableParagraphStyle()
            p.alignment = align; p.lineBreakMode = .byTruncatingTail
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
                .draw(with: CGRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
            let img = ctx.makeImage()
            if let img { cache.setObject(img, forKey: k) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(img) } }
        }
    }
}

/// Everything drawn over the poster picture, without the picture or the edge: watched badge, heart, your rating and
/// progress bar. Drawn once per look and shared by every poster.
struct PosterDecor: View {
    let item: Item
    let played: Bool
    let fav: Bool
    let progress: Int
    let accent: Color
    let look: PosterLook
    var body: some View {
        let s = look.size
        Color.clear.frame(width: s.width, height: s.height)
            .overlay(alignment: .topTrailing) { WatchBadge(item: item, played: played).padding(8) }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    if fav { FavHeart(size: 22) }
                    MyRatingBadge(item: item)
                }.padding(8)
            }
            .overlay(alignment: .bottom) {
                if progress > 0 { ProgressView(value: Double(progress) / 100).padding(.horizontal, 8).padding(.bottom, 8) }
            }
            .tint(accent)
    }

    /// The edge, at rest or lit (Glass3D: the light glass edge; Glass: a thin border, the same both ways)
    struct Edge: ViewModifier {
        let look: PosterLook
        let lit: Bool
        func body(content: Content) -> some View {
            if look.glass3D { content.modifier(ClassicLightCard(radius: look.radius, hover: lit, size: look.size, glow: false)) }
            else { content.thinBorder(look.radius) }
        }
    }
}

/// Set by the AppKit grid on its header: opens any page (see PageLink).
private struct PagePushKey: EnvironmentKey { static let defaultValue: ((any Hashable) -> Void)? = nil }
extension EnvironmentValues {
    var pagePush: ((any Hashable) -> Void)? {
        get { self[PagePushKey.self] }
        set { self[PagePushKey.self] = newValue }
    }
}

/// A NavigationLink that also works in the AppKit grid's header, through `pagePush`.
struct PageLink<V: Hashable, Label: View>: View {
    let value: V
    @ViewBuilder let label: () -> Label
    @Environment(\.pagePush) private var push
    var body: some View {
        if let push { Button { push(value) } label: { label() } }
        else { NavigationLink(value: value) { label() } }
    }
}
