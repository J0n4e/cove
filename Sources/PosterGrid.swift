import AppKit
import Combine
import SwiftUI

/// Library poster grid on NSCollectionView (both themes, see PosterLook). LazyVGrid rebuilds a full SwiftUI card for every poster that
/// scrolls in; here cells are reused and drawn natively: the poster picture, one picture of its badges and glass edge
/// (drawn once per look, see Raster), and two text labels. Only the poster under the pointer becomes the real SwiftUI
/// card, laid over the grid, so hover lift, glow and the action button look as before.
/// How the posters of one theme look: size, corners, label fonts, badges and hover card.
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
                cv.addSubview(h.view, positioned: .below, relativeTo: nil)   // under the cells and the hover card
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
        /// The real SwiftUI card over the poster under the pointer
        private var hoverHost: NSHostingView<AnyView>?
        private var hoverIndex: Int?
        private var hoverLit: GridHoverLit?

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: PosterGridCell.id, for: ip) as! PosterGridCell
            cell.view.isHidden = ip.item == hoverIndex
            if let emby { cell.show(items[ip.item], emby: emby, look: look, noHeart: inFavorites, scale: scale) }
            return cell
        }

        func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt ip: IndexPath) { willShow(ip.item) }

        /// The hover card is left alone: it follows the same state itself, and rebuilding it flashed its glow.
        func refreshVisible() {
            guard let cv, let emby else { return }
            for ip in cv.indexPathsForVisibleItems() where ip.item < items.count {
                (cv.item(at: ip) as? PosterGridCell)?.show(items[ip.item], emby: emby, look: look, noHeart: inFavorites, scale: scale)
            }
        }

        /// The card would stay behind while posters slide under it. Only a real scroll: the bounds also change
        /// when the next page of posters loads, and dropping the card then made it flash.
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
            pending?.cancel(); pending = nil
            if i != hoverIndex { show(nil); show(i) }
            if i != nil { NSCursor.pointingHand.set() }
        }

        /// Lays the SwiftUI card over poster `i` (nil: removes it). The card comes in at rest and zooms up, and
        /// zooms back down before it goes, as the hover on the SwiftUI grid.
        /// The pointer is over poster `i` (nil: none). The card under it goes at once; a new one comes only after
        /// the pointer has rested 50 ms, so a fast sweep across the grid doesn't light every poster it crosses.
        func hover(_ i: Int?) {
            pending?.cancel(); pending = nil
            guard i != hoverIndex else { return }
            show(nil)
            guard let i else { return }
            let w = DispatchWorkItem { [weak self] in self?.show(i) }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
        }
        private var pending: DispatchWorkItem?

        private func show(_ i: Int?) {
            guard i != hoverIndex else { return }
            if let old = hoverIndex, let host = hoverHost, let lit = hoverLit {
                withAnimation(.easeOut(duration: 0.2)) { lit.on = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    host.removeFromSuperview()
                    // The card covered the poster (both would draw the labels): show it again, unless lit again meanwhile
                    if self?.hoverIndex != old { self?.cv?.item(at: IndexPath(item: old, section: 0))?.view.isHidden = false }
                }
            }
            hoverIndex = i
            hoverHost = nil; hoverLit = nil
            guard let i, i < items.count, let cv, let emby,
                  let frame = cv.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame else { return }
            let pad: CGFloat = 24   // room for the lift and the glow around the card
            let lit = GridHoverLit()
            let open: (Item) -> Void = { [weak self] in self?.hover(nil); self?.open($0) }
            let card = GridHoverCard(lit: lit, item: items[i], glass3D: look.glass3D)
                .environment(\.posterOpen, open)
                .environment(\.inFavorites, inFavorites)
                .environment(\.classicGlass, look.glass3D)
                .environmentObject(emby)
                .tint(Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red"))
                .environment(\.colorScheme, .dark)
                .padding(pad)
            let h = NSHostingView(rootView: AnyView(card.frame(width: frame.width + 2 * pad, height: frame.height + 2 * pad, alignment: .top)))
            h.sizingOptions = []
            h.frame = frame.insetBy(dx: -pad, dy: -pad)
            cv.addSubview(h)   // above every cell
            h.layoutSubtreeIfNeeded()   // the card draws now, in this frame
            hoverHost = h; hoverLit = lit
            DispatchQueue.main.async { [weak self] in
                // The poster under it hides only now that the card is on screen: hiding it in the same frame
                // left the spot empty for a frame (a flash when moving fast)
                if self?.hoverIndex == i { cv.item(at: IndexPath(item: i, section: 0))?.view.isHidden = true }
                withAnimation(.easeOut(duration: 0.2)) { lit.on = true }
            }
        }

        func item(at p: NSPoint) -> Int? {
            // From the layout, not the views: indexPathForItem(at:) hit-tests, and finds the hover card on top
            let hit = cv?.collectionViewLayout?.layoutAttributesForElements(in: NSRect(origin: p, size: NSSize(width: 1, height: 1)))
                .first { $0.representedElementCategory == .item && $0.frame.contains(p) }
            guard let i = hit?.indexPath?.item, i < items.count else { return nil }
            return i
        }
    }
}

