import IOKit.pwr_mgt
import SwiftUI
import AVKit

struct ClassicRootView: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("classicFont") private var classicFont = "rounded"   // Settings → General → Font
    @Environment(\.appBG) var bg
    var body: some View {
        ZStack {
            // Hide (but keep) the screen under the player: AppKit controls such as spinners
            // otherwise draw on top of the video.
            Group { if emby.loggedIn { ClassicHomeView() } else { ClassicLoginView() } }
                .opacity(emby.playing == nil ? 1 : 0)
                .allowsHitTesting(emby.playing == nil)
            if let req = emby.playing {
                ChosenPlayerView(req: req, theme: "classic").id(req.id).zIndex(10)
            }
        }
        .onChange(of: emby.playing?.id) { _, id in
            PlaybackFlag.shared.active = id != nil
        }
        .dropdownLayer()   // glass lists for audio, subtitles, quality
        .tipLayer()   // inside the settings below, so the tooltips get the Classic look and font too
        .environment(\.classicGlass, true)
        // Text that does not name a font follows the chosen one's design; a new font rebuilds the screens so every
        // text picks it up
        .fontDesign(classicFont == "rounded" ? .rounded : classicFont == "serif" ? .serif : .default)
        .id(classicFont)
        // No scroll bars popping up over the pages (scroll with the wheel, trackpad or the row arrows)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Sidebar shell + search

struct ClassicHomeView: View {
    @AppStorage("accent") private var accentName = "red"
    @State private var keepPage = false   // the search box is being cleared after opening a result
    @State private var fromSearch = false // the first page on the stack was opened from search results
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @State private var searchKey: Any?
    // Shared with the title bar (Top bar layout puts the navigation buttons in the window's toolbar)
    @ObservedObject private var nav = ClassicNavState.shared
    var sel: String { get { nav.sel } nonmutating set { nav.sel = newValue } }
    var query: String { get { nav.query } nonmutating set { nav.query = newValue } }
    var activeCount: Int { nav.activeCount }
    var selB: Binding<String> { Binding(get: { nav.sel }, set: { nav.sel = $0 }) }
    var queryB: Binding<String> { Binding(get: { nav.query }, set: { nav.query = $0 }) }
    var showSettingsB: Binding<Bool> { Binding(get: { nav.showSettings }, set: { nav.showSettings = $0 }) }
    @State private var path = NavigationPath()
    @State private var titleBarH: CGFloat = 0
    @State private var reloadToken = 0
    @AppStorage("navStyle") private var navStyle = "sidebar"   // Settings → General → Appearance: "sidebar" or "topbar"
    @AppStorage(NavOrder.key) private var navOrder = ""

    func icon(_ lib: LibPref) -> String {
        switch lib.kind {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "boxsets": return "square.stack"
        case "music": return "music.note"
        case "homevideos": return "video"
        default: return "folder"
        }
    }

    /// Clicking the sidebar item you are already on (e.g. Movies while browsing actors and titles) goes back
    /// to that page's start. Picking a different item does the same through the onChange below.
    func popToRoot() {
        nav.reselect += 1
        path = NavigationPath()
        query = ""
    }

    /// Keeps `titleBarH` equal to the window's title bar height (0 in full screen).
    func updateTitleBarH() {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow, !w.styleMask.contains(.fullScreen) else { titleBarH = 0; return }
        let h = max(0, w.frame.height - w.contentLayoutRect.height)
        if abs(h - titleBarH) > 0.5 { titleBarH = h }
    }

    /// Favorites or Now Playing in the sidebar, wherever Settings → Libraries placed it.
    @ViewBuilder func sideSection(_ id: String) -> some View {
        if id == NavOrder.favorites { sideRow("Favorites", "heart.fill", "favorites") }
        else if id == NavOrder.nowPlaying { sideRow("Now Playing", "dot.radiowaves.left.and.right", "nowplaying", badge: activeCount) }
    }

    /// One sidebar line: the chosen one on an accent glass band, the one under the pointer lit softly (as the glass
    /// lists). Clicking the chosen one again goes back to that page's start.
    func sideRow(_ title: String, _ icon: String, _ id: String, badge: Int = 0) -> some View {
        let on = sel == id
        return Button { if on { popToRoot() } else { selB.wrappedValue = id } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).cvFont(13).frame(width: 18).foregroundStyle(.tint)
                Text(title).cvFont(13, weight: on ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 { Text("\(badge)").cvFont(11, weight: .semibold).foregroundColor(.secondary) }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).frame(height: 32)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent(accentName).opacity(0.4))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle(glass: !on))
    }

    var splitLayout: some View {
        NavigationSplitView {
            // Glass rows instead of the macOS list (its selection is always the system's blue)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sideRow("Home", "house.fill", "home")
                    let rows = NavOrder.rows(navOrder, libIds: emby.libs.map(\.id))
                    ForEach(NavOrder.top(rows), id: \.self) { sideSection($0) }
                    Text("MY MEDIA").cvFont(10, weight: .semibold).kerning(0.6).foregroundColor(.secondary)
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                    ForEach(emby.libs) { lib in
                        if lib.visible { sideRow(lib.title, icon(lib), lib.id) }
                        ForEach(NavOrder.after(lib.id, rows), id: \.self) { sideSection($0) }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 280)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    Button { emby.switchServer() } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(emby.currentServerName).cvFont(12, weight: .semibold).lineLimit(1)
                                Text(emby.currentServer?.user.isEmpty == false ? emby.currentServer!.user : (URL(string: emby.server)?.host ?? ""))
                                    .cvFont(10, weight: .regular).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down").cvFont(10, weight: .regular).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHand)
                    .helpLabel("Connected to \(emby.server) — click to switch server")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { nav.showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape").cvFont(12, weight: .medium)
                            .padding(.horizontal, 14).frame(height: 32).classicGlassPill()
                    }
                    .helpLabel("Settings (⌘,)").keyboardShortcut(",", modifiers: .command)
                    Spacer()
                }.buttonStyle(.plainHand).padding(10)
            }
            // Sidebar in the chosen background color instead of the system gray. The color stops below the
            // title bar, so the strip behind the window buttons keeps the same gray as the rest of the title bar.
            .scrollContentBackground(.hidden)
            .background(bg, ignoresSafeAreaEdges: [])
            // Strip behind the window buttons in exactly the gray of the rest of the title bar
            .overlay(alignment: .top) {
                Color(red: 41 / 255, green: 42 / 255, blue: 42 / 255)
                    .frame(height: titleBarH).offset(y: -titleBarH).allowsHitTesting(false)
            }
        } detail: {
            detailPane(withSearch: true)
        }
    }

    /// The page area (search results, home, libraries, detail pages) shared by both navigation styles.
    func detailPane(withSearch: Bool) -> some View {
        VStack(spacing: 0) {
            if withSearch { ClassicSearchBar(query: queryB) }
            NavigationStack(path: $path) {
                Group {
                    if !query.isEmpty { ClassicSearchView(query: query) }
                    else if sel == "home" { ClassicHomeContent(reloadToken: reloadToken) }
                    else if sel == "favorites" { ClassicFavoritesView() }
                    else if sel == "nowplaying" { NowPlayingView() }
                    else if let lib = emby.libs.first(where: { $0.id == sel }) { ClassicLibraryView(lib: lib, refresh: nav.reselect).id(lib.id) }
                    else { Color.black }
                }
                .modifier(NoTopScrollEdge())
                // A page opened from search results is the only page: no Back (deeper pages get one)
                .navigationDestination(for: Item.self) { ClassicDetailView(item: $0).environment(\.noBack, fromSearch && path.count == 1) }
                .navigationDestination(for: PersonRef.self) { ClassicPersonView(person: $0).environment(\.noBack, fromSearch && path.count == 1) }
                .navigationDestination(for: FavoriteGridRef.self) { ClassicFavoriteGridView(title: $0.title, ids: $0.ids) }
                .navigationDestination(for: FavoritePeopleRef.self) { _ in ClassicFavoritePeopleView() }
            }
            // Back button in the title bar, left of the window title, on every page
            .toolbar { ClassicTitleBarItems(back: nil) }   // top-level pages: no Back (pushed pages add their own)
            .classicHideToolbarTitle()
            .toolbarBackground(.hidden, for: .windowToolbar)   // no separator line when pages scroll
        }
    }

    // MARK: Top bar navigation (Settings → General → Appearance → Navigation)

    /// Top bar layout: a navigation row under the title bar (see ClassicTopNavBar), with the page area below it.
    var topLayout: some View {
        // Both the bar and the page are held to the window's width: a page that grew wider than the window
        // (e.g. Favorites) made the bar wider too, pushing its pill off screen where it couldn't be clicked.
        GeometryReader { geo in
            // The bar is see-through and floats over the page: pages start below it and scroll up under it.
            // Back sits in the bar on pushed pages.
            detailPane(withSearch: false)
                .frame(width: geo.size.width)
                .modifier(NoTopScrollEdge())   // no dark edge line where the bar ends
                .safeAreaInset(edge: .top, spacing: 0) {
                    ClassicTopNavBar(back: path.isEmpty || (fromSearch && path.count == 1) ? nil : { path.removeLast() })   // no Back on a search result
                        .frame(width: geo.size.width)
                }
                .clipped()
        }.background(bg)
    }

    /// ⌘← : one page back, like the Back button (none on a page opened from search)
    func goBack() {
        if !path.isEmpty && !(fromSearch && path.count == 1) { path.removeLast() }
    }

    /// H key: Home, from any page (search closed, pages on top of it closed)
    func goHome() {
        query = ""; nav.searchOpen = false
        path = NavigationPath()
        sel = "home"
    }

    var body: some View {
        Group {
            if navStyle == "topbar" { topLayout } else { splitLayout }
        }
        .task { await emby.loadLibs() }
        .onAppear {
            updateTitleBarH(); nav.popToRoot = { path = NavigationPath(); nav.query = "" }
            nav.open = { path.append($0) }
            nav.push = { path.append($0) }
        }
        .onAppear {
            if searchKey == nil {
                searchKey = SearchKey.install(isPlaying: { PlaybackFlag.shared.active },
                                              focus: { ClassicNavState.shared.focusSearch += 1 },
                                              home: { goHome() },
                                              back: { goBack() },
                                              banner: { d in
                                                  guard sel == "home" && path.isEmpty && query.isEmpty else { return false }
                                                  nav.bannerNudge = .init(dir: d); return true
                                              })
            }
        }
        // Switching theme replaces this view: its S key must not stay behind
        .onDisappear { if let m = searchKey { NSEvent.removeMonitor(m); searchKey = nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in updateTitleBarH() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in updateTitleBarH() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in titleBarH = 0 }
        .task {
            // Keep the sidebar's Now Playing count fresh
            while !Task.isCancelled {
                nav.activeCount = await emby.nowPlaying().count
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: sel) { path = NavigationPath(); query = "" }
        // Typing a search on a page opened from results (an actor, a movie) goes back to the results
        .onChange(of: query) {
            if keepPage { keepPage = false; return }
            if !path.isEmpty { path = NavigationPath() }
        }
        // Opening a search result clears the search box and stays on the opened page
        .onChange(of: path.count) { old, new in
            if old == 0 && new > 0 && !query.isEmpty {
                keepPage = true; query = ""; nav.searchOpen = false; fromSearch = true
            }
            if new == 0 { fromSearch = false }
        }
        .onChange(of: sel) { fromSearch = false }
        .onChange(of: emby.openRequest) { _, item in
            guard let item else { return }
            path.append(item)
            emby.openRequest = nil
        }
        // Settings always use the Glass window, whichever theme is chosen
        // Settings open in their own window (traffic lights, no Done); closing it reloads the pages
        .onChange(of: nav.showSettings) { _, on in
            guard on else { return }
            nav.showSettings = false
            SettingsWindow.show(emby: emby) { reloadToken += 1 }
        }
        .overlay {
            if navStyle == "topbar" {
                SearchDock(query: queryB, open: Binding(get: { nav.searchOpen }, set: { nav.searchOpen = $0 }),
                           focusTick: nav.focusSearch)
            }
        }
        .overlay { ToastOverlay(raised: navStyle == "topbar" && nav.searchOpen) }
    }
}

/// Back button for the bar above top-level pages. Light fill and outline so it shows on every background color
/// (the dark classicPill used over video disappears on a black background).
/// Title bar contents: just the optional Back button on the left (no app name).
/// State shared between the page area and the title bar's navigation buttons.
final class ClassicNavState: ObservableObject {
    static let shared = ClassicNavState()
    @Published var sel = "home"
    /// Bumped when the page already shown is clicked again (sidebar or top bar); the library reloads on it.
    @Published var reselect = 0
    @Published var query = ""
    @Published var searchOpen = false
    /// Goes up to put the cursor in the search field (the S key)
    @Published var focusSearch = 0
    @Published var bannerNudge: NavState.Nudge?   // ← → on Home
    @Published var activeCount = 0
    @Published var showSettings = false
    var popToRoot: () -> Void = {}
    /// Pushes an item's page (for views outside SwiftUI navigation, as the AppKit poster grid)
    var open: (Item) -> Void = { _ in }
    /// Pushes any page (a person, from the AppKit grid's header)
    var push: (any Hashable) -> Void = { _ in }
}

/// Window toolbar contents: the Back classicPill on pushed pages. (In the Top bar layout the navigation and Back
/// sit in their own row under the title bar, see ClassicTopNavBar.)
struct ClassicTitleBarItems: ToolbarContent {
    let back: (() -> Void)?
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let back, UserDefaults.standard.string(forKey: "navStyle") != "topbar" { ClassicTopBackButton(action: back) }
        }
    }
}

