import AppKit
import SwiftUI

/// SPIKE: library poster grid on NSCollectionView, so cells are reused while scrolling instead of rebuilt
/// (LazyVGrid rebuilds them). Each cell hosts the SwiftUI card in one NSHostingView that is kept and re-fed.
/// Turned on with `defaults write eu.jonae.cove appkitGrid -bool YES`. Clicks don't navigate yet.
struct PosterGrid<Card: View>: NSViewRepresentable {
    let emby: Emby
    let items: [Item]
    var itemSize = CGSize(width: 150, height: 244)
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 18
    var insets = NSEdgeInsets(top: 0, left: 40, bottom: 24, right: 92)
    /// Called when the item at this index is about to show (for paging).
    var willShow: (Int) -> Void = { _ in }
    @ViewBuilder let card: (Item) -> Card

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        let cv = NSCollectionView()
        cv.collectionViewLayout = layout
        cv.backgroundColors = [.clear]
        cv.isSelectable = false
        cv.register(PosterGridCell.self, forItemWithIdentifier: PosterGridCell.id)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        let sv = NSScrollView()
        sv.documentView = cv
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
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
        if let layout = c.cv?.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = itemSize
            layout.minimumInteritemSpacing = spacing
            layout.minimumLineSpacing = lineSpacing
            layout.sectionInset = insets
        }
        c.willShow = willShow
        // Wrap once per update: the environment a hosted view needs doesn't cross into its own NSHostingView
        let env = context.environment, emby = self.emby
        c.make = { AnyView(card($0).environmentObject(emby).tint(env.tint).environment(\.colorScheme, env.colorScheme)) }
        let ids = items.map(\.id)
        if ids != c.ids {
            c.items = items; c.ids = ids
            c.cv?.reloadData()
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var cv: NSCollectionView?
        var items: [Item] = []
        var ids: [String] = []
        var willShow: (Int) -> Void = { _ in }
        var make: (Item) -> AnyView = { _ in AnyView(EmptyView()) }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: PosterGridCell.id, for: ip) as! PosterGridCell
            cell.show(make(items[ip.item]))
            return cell
        }

        func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt ip: IndexPath) { willShow(ip.item) }
    }
}

final class PosterGridCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PosterGridCell")
    private var host: NSHostingView<AnyView>?

    override func loadView() { view = NSView() }

    func show(_ content: AnyView) {
        if let host { host.rootView = content; return }
        let h = NSHostingView(rootView: content)
        h.sizingOptions = []   // the cell sets the size; no Auto Layout constraints from SwiftUI
        h.frame = view.bounds
        h.autoresizingMask = [.width, .height]
        view.addSubview(h)
        host = h
    }
}

private extension EnvironmentValues {
    var tint: Color { Theme.accent(UserDefaults.standard.string(forKey: "accent") ?? "red") }
}
