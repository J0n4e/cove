import AppKit
import SwiftUI

/// The admin ⋯ button at the end of a detail page's button row (after ★). Admins only; others see nothing.
/// Opens the glass list: Refresh metadata…, Identify… (movies/shows), Edit images…, Open in web dashboard.
struct ItemAdminButton: View {
    let item: Item
    /// Called after a change, so the page reloads (new pictures, new metadata).
    var onChange: () -> Void = {}
    @EnvironmentObject var emby: Emby
    @ObservedObject private var profile = ProfileModel.shared

    var body: some View {
        let actions = ItemAdminAPI.detailMenu(type: item.`Type`, admin: profile.admin)
        if !actions.isEmpty {
            GlassListButton(list: {
                (["Admin"] + actions.map(\.title), [], [0], { i in
                    guard i >= 1, i <= actions.count else { return }
                    ItemAdminWindows.run(actions[i - 1], item: item, emby: emby, onChange: onChange)
                })
            }) {
                Label("Admin", systemImage: "ellipsis").labelStyle(.iconOnly)
                    .classicGlassPill(size: 44).glass3DRoundOutline()
            }
            .helpLabel("Admin tools")
            .padding(.leading, 4)
        }
    }
}

/// The admin ⋯ button at the top right of a library page: Items without poster / backdrop.
struct ItemAdminLibraryButton: View {
    let lib: LibPref
    @EnvironmentObject var emby: Emby
    @ObservedObject private var profile = ProfileModel.shared

    var body: some View {
        let actions = ItemAdminAPI.libraryMenu(kind: lib.kind, admin: profile.admin)
        if !actions.isEmpty {
            GlassListButton(list: {
                (["Admin"] + actions.map(\.title), [], [0], { i in
                    guard i >= 1, i <= actions.count else { return }
                    ItemAdminWindows.missing(actions[i - 1] == .missingPosters ? .poster : .backdrop, lib: lib, emby: emby)
                })
            }) {
                Label("Admin", systemImage: "ellipsis").labelStyle(.iconOnly)
                    .classicGlassPill(size: 44).glass3DRoundOutline()
            }
            .helpLabel("Admin tools")
        }
    }
}

/// The admin tools' glass windows (same look as Settings / Change picture: fixed size, Esc and ⌘W close).
@MainActor
enum ItemAdminWindows {
    private static var windows: [String: NSWindow] = [:]

    static func show<V: View>(_ id: String, title: String, size: NSSize, emby: Emby, _ view: V) {
        windows[id]?.close()
        let accent = UserDefaults.standard.string(forKey: "accent") ?? "red"
        let host = NSHostingView(rootView: view.environmentObject(emby).tint(Theme.accent(accent))
            .preferredColorScheme(.dark).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        CoveWindowLook.applyGlass(w, content: host, size: size)
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) { windows[id]?.close() }

    static func run(_ a: ItemAdminAPI.Action, item: Item, emby: Emby, onChange: @escaping () -> Void) {
        switch a {
        case .refresh: refresh(item, emby: emby, onChange: onChange)
        case .identify: identify(item, emby: emby, onChange: onChange)
        case .images: images(item, emby: emby, onChange: onChange)
        case .web: ItemAdminService.openWeb(item.id, emby: emby)
        case .missingPosters, .missingBackdrops: break
        }
    }

    static func refresh(_ item: Item, emby: Emby, onChange: @escaping () -> Void = {}) {
        let id = "admin-refresh-" + item.id
        show(id, title: "Refresh Metadata", size: NSSize(width: 480, height: 470), emby: emby,
             ItemRefreshView(item: item, close: { close(id) }, onChange: onChange))
    }

    static func identify(_ item: Item, emby: Emby, onChange: @escaping () -> Void = {}) {
        let id = "admin-identify-" + item.id
        show(id, title: "Identify", size: NSSize(width: 660, height: 640), emby: emby,
             ItemIdentifyView(item: item, close: { close(id) }, onChange: onChange))
    }

    static func images(_ item: Item, emby: Emby, onChange: @escaping () -> Void = {}) {
        let id = "admin-images-" + item.id
        show(id, title: "Edit Images", size: NSSize(width: 780, height: 660), emby: emby,
             ItemImagesView(item: item, onChange: onChange))
    }

    static func missing(_ kind: ItemAdminAPI.Missing, lib: LibPref, emby: Emby) {
        show("admin-missing-" + kind.rawValue + lib.id, title: kind.title, size: NSSize(width: 760, height: 640), emby: emby,
             ItemMissingView(kind: kind, lib: lib))
    }
}

// MARK: - Shared pieces

/// Title + optional grey line at the top of an admin window (under the transparent title bar).
struct ItemAdminHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).cvFont(18, weight: .bold).glassReadable()
            if let subtitle { Text(subtitle).cvFont(12).foregroundColor(.white.opacity(0.7)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 34)
    }
}

/// A picture from the server (with Cove's image auth) or from a provider's link, loaded through the image cache.
struct ItemAdminThumb: View {
    let url: URL?
    var placeholder = "photo"
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb).fill(Color.white.opacity(Glass3DTokens.Fill.subtle))
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: placeholder).cvFont(18).foregroundColor(.white.opacity(0.35)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ImageCache.shared.image(url)
        }
    }
}

/// A dark glass card used by the admin windows' sections and rows.
struct ItemAdminCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12)
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card).fill(Color.white.opacity(Glass3DTokens.Fill.subtle)))
            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card).stroke(Color.white.opacity(Glass3DTokens.Stroke.subtle)))
    }
}
extension View { func itemAdminCard() -> some View { modifier(ItemAdminCard()) } }