/// Top bar layout: the row under the title bar with Back (on pushed pages) on the left,
/// the navigation classicPill in the middle and search and Settings on the right. It stays in place on every page.
/// Laid out side by side, so a long classicPill never covers search and Settings.
/// macOS 26 draws an edge effect (a dark line) where a page scrolls under the top bar; hide it.
struct NoTopScrollEdge: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.scrollEdgeEffectHidden(true, for: .top) } else { content }
    }
}

struct ClassicTopNavBar: View {
    @Environment(\.appBG) var bg
    let back: (() -> Void)?
    var body: some View {
        // The two sides share the leftover width equally, so the classicPill stays in the middle of the window, and the
        // fixed height keeps the bar from growing: nothing moves when Back appears or disappears.
        HStack(spacing: 16) {
            HStack { if let back { ClassicTopBackButton(action: back) } }
                .fixedSize()   // never squeezed below Back's own width
                .frame(maxWidth: .infinity, alignment: .leading)
            // On a narrow window the sections don't all fit: the pill then scrolls sideways instead of
            // spilling past the window edge, where its buttons can't be clicked and Back gets squeezed out
            // Too narrow for the names: icons only (names on hover); scrolling only if even those don't fit
            ViewThatFits(in: .horizontal) {
                ClassicTopNavButtons()
                ClassicTopNavButtons(compact: true)
                ScrollView(.horizontal, showsIndicators: false) { ClassicTopNavButtons(compact: true) }
            }.layoutPriority(1)
            ClassicTopNavTools().fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 44)
        .padding(.horizontal, 28).padding(.vertical, 12)
    }
}

