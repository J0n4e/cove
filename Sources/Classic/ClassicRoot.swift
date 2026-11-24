import IOKit.pwr_mgt
import SwiftUI
import AVKit

struct ClassicRootView: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("classicFont") private var classicFont = ClassicFont.defaultValue   // Settings → General → Font
    @Environment(\.appBG) var bg
    var body: some View {
        ZStack {
            // Hide (but keep) the screen under the player: AppKit controls such as spinners
            // otherwise draw on top of the video.
            Group { if emby.loggedIn { ClassicHomeView() } else { ClassicLoginView() } }
                .opacity(emby.playing == nil ? 1 : 0)
                .allowsHitTesting(emby.playing == nil)
            if let req = emby.playing {
                ChosenPlayerView(req: req).id(req.id).zIndex(10)
            }
        }
        // A server or user change (switch, sign-in, sign-out) always starts on Home
        .onChange(of: emby.server + "|" + emby.userId) { ClassicNavState.shared.reset() }
        .onChange(of: emby.playing?.id) { _, id in
            PlaybackFlag.shared.active = id != nil
        }
        // Someone who was on the retired Glass theme: one note, once, after the window is up
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            if ThemeMigration.takeNote() { GlassMessage.show(ThemeMigration.noteTitle, ThemeMigration.noteText) }
        }
        .dropdownLayer()   // glass lists for audio, subtitles, quality
        .tipLayer()   // inside the settings below, so the tooltips get the Classic look and font too
        .environment(\.classicGlass, true)
        // Text that does not name a font follows the chosen one's design; a new font rebuilds the screens so every
        // text picks it up
        .fontDesign(classicFont == "rounded" ? .rounded : classicFont == "serif" ? .serif : .default)
        .id(classicFont)
        // No scroll bars in the rows (scroll with the wheel, trackpad or the row arrows); pages that scroll
        // vertically turn on thin overlay bars of their own (classicScrollBars)
        .scrollIndicators(.hidden)
        // Transparent title bar: banners and the video run to the top edge under the traffic lights
        .background(ClassicWindowChrome().frame(width: 0, height: 0))
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

    func icon(_ lib: LibPref) -> String { LibraryIcon.symbol(kind: lib.kind, name: lib.name) }

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

    /// Favorites or Activity in the sidebar, wherever Settings → Libraries placed it.
    @ViewBuilder func sideSection(_ id: String) -> some View {
        if id == NavOrder.favorites { sideRow("Favorites", "heart.fill", "favorites") }
        else if id == NavOrder.nowPlaying { sideRow(ActivitySection.title, ActivitySection.icon, "nowplaying", badge: activeCount, activity: true) }
    }

    /// One sidebar line: the chosen one on an accent glass band, the one under the pointer lit softly (as the glass
    /// lists). Clicking the chosen one again goes back to that page's start.
    /// Activity: the streams circle and the unread dot sit on its icon (as in the top bar).
    func sideRow(_ title: String, _ icon: String, _ id: String, badge: Int = 0, activity: Bool = false) -> some View {
        let on = sel == id
        return Button { if on { popToRoot() } else { selB.wrappedValue = id } } label: {
            HStack(spacing: Glass3DTokens.Space.m) {
                Image(systemName: icon).cvFont(13).frame(width: 18).foregroundStyle(.tint)
                    .modifier(ToolbarActivityMarkers(streams: badge, enabled: activity))
                Text(title).cvFont(13, weight: on ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, Glass3DTokens.Space.m).frame(height: 32)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous).fill(Theme.accent(accentName).opacity(0.4))
                        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
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
                        .padding(.horizontal, Glass3DTokens.Space.m).padding(.top, Glass3DTokens.Space.m).padding(.bottom, 2)
                    ForEach(emby.libs) { lib in
                        if lib.visible { sideRow(lib.title, icon(lib), lib.id) }
                        ForEach(NavOrder.after(lib.id, rows), id: \.self) { sideSection($0) }
                    }
                }.padding(.horizontal, Glass3DTokens.Space.s).padding(.vertical, Glass3DTokens.Space.s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 280)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
                    Button { emby.switchServer() } label: {
                        HStack(spacing: Glass3DTokens.Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(emby.currentServerName).cvFont(12, weight: .semibold).lineLimit(1)
                                Text(emby.currentServer?.user.isEmpty == false ? emby.currentServer!.user : (URL(string: emby.server)?.host ?? ""))
                                    .cvFont(10, weight: .regular).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down").cvFont(10, weight: .regular).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s)
                        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHand)
                    .helpLabel("Connected to \(emby.server) — click to switch server")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Glass3DTokens.Space.m).padding(.top, Glass3DTokens.Space.m).padding(.bottom, Glass3DTokens.Space.xs)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Glass3DTokens.Space.m) {
                    Button { nav.showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape").cvFont(12, weight: .medium)
                            .padding(.horizontal, Glass3DTokens.Space.l).frame(height: 32).classicGlassPill()
                    }
                    .helpLabel("Settings (⌘,)").keyboardShortcut(",", modifiers: .command)
                    Spacer()
                }.buttonStyle(.plainHand).padding(Glass3DTokens.Space.m)
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
                    else if sel == "home" { ClassicHomeContent(reloadToken: reloadToken).id(HomeModel.sessionKey(server: emby.server, userId: emby.userId)) }
                    else if sel == "favorites" { ClassicFavoritesView() }
                    else if sel == "nowplaying" { ClassicNowPlayingView() }
                    else if let lib = emby.libs.first(where: { $0.id == sel }) { ClassicLibraryView(lib: lib, refresh: nav.reselect).id(lib.id) }
                    else { Color.black }
                }
                // A page opened from search results is the only page: no Back (deeper pages get one)
                .navigationDestination(for: Item.self) { ClassicDetailView(item: $0).environment(\.noBack, fromSearch && path.count == 1) }
                .navigationDestination(for: PersonRef.self) { ClassicPersonView(person: $0).environment(\.noBack, fromSearch && path.count == 1) }
                .navigationDestination(for: FavoriteGridRef.self) { ClassicFavoriteGridView(title: $0.title, ids: $0.ids) }
                .navigationDestination(for: FavoritePeopleRef.self) { _ in ClassicFavoritePeopleView() }
            }
            // Readable under the see-through bar, on every page of the stack (see ClassicTopScrollEdge)
            .modifier(ClassicTopScrollEdge())
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
        .task { await emby.ensureLibs() }
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
                                              },
                                              escBusy: { ProfileModel.shared.menuOpen || ClassicNavState.shared.searchOpen })
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
                // Not while the app is hidden or fully covered: nobody sees the count (refreshed within 20 s of coming back)
                if AppVisibility.isVisible {
                    let n = await emby.nowPlaying().count
                    if nav.activeCount != n { nav.activeCount = n }      // publish only real changes
                }
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
        // A selected library this server or user doesn't have goes back to Home
        .onChange(of: emby.libs.map(\.id), initial: true) { _, ids in
            let s = NavState.selection(nav.sel, libIds: ids)
            if s != nav.sel { nav.sel = s }
        }
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
        .overlay { NotificationToastLayer() }   // new movies / episodes while Cove is in front (Sources/Notifications)
        .overlay { CastRemoteBar() }            // the Cast remote while casting (Glass3DCast.swift)
        .modifier(Glass3DProfileMenuLayer())    // the profile menu under the top bar's circle
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

    /// After a server or user change: back to Home with no pushed pages and the search closed (see NavState.reset).
    func reset() {
        sel = "home"; query = ""; searchOpen = false
        popToRoot()
    }
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

