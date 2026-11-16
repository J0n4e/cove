import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// Keys in the main window: "S" opens Search, "H" goes Home, ⌘← goes Back (as ⌘[ does), ← → turn the Home banner. Not while typing in a
/// field (⌘← moves the cursor there), not in the player.
enum SearchKey {
    static func install(isPlaying: @escaping () -> Bool, focus: @escaping () -> Void,
                        home: @escaping () -> Void, back: @escaping () -> Void,
                        banner: @escaping (Int) -> Bool) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard let w = ev.window, w.title != "Player", !(w is PanelWindow), w.attachedSheet == nil, w.sheetParent == nil,
                  !(w.firstResponder is NSText), !isPlaying() else { return ev }
            let mods = ev.modifierFlags.intersection([.command, .control, .option, .shift])
            if ev.keyCode == 123 && mods == .command { back(); return nil }   // ⌘←
            if mods.isEmpty && (ev.keyCode == 123 || ev.keyCode == 124) {         // ← →, only on Home
                return banner(ev.keyCode == 123 ? -1 : 1) ? nil : ev
            }
            guard mods.subtracting(.shift).isEmpty, let key = ev.charactersIgnoringModifiers?.lowercased(),
                  key == "s" || key == "h" else { return ev }
            if key == "s" { focus() } else { home() }
            return nil
        }
    }
}

struct RootView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("separatePlayer") private var separatePlayer = false
    var body: some View {
        let inline = !separatePlayer
        ZStack {
            // Hide (but keep) the screen under an in-window player: AppKit controls such as spinners
            // otherwise draw on top of the video.
            Group {
                // Keyed by server + user: switching servers (Settings → Servers → Connect) rebuilds every page,
                // so nothing from the previous server (libraries, rows, banner pictures) stays on screen
                if emby.loggedIn { HomeView().id(emby.server + "|" + emby.userId) } else { LoginView() }
            }
                .opacity(inline && emby.playing != nil ? 0 : 1)
                .allowsHitTesting(!(inline && emby.playing != nil))
            if inline, let req = emby.playing {
                ChosenPlayerView(req: req, theme: "apple").id(req.id).zIndex(10)
            }
        }
        // Settings → Playback → "Open videos in a separate window" (Apple TV style): open it when something
        // starts, close it when it stops
        .onChange(of: emby.playing?.id) { _, id in
            PlaybackFlag.shared.active = id != nil
            guard separatePlayer else { return }
            if id != nil { openWindow(id: "player") } else { dismissWindow(id: "player") }
        }
        // Switching the setting while a video plays: stop it cleanly (it would otherwise be left without a player)
        .onChange(of: separatePlayer) { _, _ in
            if emby.playing != nil { emby.playing = nil; dismissWindow(id: "player") }
        }
        .tipLayer()
    }
}

// MARK: - Sidebar shell + search

/// Lets a click on an already-selected sidebar row act (a List only reports *changes* of selection).
/// The tap gesture is switched on ONLY for the row that is already selected: a gesture on a row that is
/// not selected yet swallows the first click on macOS, so that row would need several clicks to select.
struct RootTap: ViewModifier {
    let id: String
    let sel: String
    let action: () -> Void
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { action() },
                                 including: sel == id ? .all : .subviews)
    }
}

struct HomeView: View {
    @State private var keepPage = false   // the search box is being cleared after opening a result
    @State private var fromSearch = false // the first page on the stack was opened from search results
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @FocusState private var searchFocused: Bool
    @State private var searchKey: Any?
    // Shared with the title bar (Top bar layout puts the navigation buttons in the window's toolbar)
    @ObservedObject private var nav = NavState.shared
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
    // Settings → Libraries → Sections: which fixed sections the sidebar / top bar show (Home always shows)
    @AppStorage("showFavorites") private var showFavorites = true
    @AppStorage(NavOrder.key) private var navOrder = ""
    @AppStorage("showNowPlaying") private var showNowPlaying = true
    @AppStorage("showRecent") private var showRecent = true

