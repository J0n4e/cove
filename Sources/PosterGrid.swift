import AppKit
import Combine
import SwiftUI

/// Library poster grid on NSCollectionView (Glass3D). LazyVGrid rebuilds a full SwiftUI card for every poster that
/// scrolls in; here cells are reused and drawn natively: the poster picture, one picture of its badges and glass edge
/// (drawn once per look, see Raster), and two text labels. Only the poster under the pointer becomes the real SwiftUI
/// card, laid over the grid, so hover lift, glow and the action button look as before.
/// On with `defaults write eu.jonae.cove appkitGrid -bool YES`.
struct PosterGrid: NSViewRepresentable {
    let emby: Emby
    let items: [Item]
    var insets = NSEdgeInsets(top: 0, left: 40, bottom: 24, right: 92)
    /// Called when the item at this index is about to show (for paging).
    var willShow: (Int) -> Void = { _ in }
    let open: (Item) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        let cv = PosterCollectionView()
        cv.collectionViewLayout = layout
        cv.backgroundColors = [.clear]
        cv.isSelectable = false
        cv.register(PosterGridCell.self, forItemWithIdentifier: PosterGridCell.id)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.coordinator = context.coordinator
        cv.autoresizingMask = [.width]   // follow the window width (columns re-flow)
        let sv = NSScrollView()
        sv.documentView = cv
        sv.drawsBackground = false
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
        c.insets = insets
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
        private var watchers: [AnyCancellable] = []
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
            let labelH: CGFloat = (showTitle || showYear) ? 6 + (showTitle ? 16 : 0) + (showYear ? 13 : 0) : 0
            guard let layout = cv?.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let size = CGSize(width: 150, height: 225 + labelH)
            if layout.itemSize != size { layout.itemSize = size }
            if !NSEdgeInsetsEqual(layout.sectionInset, insets) { layout.sectionInset = insets }
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
            if let emby { cell.show(items[ip.item], emby: emby, scale: scale) }
            return cell
        }

        func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt ip: IndexPath) { willShow(ip.item) }

        /// The hover card is left alone: it follows the same state itself, and rebuilding it flashed its glow.
        func refreshVisible() {
            guard let cv, let emby else { return }
            for ip in cv.indexPathsForVisibleItems() where ip.item < items.count {
                (cv.item(at: ip) as? PosterGridCell)?.show(items[ip.item], emby: emby, scale: scale)
            }
        }

        /// The card would stay behind while posters slide under it. Only a real scroll: the bounds also change
        /// when the next page of posters loads, and dropping the card then made it flash.
        @objc func scrolled() { if ScrollActivity.scrolling { hover(nil) } }

        /// Lays the SwiftUI card over poster `i` (nil: removes it). The card comes in at rest and zooms up, and
        /// zooms back down before it goes, as the hover on the SwiftUI grid.
        func hover(_ i: Int?) {
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
            let card = GridHoverCard(lit: lit, item: items[i])
                .environment(\.posterOpen, open)
                .environment(\.classicGlass, true)
                .environmentObject(emby)
                .tint(Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red"))
                .environment(\.colorScheme, .dark)
                .padding(pad)
            let h = NSHostingView(rootView: AnyView(card.frame(width: frame.width + 2 * pad, height: frame.height + 2 * pad, alignment: .top)))
            h.sizingOptions = []
            h.frame = frame.insetBy(dx: -pad, dy: -pad)
            cv.addSubview(h)   // above every cell
            cv.item(at: IndexPath(item: i, section: 0))?.view.isHidden = true
            hoverHost = h; hoverLit = lit
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { lit.on = true } }
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
    var body: some View { ClassicPosterCard(item: item, forcedHover: lit.on) }
}

/// Follows the pointer to show the hover card; a click on a poster opens it.
final class PosterCollectionView: NSCollectionView {
    weak var coordinator: PosterGrid.Coordinator?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        guard !ScrollActivity.scrolling else { return }
        coordinator?.hover(coordinator?.item(at: convert(e.locationInWindow, from: nil)))
    }

    override func mouseExited(with e: NSEvent) {
        super.mouseExited(with: e)
        coordinator?.hover(nil)
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

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        poster.frame = CGRect(x: 0, y: 0, width: 150, height: 225)
        poster.cornerRadius = 8
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
        let h = view.bounds.height
        poster.frame = CGRect(x: 0, y: h - 225, width: 150, height: 225)
        decor.frame = poster.frame
        var y = h - 225 - 6
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !nameLabel.isHidden { y -= 16; nameLabel.frame = CGRect(x: 0, y: y, width: 150, height: 16) }
        if !year.isHidden { y -= 13; year.frame = CGRect(x: 0, y: y, width: 150, height: 13) }
        CATransaction.commit()
    }

    @MainActor func show(_ item: Item, emby: Emby, scale: CGFloat) {
        let played = emby.isPlayed(item)
        let fav = emby.isFav(item)
        let rating = Trakt.shared.rating(item)
        let pct = item.UserData?.PlayedPercentage.map { Int($0) } ?? 0
        let progress = (pct > 0 && pct < 100 && !played) ? pct : 0
        let accent = UserDefaults.standard.string(forKey: "accent") ?? "red"
        let unwatched = item.isSeries && !played ? (item.UserData?.UnplayedItemCount ?? 0) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        poster.opacity = played ? 0.6 : 1
        let key = "gridDecor|\(played)|\(unwatched)|\(fav)|\(rating ?? 0)|\(progress)|\(accent)"
        decor.contents = Raster.image(key, scale: scale, pad: 0) {
            PosterDecor(item: item, played: played, fav: fav, progress: progress, accent: Theme.accent(accent))
                .environmentObject(emby).environment(\.classicGlass, true)
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
        for (t, text, font, color, h) in [(nameLabel, item.Name, ClassicFont.nsFont(12, .semibold), NSColor.white, CGFloat(16)),
                                          (year, item.yearText, ClassicFont.nsFont(10, .regular),
                                           NSColor.white.withAlphaComponent(0.55), CGFloat(13))] {
            t.contentsScale = scale
            if let img = LabelPicture.cached(text, font, align, scale) { t.contents = img; continue }
            t.contents = nil
            LabelPicture.draw(text, font, color, align, CGSize(width: 150, height: h), scale) { [weak self, weak t] img in
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

/// Everything drawn over the poster picture in the Glass3D card, without the picture: watched badge, heart,
/// your rating, progress bar and the light glass edge. Drawn once per look and shared by every poster.
private struct PosterDecor: View {
    let item: Item
    let played: Bool
    let fav: Bool
    let progress: Int
    let accent: Color
    var body: some View {
        Color.clear.frame(width: 150, height: 225)
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
            .modifier(ClassicLightCard(radius: 8, accent: accent, size: CGSize(width: 150, height: 225)))
            .tint(accent)
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