struct ClassicTopNavButtons: View {
    @AppStorage("accent") private var accentName = "red"
    @EnvironmentObject var emby: Emby
    @AppStorage(NavOrder.key) private var navOrder = ""
    @ObservedObject private var nav = ClassicNavState.shared
    @AppStorage("topBarLabels") private var labelSetting = "both"   // Settings → General: "both", "names" or "icons"
    /// The window is too narrow for the names: icons only, whatever Settings says.
    var compact = false
    var labels: String { compact ? "icons" : labelSetting }
    func item(_ title: String, _ id: String, _ icon: String, badge: Int = 0) -> some View {
        let on = nav.sel == id
        return Button {
            nav.query = ""; nav.searchOpen = false
            if nav.sel == id { nav.reselect += 1 }
            nav.sel = id; nav.popToRoot()
        } label: {
            // Small icon before each name, as in the sidebar
            HStack(spacing: 6) {
                // Glossy lettering (the 3D face, no thickness)
                if labels != "names" { Text3D(image: Image(systemName: icon), size: labels == "icons" ? 16 : 14, thick: false) }
                if labels != "icons" {
                    Text3D(text: badge > 0 ? "\(title) \(badge)" : title, size: 15, thick: false, weight: on ? .bold : .semibold)
                } else if badge > 0 { Text3D(text: "\(badge)", size: 15, thick: false) }
            }
                .opacity(on ? 1 : 0.6)
                .padding(.horizontal, labels == "names" ? 18 : 16).frame(height: 36)
                .classicSelectedPill(on)   // only the selected section gets the banner Play button's glass pill
                .modifier(SectionHoverGlow(on: !on))   // the others: an accent glow in the pill's shape on hover
                .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .tip(labels == "icons" ? title : "")   // names show on hover when only icons are shown
        .focusEffectDisabled()   // no blue keyboard-focus ring around a section
    }
    /// Favorites or Now Playing, wherever Settings → Libraries placed it.
    @ViewBuilder func section(_ id: String) -> some View {
        if id == NavOrder.favorites { item("Favorites", "favorites", "heart.fill") }
        else if id == NavOrder.nowPlaying { item("Now Playing", "nowplaying", "dot.radiowaves.left.and.right", badge: nav.activeCount) }
    }
    func icon(_ lib: LibPref) -> String {
        switch lib.kind {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "boxsets": return "square.stack"
        case "music": return "music.note"
        case "homevideos": return "video"
        default: return "folder"
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            item("Home", "home", "house.fill")
            let rows = NavOrder.rows(navOrder, libIds: emby.libs.map(\.id))
            ForEach(NavOrder.top(rows), id: \.self) { section($0) }
            ForEach(emby.libs) { lib in
                if lib.visible { item(lib.title, lib.id, icon(lib)) }
                ForEach(NavOrder.after(lib.id, rows), id: \.self) { section($0) }
            }
        }
        .padding(4)
        .frame(height: 44)
        .classicClearGlass()

    }
}

struct ClassicTopNavTools: View {
    @ObservedObject private var nav = ClassicNavState.shared
    var body: some View {
        HStack(spacing: 8) {
            // The search box itself floats at the bottom of the window (SearchDock)
            // Same 44-pt glass as Back, the sections and the Play button; Settings is in the Cove menu (⌘,)
            Button { nav.searchOpen.toggle(); if !nav.searchOpen { nav.query = "" } } label: {
                Image(systemName: "magnifyingglass").cvFont(14, weight: .semibold)
                    .frame(width: 44, height: 44).classicGlassPill().contentShape(Capsule())
            }.buttonStyle(HoverButton()).accessibilityLabel("Search")
        }
        .onChange(of: nav.focusSearch) { nav.searchOpen = true }   // S key
    }
}

extension View { func classicHideToolbarTitle() -> some View { modifier(HideToolbarTitle()) } }

struct ClassicTopBackButton: View {
    @EnvironmentObject var emby: Emby
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").cvFont(15, weight: .semibold)
            .frame(width: 44, height: 44)
            .brightness(hover ? 0.1 : 0)
            .classicGlassPill()
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButton())
        .focusEffectDisabled()   // no blue macOS focus ring when a page opens
        .scrollHover($hover)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back")
        .disabled(emby.playing != nil)
    }
}