    /// Sidebar row like the Apple TV app: blue icon, white text.
    func sideLabel(_ title: String, _ icon: String) -> some View {
        Label {
            Text(title).foregroundColor(.white)
        } icon: {
            Image(systemName: icon).foregroundStyle(TintShapeStyle())
        }.font(.system(size: 15))
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

    /// Clicking the sidebar item you are already on (e.g. Movies while browsing actors and titles) goes back
    /// to that page's start. Picking a different item does the same through the onChange below.
    func popToRoot() {
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
        if id == NavOrder.favorites && showFavorites {
            sideLabel("Favorites", "heart").modifier(RootTap(id: "favorites", sel: sel, action: popToRoot)).tag("favorites")
        } else if id == NavOrder.nowPlaying && showNowPlaying {
            sideLabel("Now Playing", "dot.radiowaves.left.and.right")
                .modifier(RootTap(id: "nowplaying", sel: sel, action: popToRoot))
                .badge(activeCount)
                .tag("nowplaying")   // tag last, or the badge hides it and the row can't be selected
        }
    }

    var splitLayout: some View {
        NavigationSplitView {
            List(selection: selB) {
                sideLabel("Home", "house").modifier(RootTap(id: "home", sel: sel, action: popToRoot)).tag("home")
                let rows = NavOrder.rows(navOrder, libIds: emby.libs.map(\.id))
                ForEach(NavOrder.top(rows), id: \.self) { sideSection($0) }
                Section("Library") {
                    if showRecent {
                        sideLabel("Recently Added", "clock").modifier(RootTap(id: "recent", sel: sel, action: popToRoot)).tag("recent")
                    }
                    ForEach(emby.libs) { lib in
                        if lib.visible {
                            sideLabel(lib.title, icon(lib)).modifier(RootTap(id: lib.id, sel: sel, action: popToRoot)).tag(lib.id)
                        }
                        ForEach(NavOrder.after(lib.id, rows), id: \.self) { sideSection($0) }
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 34)
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 290)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    // Search sits in the sidebar, as in the Apple TV app
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search", text: queryB).textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onChange(of: nav.focusSearch) { searchFocused = true }
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }.buttonStyle(.plainHand)
                        }
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
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
            detailPane(withSearch: false)
        }
    }