/// Whether the grid's hover card is lit; changed with animation so it zooms in and out.
final class GridHoverLit: ObservableObject { @Published var on = false }

private struct GridHoverCard: View {
    @ObservedObject var lit: GridHoverLit
    let item: Item
    let glass3D: Bool
    var body: some View {
        if glass3D { ClassicPosterCard(item: item, forcedHover: lit.on) }
        else { PosterCard(item: item, forcedHover: lit.on) }
    }
}

/// Follows the pointer to show the hover card; a click on a poster opens it.
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

    /// AppKit also sends this when views are added over the grid (the hover card) while the pointer stays put:
    /// only a pointer really outside the grid takes the card away, or every card flickered as it appeared
    override func mouseExited(with e: NSEvent) {
        super.mouseExited(with: e)
        if !visibleRect.contains(convert(e.locationInWindow, from: nil)) { coordinator?.hover(nil) }
    }

    /// The hand pointer over a poster (anywhere on it, not only where the card's own button is)
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

    /// Leaving the page (a movie opened over it): no card left lit for when it comes back
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

/// One poster drawn with layers: picture, badges-and-edge picture, title and year.
final class PosterGridCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PosterGridCell")
    private let poster = CALayer()
    private let decor = CALayer()
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
        decor.frame = poster.frame
        v.layer?.addSublayer(poster)
        v.layer?.addSublayer(decor)
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
        poster.frame = CGRect(x: 0, y: h - ps.height, width: ps.width, height: ps.height)
        decor.frame = poster.frame
        var y = h - ps.height - 6
        if !nameLabel.isHidden { y -= PosterLook.titleH; nameLabel.frame = CGRect(x: 0, y: y, width: ps.width, height: PosterLook.titleH) }
        if !year.isHidden { y -= PosterLook.yearH; year.frame = CGRect(x: 0, y: y, width: ps.width, height: PosterLook.yearH) }
        CATransaction.commit()
    }

    @MainActor func show(_ item: Item, emby: Emby, look: PosterLook, noHeart: Bool, scale: CGFloat) {
        if look != self.look { self.look = look; view.needsLayout = true }
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
        decor.contentsScale = scale
        poster.contentsScale = scale
        CATransaction.commit()

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

/// Everything drawn over the poster picture, without the picture: watched badge, heart, your rating, progress bar
/// and the edge (Glass3D: the light glass edge; Glass: a thin border). Drawn once per look and shared by every poster.
private struct PosterDecor: View {
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
            .modifier(Edge(look: look, accent: accent))
            .tint(accent)
    }

    struct Edge: ViewModifier {
        let look: PosterLook
        let accent: Color
        func body(content: Content) -> some View {
            if look.glass3D { content.modifier(ClassicLightCard(radius: look.radius, accent: accent, size: look.size)) }
            else { content.thinBorder(look.radius) }
        }
    }
}

/// Set by the AppKit grid: its hover card opens the item through this instead of a NavigationLink, which
/// can't reach the NavigationStack from its own hosting view.
private struct PosterOpenKey: EnvironmentKey { static let defaultValue: ((Item) -> Void)? = nil }
extension EnvironmentValues {
    var posterOpen: ((Item) -> Void)? {
        get { self[PosterOpenKey.self] }
        set { self[PosterOpenKey.self] = newValue }
    }
}

/// Set by the AppKit grid on its header: opens any page, as `posterOpen` does for posters (see PageLink).
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

/// A NavigationLink, or a plain button calling `open` when one is given (see posterOpen).
struct OpenLink<Label: View>: View {
    let item: Item
    let open: ((Item) -> Void)?
    @ViewBuilder let label: () -> Label
    var body: some View {
        if let open { Button { open(item) } label: { label() } }
        else { NavigationLink(value: item) { label() } }
    }
}