struct ClassicTopNavBar: View {
    @Environment(\.appBG) var bg
    let back: (() -> Void)?
    @State private var barWidth: CGFloat = 0
    /// Width the sections may use: the bar minus the two fixed side slots (Back, profile circle) and the gaps, so
    /// the sections stay centred and never push Back or the profile circle out.
    var available: CGFloat {
        guard barWidth > 0 else { return 0 }
        return max(0, barWidth - 2 * (Glass3DTokens.Toolbar.sideSlot + Glass3DTokens.Space.l))
    }
    var body: some View {
        // The two sides share the leftover width equally, so the sections stay in the middle of the window, and the
        // fixed height keeps the bar from growing: nothing moves when Back appears or disappears.
        HStack(spacing: Glass3DTokens.Space.l) {
            HStack { if let back { ClassicTopBackButton(action: back) } }
                .fixedSize()   // never squeezed below Back's own width
                .frame(minWidth: Glass3DTokens.Toolbar.sideSlot, maxWidth: .infinity, alignment: .leading)
            // On a narrow window the sections that don't fit move into the More (⋯) menu at the end of the bar
            ClassicTopNavButtons(available: available).layoutPriority(1)
            ClassicTopNavTools().fixedSize()
                .frame(minWidth: Glass3DTokens.Toolbar.sideSlot, maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: Glass3DTokens.Toolbar.barHeight)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { barWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in barWidth = w }
        })
        .padding(.horizontal, Glass3DTokens.Space.xxl).padding(.vertical, Glass3DTokens.Space.m)
    }
}