    /// The page area (search results, home, libraries, detail pages) shared by both navigation styles.
    func detailPane(withSearch: Bool) -> some View {
        VStack(spacing: 0) {
            if withSearch { SearchBar(query: queryB) }
            NavigationStack(path: $path) {
                Group {
                    if !query.isEmpty { SearchView(query: query) }
                    else if sel == "home" { HomeContent(reloadToken: reloadToken) }
                    else if sel == "favorites" { FavoritesView() }
                    else if sel == "nowplaying" { NowPlayingView() }
                    else if sel == "recent" { FeedView(feed: .recent, root: true) }
                    else if let lib = emby.libs.first(where: { $0.id == sel }) { LibraryView(lib: lib).id(lib.id) }
                    else { Color.black }
                }
                // A page opened from search results is the only page: no Back (deeper pages get one)
                .navigationDestination(for: Item.self) { DetailView(item: $0).environment(\.noBack, fromSearch && path.count == 1) }
                .navigationDestination(for: PersonRef.self) { PersonView(person: $0).environment(\.noBack, fromSearch && path.count == 1) }
                .navigationDestination(for: Feed.self) { FeedView(feed: $0) }
                .navigationDestination(for: FavoriteGridRef.self) { FavoriteGridView(title: $0.title, ids: $0.ids) }
                .navigationDestination(for: FavoritePeopleRef.self) { _ in FavoritePeopleView() }
            }
            // Back button in the title bar, left of the window title, on every page
            .toolbar { TitleBarItems(back: nil) }   // top-level pages: no Back (pushed pages add their own)
            .hideToolbarTitle()
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    // MARK: Top bar navigation (Settings → General → Appearance → Navigation)

    /// Top bar layout: a navigation row under the title bar (see TopNavBar), with the page area below it.
    var topLayout: some View {
        // Both the bar and the page are held to the window's width: a page that grew wider than the window
        // (e.g. Favorites) made the bar wider too, pushing its pill off screen where it couldn't be clicked.
        GeometryReader { geo in
            VStack(spacing: 0) {
                // In front of the page, so nothing on a page can cover its buttons. Back sits in the bar on pushed pages.
                TopNavBar(back: path.isEmpty || (fromSearch && path.count == 1) ? nil : { path.removeLast() })   // no Back on a search result
                    .frame(width: geo.size.width).zIndex(1)
                detailPane(withSearch: false)
                    .frame(width: geo.size.width).clipped()
            }
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
                                              focus: { NavState.shared.focusSearch += 1 },
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
                let n = await emby.nowPlaying().count
                if nav.activeCount != n { nav.activeCount = n }      // publish only real changes
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
        .onChange(of: [showFavorites, showNowPlaying, showRecent]) {
            let hidden = (!showFavorites && sel == "favorites") || (!showNowPlaying && sel == "nowplaying") || (!showRecent && sel == "recent")
            if hidden { nav.sel = "home" }
        }
        .onChange(of: emby.openRequest) { _, item in
            guard let item else { return }
            path.append(item)
            emby.openRequest = nil
        }
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
/// (the dark pill used over video disappears on a black background).
/// Title bar contents: just the optional Back button on the left (no app name).
/// State shared between the page area and the title bar's navigation buttons.
final class NavState: ObservableObject {
    static let shared = NavState()
    @Published var sel = "home"
    @Published var query = ""
    @Published var searchOpen = false
    /// Goes up to put the cursor in the search field (the S key)
    @Published var focusSearch = 0
    /// ← → on Home: the banner turns one page that way
    struct Nudge: Equatable { let id = UUID(); let dir: Int }
    @Published var bannerNudge: Nudge?
    @Published var activeCount = 0
    @Published var showSettings = false
    var popToRoot: () -> Void = {}
    /// Pushes an item's page (for views outside SwiftUI navigation, as the AppKit poster grid)
    var open: (Item) -> Void = { _ in }
    /// Pushes any page (a person, from the AppKit grid's header)
    var push: (any Hashable) -> Void = { _ in }
}

/// Window toolbar contents: the Back pill on pushed pages. (In the Top bar layout the navigation and Back
/// sit in their own row under the title bar, see TopNavBar.)
struct TitleBarItems: ToolbarContent {
    let back: (() -> Void)?
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let back, UserDefaults.standard.string(forKey: "navStyle") != "topbar" { TopBackButton(action: back) }
        }
    }
}

/// Top bar layout: the row under the title bar with Back (on pushed pages) on the left,
/// the navigation pill in the middle and search and Settings on the right. It stays in place on every page.
/// Laid out side by side, so a long pill never covers search and Settings.
struct TopNavBar: View {
    @Environment(\.appBG) var bg
    let back: (() -> Void)?
    var body: some View {
        // The two sides share the leftover width equally, so the pill stays in the middle of the window, and the
        // fixed height keeps the bar from growing: nothing moves when Back appears or disappears.
        HStack(spacing: 16) {
            HStack { if let back { TopBackButton(action: back) } }
                .fixedSize()   // never squeezed below Back's own width
                .frame(maxWidth: .infinity, alignment: .leading)
            // On a narrow window the sections don't all fit: the pill then scrolls sideways instead of
            // spilling past the window edge, where its buttons can't be clicked and Back gets squeezed out
            // Too narrow for the names: icons only (names on hover); scrolling only if even those don't fit
            ViewThatFits(in: .horizontal) {
                TopNavButtons()
                TopNavButtons(compact: true)
                ScrollView(.horizontal, showsIndicators: false) { TopNavButtons(compact: true) }
            }.layoutPriority(1)
            TopNavTools().fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 40)
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(bg)
    }
}

struct TopNavButtons: View {
    @AppStorage("accent") private var accentName = "red"
    @EnvironmentObject var emby: Emby
    @ObservedObject private var nav = NavState.shared
    @AppStorage("showFavorites") private var showFavorites = true
    @AppStorage(NavOrder.key) private var navOrder = ""
    @AppStorage("showNowPlaying") private var showNowPlaying = true
    @AppStorage("showRecent") private var showRecent = true
    @AppStorage("topBarLabels") private var labelSetting = "both"   // Settings → General: "both", "names" or "icons"
    /// The window is too narrow for the names: icons only, whatever Settings says.
    var compact = false
    var labels: String { compact ? "icons" : labelSetting }
    func item(_ title: String, _ id: String, _ icon: String, badge: Int = 0) -> some View {
        let on = nav.sel == id
        return Button {
            nav.query = ""; nav.searchOpen = false
            nav.sel = id; nav.popToRoot()
        } label: {
            // Small icon before each name, as in the sidebar
            HStack(spacing: 6) {
                if labels != "names" { Image(systemName: icon).font(.system(size: labels == "icons" ? 14 : 12)) }
                if labels != "icons" { Text(badge > 0 ? "\(title) \(badge)" : title) }
                else if badge > 0 { Text("\(badge)") }
            }
                .font(.callout.weight(on ? .semibold : .regular))
                .foregroundColor(on ? Theme.onAccent(accentName) : .secondary)   // black on a white accent
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(on ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .tip(labels == "icons" ? title : "")   // names show on hover when only icons are shown
        .focusEffectDisabled()   // no blue keyboard-focus ring around a section
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
    /// Favorites or Now Playing, wherever Settings → Libraries placed it.
    @ViewBuilder func section(_ id: String) -> some View {
        if id == NavOrder.favorites && showFavorites { item("Favorites", "favorites", "heart") }
        else if id == NavOrder.nowPlaying && showNowPlaying {
            item("Now Playing", "nowplaying", "dot.radiowaves.left.and.right", badge: nav.activeCount)
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            item("Home", "home", "house")
            let rows = NavOrder.rows(navOrder, libIds: emby.libs.map(\.id))
            ForEach(NavOrder.top(rows), id: \.self) { section($0) }
            if showRecent { item("Recently Added", "recent", "clock") }
            ForEach(emby.libs) { lib in
                if lib.visible { item(lib.title, lib.id, icon(lib)) }
                ForEach(NavOrder.after(lib.id, rows), id: \.self) { section($0) }
            }
        }
        .padding(4)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.4)))
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

struct TopNavTools: View {
    @ObservedObject private var nav = NavState.shared
    var body: some View {
        HStack(spacing: 8) {
            // The search box itself floats at the bottom of the window (SearchDock)
            Button { nav.searchOpen.toggle(); if !nav.searchOpen { nav.query = "" } } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .contentShape(Circle())
            }.buttonStyle(HoverButton()).helpLabel("Search (S)")
        }
        .onChange(of: nav.focusSearch) { nav.searchOpen = true }   // S key
    }
}

/// Removes the toolbar's default left-aligned title (`ToolbarDefaultItemKind.title` needs macOS 15).
struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}
extension View { func hideToolbarTitle() -> some View { modifier(HideToolbarTitle()) } }

struct TopBackButton: View {
    @EnvironmentObject var emby: Emby
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            // Apple TV style: a round glass ‹ button
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(hover ? 0.55 : 0.4)))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(HoverButton())
        .focusEffectDisabled()   // no blue macOS focus ring when a page opens
        .scrollHover($hover)
        .keyboardShortcut("[", modifiers: .command)
        .helpLabel("Back (⌘[)")
        .disabled(emby.playing != nil)
    }
}

/// Confirmation pill at the bottom of the window after a favorite or watched change; fades after 2 s.
struct ToastOverlay: View {
    @EnvironmentObject var emby: Emby
    var raised = false   // the search box is open at the bottom: sit above it
    var body: some View {
        VStack {
            Spacer()
            if let t = emby.toast {
                Label(t.text, systemImage: t.icon)
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    .padding(.horizontal, 18).frame(height: 44)
                    .searchGlass()
                    .padding(.bottom, raised ? 80 : 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
                    .task(id: t.id) {
                        try? await Task.sleep(for: .seconds(2))
                        if emby.toast?.id == t.id { emby.toast = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.35), value: emby.toast)
        .allowsHitTesting(false)
    }
}