struct ClassicTopNavButtons: View {
    @EnvironmentObject var emby: Emby
    @AppStorage(NavOrder.key) private var navOrder = ""
    @ObservedObject private var nav = ClassicNavState.shared
    @AppStorage("topBarLabels") private var labels = "both"   // Settings → General: "both", "names" or "icons"
    /// Width the sections may use (0 = not measured yet: show all)
    var available: CGFloat = 0
    @State private var widths: [String: CGFloat] = [:]

    struct Entry: Identifiable { let id: String; let title: String; let icon: String }

    /// Every section in bar order: Home, Favorites / Activity where Settings → Libraries placed them, libraries.
    var entries: [Entry] {
        var out = [Entry(id: "home", title: "Home", icon: "house.fill")]
        let rows = NavOrder.rows(navOrder, libIds: emby.libs.map(\.id))
        func section(_ id: String) {
            if id == NavOrder.favorites { out.append(Entry(id: "favorites", title: "Favorites", icon: "heart.fill")) }
            else if id == NavOrder.nowPlaying { out.append(Entry(id: "nowplaying", title: ActivitySection.title, icon: ActivitySection.icon)) }
        }
        NavOrder.top(rows).forEach(section)
        for lib in emby.libs {
            if lib.visible { out.append(Entry(id: lib.id, title: lib.title, icon: LibraryIcon.symbol(kind: lib.kind, name: lib.name))) }
            NavOrder.after(lib.id, rows).forEach(section)
        }
        return out
    }

    func select(_ id: String) {
        nav.query = ""; nav.searchOpen = false
        if nav.sel == id { nav.reselect += 1 }
        nav.sel = id; nav.popToRoot()
    }

    func label(_ e: Entry) -> some View {
        ToolbarItemLabel(title: e.title, icon: e.icon, labels: labels, on: nav.sel == e.id,
                         activity: e.id == "nowplaying", streams: nav.activeCount)
    }

    func item(_ e: Entry) -> some View {
        Button { select(e.id) } label: { label(e) }
            .buttonStyle(.plainHand)
            .tip(labels == "icons" ? e.title : "")   // names show on hover when only icons are shown
            .focusEffectDisabled()   // no blue keyboard-focus ring around a section
    }

    var body: some View {
        let all = entries
        let inner = available > 0 ? available - 2 * Glass3DTokens.Space.xs : 0
        let split = ToolbarOverflow.split(all.map(\.id), widths: widths, available: inner, spacing: Glass3DTokens.Space.s,
                                          moreWidth: widths[Self.moreId] ?? Glass3DTokens.Toolbar.sideSlot, selected: nav.sel)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        HStack(spacing: Glass3DTokens.Space.s) {
            ForEach(split.visible, id: \.self) { id in if let e = byId[id] { item(e) } }
            if !split.overflow.isEmpty {
                ToolbarMoreButton(items: split.overflow.compactMap { byId[$0] }.map { ($0.id, $0.title) },
                                  selected: nav.sel, pick: select)
            }
        }
        .padding(Glass3DTokens.Space.xs)
        .frame(height: Glass3DTokens.Toolbar.barHeight)
        .modifier(ToolbarBarSurface())   // steady tinted glass + hairline (macOS 26 and 14/15)
        // Off-screen copies of every section (and More) at their natural width, for the split above
        .background {
            HStack(spacing: 0) {
                ForEach(all) { e in label(e).toolbarMeasure(e.id) }
                ToolbarMoreButton(items: [], selected: "", pick: { _ in }).toolbarMeasure(Self.moreId)
            }
            .fixedSize().hidden().allowsHitTesting(false)
        }
        .onPreferenceChange(ToolbarWidthsKey.self) { w in if w != widths { widths = w } }
    }
    static let moreId = "__more"
}

struct ClassicTopNavTools: View {
    @ObservedObject private var nav = ClassicNavState.shared
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.s) {
            // No search button (owner): ⌘F opens the search pill at the bottom of the window (SearchDock)
            Glass3DProfileCircle()   // far right: the profile menu (Glass3DProfile*.swift)
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


