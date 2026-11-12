// Classic theme: the original Cove screens from v1.9.2 (main), used when Settings → General → Theme is Classic.
// Names carry a "Classic" prefix so they live next to the Apple TV screens.

import IOKit.pwr_mgt
import SwiftUI
import AVKit

// MARK: - Theme

// Background color, accent colors (Theme) and \.appBG are shared with the Apple TV theme (Views.swift).

struct ClassicPillStyle: ViewModifier {
    @AppStorage("accent") private var name = "red"
    let active: Bool
    func body(content: Content) -> some View {
        content.font(.cv(12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .classicGlassPill()
    }
}

extension View {
    /// Glass card finish that follows the rounded corners (posters, episode thumbnails, preview card).
    /// `size`: the card's fixed size, if it has one, so the finish is drawn once and reused (see Raster).
    func classicThinBorder(_ radius: CGFloat, size: CGSize? = nil) -> some View { modifier(ClassicGlassCard(radius: radius, size: size)) }
    func classicPill(active: Bool = false) -> some View { modifier(ClassicPillStyle(active: active)) }
    func classicOnAccent() -> some View { modifier(OnAccent()) }
    func classicCircleButton() -> some View {
        self.font(.cv(15, weight: .regular)).frame(width: 44, height: 44)
            .background(Color.white.opacity(0.14)).clipShape(Circle())
    }
}

let classicAlphaLetters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

func classicParseDate(_ s: String?) -> Date? {
    guard let s, s.count >= 19 else { return nil }
    return ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
}

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
            ClassicHoverCardLayer()
            if let req = emby.playing {
                ChosenPlayerView(req: req, theme: "classic").id(req.id).zIndex(10)
            }
        }
        .onChange(of: emby.playing?.id) { _, id in
            PlaybackFlag.shared.active = id != nil
            if id != nil { ClassicHoverCardCenter.shared.hide() }
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

struct ClassicLoginView: View {
    @EnvironmentObject var emby: Emby
    @State private var adding = false
    @State private var server = ""
    @State private var serverLabel = ""   // optional name shown in the server list
    @State private var user = ""
    @State private var pw = ""
    @State private var error = ""
    @State private var busy = false
    @FocusState private var focus: Field?
    enum Field { case name, server, user, pw }

    var showForm: Bool { adding || emby.servers.isEmpty }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                if showForm { form } else { serverList }
                if !error.isEmpty { Text(error).foregroundColor(.orange).font(.cv(10, weight: .regular)).multilineTextAlignment(.center) }
            }
            .frame(width: showForm ? 340 : 520).padding(36)
            .modifier(PanelSurface(classic: true))   // dark glass, as the player panels
        }
    }

    var serverList: some View {
        VStack(spacing: 14) {
            Text("Select Server").font(.cv(22, weight: .bold)).padding(.bottom, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(emby.servers) { s in serverCard(s) }
                Button { startAdd() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus").font(.cv(34, weight: .light))
                            .frame(width: 150, height: 100)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                        Text("Add Server").font(.cv(13, weight: .bold))
                        Text(" ").font(.cv(10, weight: .regular))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plainHand)
            }
            if busy { Spinner().controlSize(.small) }
        }
    }

    func serverCard(_ s: SavedServer) -> some View {
        Button { open(s) } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "server.rack").font(.cv(38))
                        .frame(width: 150, height: 100)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                    if s.token != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(6)
                            .helpLabel("Signed in")
                    }
                }
                HStack(spacing: 5) { ConnectionBadge(address: s.url).font(.cv(10, weight: .regular)); Text(s.name).font(.cv(13, weight: .bold)).lineLimit(1) }
                Text((s.user.isEmpty ? s.url : "\(s.user) · \(s.url)") + " · " + emby.kindLabel(s))
                    .font(.cv(10, weight: .regular)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 150).contentShape(Rectangle())
        }
        .buttonStyle(HoverButton()).disabled(busy)
        .contextMenu {
            Button("Edit / Sign In Again") { edit(s) }
            Button("Remove Server", role: .destructive) { emby.removeServer(s) }
        }
    }

    var form: some View {
        VStack(spacing: 14) {
            HStack {
                if !emby.servers.isEmpty {
                    Button { adding = false; error = "" } label: { Label("Back", systemImage: "chevron.left").classicGlassPill(size: 34) }
                        .buttonStyle(HoverButton()).helpLabel("Back to servers")
                }
                Spacer()
                Text(emby.servers.isEmpty ? "Sign In" : "Add Server").font(.cv(22, weight: .bold))
                Spacer()
                if !emby.servers.isEmpty { Color.clear.frame(width: 34, height: 34) }
            }.padding(.bottom, 6)
            TextField("Name (optional, e.g. Home Jellyfin)", text: $serverLabel).focused($focus, equals: .name)
                .onSubmit { focus = .server }.modifier(GlassField())
            TextField("Server (e.g. 192.168.1.10:8096)", text: $server).focused($focus, equals: .server)
                .onSubmit { focus = .user }.modifier(GlassField())
            TextField("Username", text: $user).focused($focus, equals: .user).onSubmit { focus = .pw }.modifier(GlassField())
            SecureField("Password", text: $pw).focused($focus, equals: .pw).onSubmit(go).modifier(GlassField())
            Button(action: go) {
                HStack {
                    if busy { Spinner().controlSize(.small) }
                    Text("Sign In").font(.cv(14, weight: .bold))
                }.frame(maxWidth: .infinity).frame(height: 40).classicGlassPill()
            }.buttonStyle(HoverButton()).disabled(busy || server.isEmpty || user.isEmpty)
            .opacity(busy || server.isEmpty || user.isEmpty ? 0.5 : 1)
        }
        .onAppear { focus = server.isEmpty ? .server : .pw }
    }

    func startAdd() { server = ""; user = ""; pw = ""; error = ""; adding = true }

    func edit(_ s: SavedServer) { server = s.url; serverLabel = s.name; user = s.user; pw = ""; error = ""; adding = true; focus = .pw }

    func open(_ s: SavedServer) {
        error = ""
        guard s.token != nil else { edit(s); return }
        busy = true
        Task {
            let result = await emby.resume(s)
            busy = false
            switch result {
            case .ok: break
            case .expired: edit(s); error = "Session expired. Enter your password to sign in again."
            case .unreachable: error = "Couldn't reach \(s.name). Check that the server is running and try again."
            }
        }
    }

    func go() {
        guard !busy else { return }
        busy = true; error = ""
        Task {
            // https when the server has it; warn before a password goes out unencrypted over the internet
            let address = await Emby.resolveAddress(server)
            if ConnectionSecurity.kind(address) == .remotePlain, !ConnectionSecurity.confirmPlainHTTP(address) { busy = false; return }
            do { try await emby.login(server: address, user: user, pw: pw, name: serverLabel); pw = ""; adding = false }
            catch { self.error = (error as? LoginError)?.errorDescription ?? Emby.describe(error) }
            busy = false
        }
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
                Image(systemName: icon).font(.cv(13)).frame(width: 18).foregroundStyle(.tint)
                Text(title).font(.cv(13, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 { Text("\(badge)").font(.cv(11, weight: .semibold)).foregroundColor(.secondary) }
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
                    Text("MY MEDIA").font(.cv(10, weight: .semibold)).kerning(0.6).foregroundColor(.secondary)
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
                                Text(emby.currentServerName).font(.cv(12, weight: .semibold)).lineLimit(1)
                                Text(emby.currentServer?.user.isEmpty == false ? emby.currentServer!.user : (URL(string: emby.server)?.host ?? ""))
                                    .font(.cv(10, weight: .regular)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down").font(.cv(10, weight: .regular)).foregroundColor(.secondary)
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
                        Label("Settings", systemImage: "gearshape").font(.cv(12, weight: .medium))
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
                    else if let lib = emby.libs.first(where: { $0.id == sel }) { ClassicLibraryView(lib: lib).id(lib.id) }
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
        .onAppear { updateTitleBarH(); nav.popToRoot = { path = NavigationPath(); nav.query = "" } }
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
            ClassicHoverCardCenter.shared.hide()   // a preview card must not stay over the page just opened
            if old == 0 && new > 0 && !query.isEmpty {
                keepPage = true; query = ""; nav.searchOpen = false; fromSearch = true
            }
            if new == 0 { fromSearch = false }
        }
        .onChange(of: sel) { fromSearch = false; ClassicHoverCardCenter.shared.hide() }
        .onChange(of: emby.openRequest) { _, item in
            guard let item else { return }
            path.append(item)
            emby.openRequest = nil
        }
        // Settings always use the Glass window, whichever theme is chosen
        .sheet(isPresented: showSettingsB) { SettingsView { reloadToken += 1 } }
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
    @Published var query = ""
    @Published var searchOpen = false
    /// Goes up to put the cursor in the search field (the S key)
    @Published var focusSearch = 0
    @Published var bannerNudge: NavState.Nudge?   // ← → on Home
    @Published var activeCount = 0
    @Published var showSettings = false
    var popToRoot: () -> Void = {}
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
                Image(systemName: "magnifyingglass").font(.cv(14, weight: .semibold))
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
            Image(systemName: "chevron.left").font(.cv(15, weight: .semibold))
            .frame(width: 44, height: 44)
            .brightness(hover ? 0.1 : 0)
            .classicGlassPill()
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButton())
        .focusEffectDisabled()   // no blue macOS focus ring when a page opens
        .onHover { hover = ScrollActivity.hover(hover, $0) }
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back")
        .disabled(emby.playing != nil)
    }
}

struct ClassicSearchBar: View {
    @Binding var query: String
    @Environment(\.appBG) var bg
    @ObservedObject private var nav = ClassicNavState.shared
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search movies, shows, people", text: $query).textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: nav.focusSearch) { focused = true }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plainHand)
                }
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .background(ClassicGlassBacking(shape: Capsule()))   // glass field, as the search box
            .frame(width: 280)
        }
        .padding(.horizontal, 32).padding(.vertical, 10)
        .background(bg)
    }
}

struct ClassicSearchView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let query: String
    @State private var results: [Item] = []
    @State private var people: [Item] = []
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Results for “\(query)”").font(.cv(17, weight: .bold))
                if !people.isEmpty { peopleRow }
                if !people.isEmpty && !results.isEmpty { Text("Titles").font(.cv(15, weight: .bold)).padding(.top, 8) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                    ForEach(results) { ClassicPosterCard(item: $0) }
                }
                if busy { Spinner() }
                else if results.isEmpty && people.isEmpty { Text("No results").foregroundColor(.secondary) }
            }.padding(40)
        }
        .background(bg)
        .task(id: query) {
            busy = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            async let titles = emby.search(query)
            async let persons = emby.searchPeople(query)
            results = await titles
            people = await persons
            busy = false
        }
    }

    /// Matching people as poster-sized portraits; each opens the person's page.
    var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.cv(15, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(people) { p in
                        NavigationLink(value: PersonRef(id: p.Id, name: p.Name)) {
                            VStack(spacing: 6) {
                                CachedImage(url: emby.image(p.Id, width: 360)) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.cv(50)).foregroundColor(.secondary) }
                                }
                                // Poster-sized portrait, like the other result cards
                                .frame(width: 150, height: 225).clipShape(RoundedRectangle(cornerRadius: 12))
                                .modifier(ClassicLightCard(radius: 12, size: CGSize(width: 150, height: 225)))   // the posters' light glass edge
                                .overlay(alignment: .topLeading) {
                                    if emby.isPersonFav(p.Id) {
                                        FavHeart(size: 16).padding(8)
                                    }
                                }
                                .modifier(HoverPersonHeart(id: p.Id, name: p.Name))
                                .classicHoverLift()
                                Text(p.Name).font(.cv(12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(width: 150)
                        }
                        .buttonStyle(.plainHand).accessibilityLabel("Show everything with \(p.Name)")   // no tooltip on actors
                    }
                }.padding(.vertical, 8)
            }
        }
        .task { _ = await emby.favoritePeople() }   // hearts on favorite people
    }
}

// MARK: - Favorites

/// Movies and shows marked as favorite, in two sections. Refreshes each time the page is shown,
/// and hides anything un-favorited from the detail page right away.
struct ClassicFavoritesView: View {
    @EnvironmentObject var emby: Emby
    /// "row" (scrolling row per section), "grid" or "list"; set in Settings → Libraries.
    @AppStorage("favoritesLayout") private var layout = "row"
    @Environment(\.appBG) var bg
    @State private var items: [Item] = []
    @State private var people: [Item] = []
    @State private var loading = true

    var body: some View {
        let favs = items.filter { emby.isFav($0) }
        let movies = favs.filter { !$0.isSeries && !$0.isBox && !$0.isEpisode }
        let shows = favs.filter { $0.isSeries }
        let episodes = favs.filter { $0.isEpisode }
        let collections = favs.filter { $0.isBox }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ClassicPageTitle(text: "Favorites", icon: "heart.fill")
                    if !favs.isEmpty { Text("\(favs.count) Items").foregroundColor(.secondary) }
                }
                if !movies.isEmpty { section("Favorite Movies", movies) }
                if !shows.isEmpty { section("Favorite Shows", shows) }
                if !episodes.isEmpty { section("Favorite Episodes", episodes) }
                if !collections.isEmpty { section("Favorite Collections", collections) }
                let favPeople = people.filter { emby.isFav($0) }
                if !favPeople.isEmpty { peopleSection(favPeople) }
                if loading && items.isEmpty { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if favs.isEmpty && !people.contains(where: { emby.isFav($0) }) {
                    VStack(spacing: 10) {
                        Image(systemName: "heart").font(.cv(40)).foregroundColor(.secondary)
                        Text("No favorites yet").font(.cv(13, weight: .bold))
                        Text("Tap the heart on a movie, show, collection, episode or person to add it here.").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .environment(\.inFavorites, true)   // no heart on the posters: everything here is a favorite
        .onAppear {
            Task { items = await emby.favorites(); loading = false }
            Task { people = await emby.favoritePeople() }
        }
        // Something was added or removed elsewhere (a cast photo, an episode): show it without leaving the page
        .onChange(of: emby.favRevision) {
            Task { items = await emby.favorites() }
            Task { people = await emby.favoritePeople() }
        }
    }

    /// Emby-style row: "Favorite Movies ›" heading (opens the full grid) and a scrolling row of posters.
    /// Portrait photos of favorite actors and directors, poster-sized; a click opens their page.
    /// Follows the Favorites layout (Row, Grid or List) like the other sections.
    func peopleSection(_ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // "Favorite People ›" opens all of them on their own page, like the other sections
            NavigationLink(value: FavoritePeopleRef()) {
                HStack(spacing: 6) {
                    Text("Favorite People").font(.cv(15, weight: .bold))
                    Image(systemName: "chevron.right").font(.cv(15, weight: .bold)).foregroundColor(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHand)
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { ClassicFavPersonCard(p: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { FavPersonListRow(p: $0, link: PersonRef(id: $0.id, name: $0.Name)) } }
            } else {
                let byId = Dictionary(list.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 150, spacing: 16, inset: 0) { id in
                    if let p = byId[id] { ClassicFavPersonCard(p: p) }
                }
            }
        }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        let byId = Dictionary(list.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 8) {
            // Opened through the page path (like every other page), so Back shows and the top bar can leave it
            NavigationLink(value: FavoriteGridRef(title: title, ids: list.map(\.Id))) {
                HStack(spacing: 6) {
                    Text3D(text: title, size: 16)
                    Text3D(image: Image(systemName: "chevron.right"), size: 16)
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHand).tip("Show all")
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { ClassicPosterCard(item: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { ListRow(item: $0) } }
            } else {
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 150, spacing: 16, inset: 0) { id in
                    if let it = byId[id] { ClassicPosterCard(item: it) }
                }
            }
        }
    }
}

struct ClassicFavoriteGridView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let title: String
    let ids: [String]
    @State private var items: [Item] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClassicPageTitle(text: title, icon: "heart.fill")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(items.filter { emby.isFav($0) }) { ClassicPosterCard(item: $0) }
                }
            }.padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .environment(\.inFavorites, true)   // no heart on the posters: everything here is a favorite
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: { dismiss() }) }
        .classicHideToolbarTitle()
        .task {
            let all = await emby.favorites()
            let set = Set(ids)
            items = all.filter { set.contains($0.Id) }
        }
    }
}

// MARK: - Now Playing (active sessions on the server)

// MARK: - Person

/// Everything in the user's libraries featuring one actor / director.
struct ClassicPersonView: View {
    @Environment(\.noBack) private var noBack
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let person: PersonRef
    @Environment(\.dismiss) var dismiss
    @State private var items: [Item] = []
    @State private var record: Item?
    @State private var loading = true

    var body: some View {
        let movies = items.filter { !$0.isSeries }
        let shows = items.filter { $0.isSeries }
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                // Same header as the Glass theme
                PersonHeader(id: person.id, name: person.name, record: record, items: items, loading: loading)
                Group {
                    if !movies.isEmpty { section("Movies", movies) }
                    if !shows.isEmpty { section("Shows", shows) }
                    if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                    else if items.isEmpty {
                        Text("Nothing in your libraries with \(person.name).").foregroundColor(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }.padding(.horizontal, 52)
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(bg)
        .navigationTitle(person.name)
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: noBack ? nil : { dismiss() }) }
        .classicHideToolbarTitle()
        .task {
            async let list = emby.itemsWithPerson(person.id)
            async let me = emby.person(person.id)
            items = await list
            record = await me
            loading = false
        }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text3D(text: title, size: 17)
                Text("\(list.count)").font(.cv(15, weight: .regular)).foregroundColor(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                ForEach(list) { ClassicPosterCard(item: $0) }
            }
        }
    }
}

// MARK: - Home

struct ClassicHomeContent: View {
    @AppStorage("classicBannerStyle") private var bannerStyle = "cinematic"
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @AppStorage("homeLayout") private var homeLayout = "row"
    @AppStorage("homeResumeLayout") private var resumeLayout = "row"
    let reloadToken: Int
    @State private var retry = 0
    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var pageH: CGFloat = .infinity

    var heroItems: [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for row in rows {
            for it in row.items.filter({ $0.backdropId != nil }).prefix(2) where !seen.contains(it.heroTitle) {
                seen.insert(it.heroTitle); out.append(it)
            }
        }
        return Array(out.prefix(8))
    }

    var body: some View {
        let hero = heroItems
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !hero.isEmpty { ClassicHero(items: hero, pageH: pageH) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.title).font(.cv(15, weight: .bold)).padding(.leading, 32)
                        let wide = row.title == "Continue Watching"
                        // Continue Watching has its own Row / Grid choice; every other section follows Home's
                        if (wide ? resumeLayout : homeLayout) == "grid" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 260 : 150), spacing: 14)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(row.items.indices, id: \.self) { i in
                                    if wide { ClassicResumeCard(item: row.items[i]) } else { ClassicPosterCard(item: row.items[i]) }
                                }
                            }.padding(.horizontal, 32)
                        } else if wide {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 260, spacing: 14, inset: 32) {
                                ClassicResumeCard(item: row.items[$0])
                            }
                        } else {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 150, spacing: 14, inset: 32) {
                                ClassicPosterCard(item: row.items[$0])
                            }
                        }
                    }
                }
                if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if rows.isEmpty, let m = emby.lastFailure {
                    // The server couldn't be reached: say so, instead of an empty page
                    ErrorStateView(message: m, retry: { loading = true; retry += 1 },
                                   switchServer: { emby.switchServer() }).padding(.top, 80)
                }
            }.padding(.bottom, 40)
        }
        // The banner runs up under the floating top bar (not the inset card)
        .ignoresSafeArea(edges: hero.isEmpty || bannerStyle == "card" ? [] : .top)
        // Height of the whole visible page, including the part under the top bar the banner runs up into
        .background(GeometryReader { g in
            Color.clear.onAppear { pageH = g.size.height }.onChange(of: g.size.height) { _, h in pageH = h }
        }.ignoresSafeArea(edges: bannerStyle == "card" ? [] : .top))
        .background(bg)
        .task(id: "\(reloadToken)-\(retry)") { rows = await emby.loadHome(); loading = false }
    }
}

extension View {
    /// Black outline around text (four hairline shadows plus a soft one) so it reads on any picture.
    func classicBlackOutline(_ w: CGFloat = 1) -> some View {
        self.shadow(color: .black, radius: 0, x: w, y: 0).shadow(color: .black, radius: 0, x: -w, y: 0)
            .shadow(color: .black, radius: 0, x: 0, y: w).shadow(color: .black, radius: 0, x: 0, y: -w)
            .shadow(color: .black.opacity(0.7), radius: 4)
    }
}

/// A series' seasons stacked like playing cards (as the Home banner's deck): the shown season in front, the ones
/// after it peeking out behind; glass ‹ › beside it. Changing season cross-fades the whole deck.
struct SeasonDeck: View {
    let numbers: [Int]
    let selected: Int
    let title: (Int) -> String
    let image: (Int) -> URL?
    let select: (Int) -> Void
    /// Front card extras, as on the season posters: unwatched count (top right), Watched / Favorite on hover
    let badge: (Int) -> Int?
    let seasonItem: (Int) -> Item?
    let episodes: (Int) -> [Item]
    /// Collections: the line under the deck (the front movie's year, so the order is clear), the movie the front
    /// card opens, and what the arrows step through
    var caption: ((Int) -> String?)? = nil
    var link: ((Int) -> Item?)? = nil
    /// Collections: whether each movie is watched (the check on every card, top right, as on posters)
    var watched: ((Int) -> Bool)? = nil
    var noun = "season"
    private let w: CGFloat = 280, h: CGFloat = 420
    @AppStorage("accent") private var accentName = "red"
    private let peek: CGFloat = 40

    /// The deck's own position; the page's season follows it (and the deck follows the page when the season
    /// changes elsewhere).
    @State private var pos = -1
    @State private var swipe = DeckSwipe()
    var shownPos: Int { pos >= 0 ? pos : (numbers.firstIndex(of: selected) ?? 0) }

    var body: some View {
        HStack(spacing: 12) {
            arrow("chevron.left", "Previous \(noun)", enabled: shownPos > 0) { go(shownPos - 1) }
            VStack(alignment: .leading, spacing: 10) {
                cards
                if let caption, numbers.indices.contains(shownPos), let c = caption(numbers[shownPos]) {
                    Text(c).font(.cv(15, weight: .semibold)).foregroundColor(.white).classicBlackOutline()
                        .frame(width: w).id(shownPos).transition(.opacity)   // centered under the front card
                }
            }
            arrow("chevron.right", "Next \(noun)", enabled: shownPos < numbers.count - 1) { go(shownPos + 1) }
        }
        .onHover { swipe.hover($0) }
        .onAppear {
            pos = numbers.firstIndex(of: selected) ?? 0
            let box = swipe
            swipe.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard box.inside, let step = box.step(e) else { return box.inside && box.horizontal ? nil : e }
                // Past the first or last card the page scrolls on instead
                guard numbers.indices.contains(shownPos + step) else { return e }
                go(shownPos + step)
                return nil
            }
        }
        .onDisappear { if let m = swipe.monitor { NSEvent.removeMonitor(m); swipe.monitor = nil } }
        .onChange(of: selected) { _, s in
            if let i = numbers.firstIndex(of: s), i != pos { pos = i }
        }
    }

    func arrow(_ icon: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(help, systemImage: icon).classicGlassPill(size: 40) }
            .buttonStyle(HoverButton()).helpLabel(help)
            .disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    /// Shows season `p`: the whole deck cross-fades to its new stack.
    func go(_ p: Int) {
        guard p >= 0, p < numbers.count, p != shownPos else { return }
        withAnimation(.easeInOut(duration: 0.35)) { pos = p }
        select(numbers[p])
    }

    var cards: some View {
        let pos = shownPos
        let shown = min(numbers.count - pos, 4)
        return ZStack(alignment: .leading) { stack(pos, shown) }
            .frame(width: w + CGFloat(3) * peek, height: h, alignment: .leading)
    }

    /// One whole stack, keyed by its position: a new position replaces the stack as one piece with a plain
    /// cross-fade (the same both ways)
    func stack(_ pos: Int, _ shown: Int) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array((pos..<(pos + shown)).reversed()), id: \.self) { p in
                let k = p - pos
                deckButton(p, k: k) {
                    card(numbers[p], k: k)
                        .overlay(alignment: .topTrailing) {
                            if let watched {
                                if watched(numbers[p]) { TubeBadge(count: nil).helpLabel("Watched").padding(10) }
                            } else if k == 0 { CountBadge(count: badge(numbers[p])).padding(10) }
                        }
                }
                .modifier(FrontActions(on: k == 0, item: seasonItem(numbers[p]), episodes: episodes(numbers[p])))
                    .buttonStyle(.plainHand)
                    .accessibilityLabel(title(numbers[p]))   // no tooltip: the card shows its name
                    .scaleEffect(1 - CGFloat(k) * 0.08, anchor: .trailing)
                    .offset(x: CGFloat(k) * peek)
            }
        }
        .id(pos)
        .transition(.opacity)
    }

    /// The front card of a collection opens its movie; every other card brings itself to the front.
    @ViewBuilder func deckButton<L: View>(_ p: Int, k: Int, @ViewBuilder label: () -> L) -> some View {
        if k == 0, let link, let it = link(numbers[p]) {
            NavigationLink(value: it) { label() }
        } else {
            Button { go(p) } label: { label() }
        }
    }

    func card(_ n: Int, k: Int) -> some View {
        CachedImage(url: image(n)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { ZStack { Color(white: 0.15); Text(title(n)).font(.cv(10, weight: .regular)) } }
        .frame(width: w, height: h).clipped()   // no name on the card: season and movie covers show their own
        .cornerRadius(10)
        .modifier(ClassicLightCard(radius: 10, accent: Theme.accent(accentName), size: CGSize(width: w, height: h),
                                   tracksHover: k == 0))   // the posters' light glass edge; glow on the front card
        .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(Double(k) * 0.22)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

/// A two-finger trackpad swipe over a card deck: one card per swipe (left = next, right = previous), whatever
/// the swipe's length; the page keeps scrolling up and down as usual. A mouse wheel turned over the deck steps
/// through it too (down = next), unless the page was already scrolling when the deck came under the pointer.
final class DeckSwipe {
    var monitor: Any?
    var inside = false
    /// The pointer came onto the deck while the page stood still: the mouse wheel is the deck's
    private var wheelArmed = false
    private var lastWheelStep = Date.distantPast
    private var wheelTravel: CGFloat = 0

    @MainActor func hover(_ h: Bool) {
        inside = h
        wheelArmed = h && !ScrollActivity.scrolling
    }
    /// This swipe goes sideways (its events are the deck's, not the page's)
    var horizontal = false
    private var dx: CGFloat = 0
    private var fired = false

    /// The step this event completes (+1 next, -1 previous), or nil.
    func step(_ e: NSEvent) -> Int? {
        // The coasting after the fingers lift belongs to the swipe already counted
        if !e.momentumPhase.isEmpty { return nil }
        if e.phase == .began || e.phase == .mayBegin { dx = 0; fired = false; horizontal = false }
        // A mouse wheel: no phases at all (a trackpad marks every event with its swipe or coasting phase).
        // macOS smooths each notch into a short stream of small steps (about 50 points in all), so a card turns
        // after 45 points: one per notch. Sideways always; up and down once armed.
        if e.phase.isEmpty && e.momentumPhase.isEmpty {
            horizontal = false
            let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : (wheelArmed ? e.scrollingDeltaY : 0)
            guard d != 0 else { return nil }
            horizontal = true   // this tick is the deck's
            if Date().timeIntervalSince(lastWheelStep) > 0.3 { wheelTravel = 0 }   // a new notch
            lastWheelStep = Date()
            wheelTravel += e.hasPreciseScrollingDeltas ? d : d * 50
            guard abs(wheelTravel) >= 45 else { return nil }
            let step = wheelTravel < 0 ? 1 : -1
            wheelTravel = 0   // the rest of this notch's stream doesn't add up to another card
            return step
        }
        if e.phase.isEmpty { dx = 0; fired = false; horizontal = false }
        if e.phase == .ended || e.phase == .cancelled { horizontal = false; return nil }
        if !horizontal {
            guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return nil }
            horizontal = true
        }
        dx += e.scrollingDeltaX
        guard !fired, abs(dx) > 40 else { return nil }
        fired = true
        return dx < 0 ? 1 : -1   // fingers to the left bring the next card
    }
}

/// The subtitle appearance panel: dark glass in the Classic theme, the plain grey panel otherwise.
struct AppearanceSurface: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(PanelSurface(classic: true)).padding(.vertical, 24).padding(.trailing, 24) }
        else { content.background(Color(white: 0.16).opacity(0.97)) }
    }
}

/// A text field as a glass capsule (sign-in form).
struct GlassField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.cv(13)).foregroundColor(.white)
            .padding(.horizontal, 16).frame(height: 38)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .background(ClassicGlassBacking(shape: Capsule()))
    }
}

/// Timeline preview picture: the glass card frame in the Classic theme, a white outline otherwise.
struct PreviewFrame: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.classicThinBorder(10).shadow(color: .black.opacity(0.5), radius: 8, y: 3) }
        else { content.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6), lineWidth: 1)) }
    }
}

/// The time above the timeline: a dark glass capsule in the Classic theme.
struct TimeBubble: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            content.background(Capsule().fill(Color.black.opacity(0.55))).background(ClassicGlassBacking(shape: Capsule()))
        } else {
            content.background(Capsule().fill(Color.black.opacity(0.7)))
        }
    }
}

/// Classic slider (timeline, volume): a slim glass capsule, the filled part in see-through accent with a glow, and a
/// small white knob that shows under the pointer or while dragging.
struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditing: (Bool) -> Void = { _ in }
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        let accent = Theme.accent(accentName)
        GeometryReader { g in
            let span = max(range.upperBound - range.lowerBound, 0.000_1)
            let frac = CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
            let thick: CGFloat = hover || dragging ? 8 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35)).frame(height: thick)
                ClassicGlassBacking(shape: Capsule()).frame(height: thick)
                Capsule().fill(accent.opacity(0.55))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center)))
                    .frame(width: max(thick, g.size.width * frac), height: thick)
                    .shadow(color: accent.opacity(0.8), radius: 4)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .offset(x: g.size.width * frac - 7)
                    .opacity(hover || dragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    if !dragging { dragging = true; onEditing(true) }
                    value = range.lowerBound + Double(min(1, max(0, d.location.x / max(g.size.width, 1)))) * span
                }
                .onEnded { _ in dragging = false; onEditing(false) })
        }
        .frame(height: 18)
        .onHover { hover = ScrollActivity.hover(hover, $0) }
        .animation(.easeOut(duration: 0.12), value: hover || dragging)
    }
}

/// Top bar and switch hover: the chosen hover look (Settings) shaped like the selected section's pill, no pill itself.
struct SectionHoverGlow: ViewModifier {
    let on: Bool
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background {
                // The chosen hover look, as the buttons
                ClassicHoverEffect()
                    .opacity(on && hover ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// The playback info box: the side panel's dark glass in the Classic theme, a plain dark box otherwise.
struct InfoSurface: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(PanelSurface(classic: true)) }
        else { content.background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75))) }
    }
}

/// The player's side panel: dark glass framed like the buttons in the Classic theme, the frosted panel otherwise.
struct PanelSurface: ViewModifier {
    let classic: Bool
    @Environment(\.appBG) private var bg
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if classic {
            content.background(shape.fill(bg.opacity(0.75))).clipShape(shape)
                .modifier(ClassicClearGlass(shape: shape))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        } else {
            content.background(.ultraThinMaterial.opacity(0.95)).background(Color(white: 0.15).opacity(0.85))
                .cornerRadius(14)
        }
    }
}

/// Classic progress on a card, bottom-right, styled like the glass Play button: a glass ring (dark see-through
/// track lit from the top, light-catching rims) and the watched part in see-through accent with a shine and a glow.
/// Drawn by hand (no system glass), so a row of cards stays smooth to scroll.
struct ClassicProgressCircle: View {
    let progress: Double   // 0...1
    var size: CGFloat = 26
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.displayScale) private var scale
    var body: some View {
        // Drawn once per whole percent, size and accent (see Raster): it's eight layers with glowing shadows
        let pct = Int((min(1, max(0.03, progress)) * 100).rounded())
        Raster.view("ring\(pct)|\(size)|\(accentName)", scale: scale, pad: 12) { drawing(CGFloat(pct) / 100) }
    }
    @ViewBuilder func drawing(_ p: CGFloat) -> some View {
        let accent = Theme.accent(accentName)
        let w: CGFloat = 5
        ZStack {
            // glass track
            Circle().stroke(Color.black.opacity(0.4), lineWidth: w)
            Circle().stroke(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                            lineWidth: w)
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5).frame(width: size + w, height: size + w)
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5).frame(width: size - w, height: size - w)
            // watched part
            Group {
                Circle().trim(from: 0, to: p)
                    .stroke(accent.opacity(0.42), style: StrokeStyle(lineWidth: w - 1, lineCap: .round))
                    .shadow(color: accent.opacity(0.9), radius: 4)
                    .shadow(color: accent.opacity(0.5), radius: 8)
                Circle().trim(from: 0, to: p)
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: size + 1.5, height: size + 1.5)
            }.rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .frame(width: size + w, height: size + w)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

/// Watched / Favorite buttons on hover (bottom right), only on the deck's front card.
private struct FrontActions: ViewModifier {
    let on: Bool
    let item: Item?
    let episodes: [Item]
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.hoverItemActions(item, .bottomTrailing, children: episodes) } else { content }
    }
}

/// The banner's outline: full width (cinematic, panel) or an inset card with the glass frame.
private struct BannerShape: ViewModifier {
    let card: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if card {
            content.clipShape(RoundedRectangle(cornerRadius: 18))
                .modifier(ClassicLightCard(radius: 18))   // the posters' light glass edge, drawn once per size
                .padding(.horizontal, 32)
        } else {
            content.clipped()
        }
    }
}

/// Home banner, cinematic: the picture runs edge to edge up under the floating top bar, the title logo, facts,
/// description and glass buttons sit on a dark fade at the left; glass page bullets at the bottom and glass arrows at
/// the sides on hover.
struct ClassicHero: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let items: [Item]
    var pageH: CGFloat = .infinity
    /// Banners moved through so far (back = −1); never wraps, so each card in the deck keeps its own identity
    @State private var pos = 0
    var index: Int { items.isEmpty ? 0 : ((pos % items.count) + items.count) % items.count }
    @State private var leaving: Item?       // the deck's front card while it fades away
    @State private var busy = false
    @State private var leavingGone = false
    @State private var hover = false
    @State private var width: CGFloat = 1200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback = PlaybackFlag.shared
    @ObservedObject private var nav = ClassicNavState.shared
    /// Settings → General → Home banner: "cinematic" (edge to edge), "panel" (text on a glass panel) or "card"
    /// (an inset glass-framed card)
    @AppStorage("classicBannerStyle") private var style = "cinematic"
    /// Settings → General → Banner navigation: "deck" (cards, bottom right) or "bullets" (bottom center)
    @AppStorage("classicBannerNav") private var bannerNav = "deck"
    /// The whole visible page, so the rows (Continue Watching…) start just below it and show once you scroll
    var bannerH: CGFloat { pageH.isFinite ? max(pageH, 360) : max(width * 9 / 16, 520) }

    func meta(_ item: Item) -> String {
        var m: [String] = [item.isEpisode || item.isSeries ? "TV Show" : "Movie"]
        m += (item.Genres ?? []).prefix(2)
        if let y = item.ProductionYear { m.append(String(y)) }
        return m.joined(separator: " · ")
    }

    /// Shows banner `i` (any integer; wraps). One back steps back; anything else moves forward through the deck.
    func go(_ i: Int) {
        let n = items.count
        guard n > 0, !busy else { return }
        if !reduceMotion {
            busy = true   // clicks during a move wait for it to finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { busy = false }
        }
        let d = (((i - index) % n) + n) % n
        let back = d == n - 1 && n > 2
        // Moving forward: keep the front card on screen as a copy and fade it away over the deck
        if !back && d > 0 && n > 1 && !reduceMotion {
            leaving = items[(index + 1) % n]
            leavingGone = false
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.7)) { leavingGone = true }
            }
            let id = leaving?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { if leaving?.id == id { leaving = nil } }
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { pos += back ? -1 : d }
    }

    var body: some View {
        let item = items[index % items.count]
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: bannerH)
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: min(Int(width * 2), 2560)) }.clipped()   // Retina-sharp
                // The new picture fades in over the old one, which stays solid underneath until it is covered (both
                // half see-through at once made the banner dim mid-change)
                .id("b" + item.id)
                .transition(.asymmetric(insertion: .opacity,
                                        removal: .opacity.animation(.linear(duration: 0.05).delay(0.7))))
                .zIndex(Double(pos))
            fades.zIndex(Double(pos) + 0.5)
            Group {
                if style == "panel" {
                    info(item).padding(24)
                        .modifier(ClassicClearGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.35)))
                } else { info(item) }
            }
            .padding(.leading, style == "card" ? 44 : 80).padding(.bottom, 56)
            // Old text fades out quickly, then the new text fades in (they overlapped mid-change)
            .id("t" + item.id)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.3)),
                                    removal: .opacity.animation(.easeIn(duration: 0.25))))
            .zIndex(Double(pos) + 0.6)
            // The coming banners as a deck of cards, bottom right (above the changing picture and text)
            Group {
                if items.count > 1 {
                    if bannerNav == "bullets" {
                        thumbs.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 26)
                    } else {
                        deck.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.trailing, 44).padding(.bottom, 56)
                    }
                }
            }.zIndex(Double(pos) + 1)
        }
        .animation(.easeOut(duration: 0.15), value: hover)
        .frame(height: style == "card" ? max(bannerH - 24, 340) : bannerH)
        .modifier(BannerShape(card: style == "card"))
        .foregroundColor(.white)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        .onHover { hover = ScrollActivity.hover(hover, $0) }
        .onChange(of: nav.bannerNudge) { _, n in if let n, !items.isEmpty { go(index + n.dir) } }   // ← → keys
        // Next banner every 9 s, but not under the pointer, not during playback and not with Reduce Motion
        .task(id: "\(pos)-\(hover)-\(playback.active)") {
            guard !hover, !playback.active, !reduceMotion, items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !Task.isCancelled { go(index + 1) }
        }
    }

    /// Dark fades so the text reads: from the left and into the page (cinematic), only at the bottom (panel: the
    /// glass panel carries the text), or inside the card.
    @ViewBuilder var fades: some View {
        if style != "panel" {
            LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.6)],
                           startPoint: .leading, endPoint: .trailing)
        }
        if style == "card" {
            LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: bg.opacity(0.7), location: 0.8),
                                   .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }

    func info(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.isEpisode {
                Text("S\(item.ParentIndexNumber ?? 0) · E\(item.IndexNumber ?? 0)").font(.cv(13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            TitleLogo(item: item, height: style == "cinematic" ? 110 : 90, font: style == "cinematic" ? 56 : 46)
            HStack(spacing: 10) {
                Text(meta(item))
                if let r = item.CommunityRating {
                    HStack(spacing: 3) { Image(systemName: "star.fill"); Text(String(format: "%.1f", r)) }
                }
            }.font(.cv(15, weight: .medium)).foregroundColor(.white.opacity(0.9))
            Text(item.Overview ?? "").font(.cv(15)).lineLimit(3)
                .foregroundColor(.white.opacity(0.8)).frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 12) {
                Button { Task { await emby.play(item) } } label: {
                    Label(emby.resumeAt(item) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                        .classicGlassPill(size: 46, iconOnly: false)
                }.buttonStyle(HoverButton())
                let fav = emby.isFav(item)
                Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                    Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "checkmark" : "plus")
                        .classicGlassPill(size: 46)
                }.buttonStyle(HoverButton()).helpLabel(fav ? "Remove from Favorites" : "Add to Favorites")
                NavigationLink(value: item) {
                    Label("More Info", systemImage: "info").classicGlassPill(size: 46)
                }.buttonStyle(HoverButton()).helpLabel("More Info")
            }.padding(.top, 6)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// The coming banners stacked like playing cards: the next one in front, the ones after it peeking out behind, each a
    /// little smaller, further right and dimmer. Moving on, the front card fades away (growing slightly) and the one
    /// beneath slides up into its place. Clicking a card shows that banner.
    var deck: some View {
        let shown = min(items.count - 1, 4)
        return ZStack(alignment: .leading) {
            // Drawn back to front, so the next banner's card ends up on top
            ForEach(Array(((pos + 1)..<(pos + 1 + shown)).reversed()), id: \.self) { p in
                let k = p - pos - 1
                let i = ((p % items.count) + items.count) % items.count
                Button { go(i) } label: { deckCard(items[i], k: k) }
                    .buttonStyle(.plainHand)
                    .accessibilityLabel(items[i].heroTitle)   // no tooltip: the card shows its title
                    .scaleEffect(1 - CGFloat(k) * 0.08, anchor: .trailing)
                    .offset(x: CGFloat(k) * 26)
                    // The front card leaves at once (its fading copy takes over; two fading copies overlapped into a
                    // ghost); a card at the back fades in or out instead of popping
                    .transition(.asymmetric(insertion: .opacity, removal: k == 0 ? .identity : .opacity))
            }
            // Moving forward: the card that was in front, drawn over the deck, fading away (growing slightly and
            // drifting left) while the one beneath takes its place
            if let l = leaving {
                deckCard(l, k: 0)
                    .scaleEffect(leavingGone ? 1.08 : 1)
                    .offset(x: leavingGone ? -30 : 0)
                    .opacity(leavingGone ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: deckW + CGFloat(shown - 1) * 26, height: deckW * 9 / 16, alignment: .leading)
    }

    private let deckW: CGFloat = 300
    @AppStorage("accent") private var accentName = "red"

    func deckCard(_ it: Item, k: Int) -> some View {
        CachedImage(url: emby.image(it.backdropId ?? it.Id, "Backdrop", width: 520)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.15) }
        .frame(width: deckW, height: deckW * 9 / 16).clipped()   // no name on the card (the banner beside it says it)
        .cornerRadius(12)
        .modifier(ClassicLightCard(radius: 12, accent: Theme.accent(accentName), size: CGSize(width: deckW, height: deckW * 9 / 16),
                                   tracksHover: k == 0))   // the posters' light glass edge; glow on the front card
        .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(Double(k) * 0.22)))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// Page bullets: small glass pills; the current one stretches longer and is lit.
    var thumbs: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == index % items.count
                Button { go(i) } label: {
                    Capsule().fill(Color.white.opacity(on ? 0.85 : 0.25))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.15)],
                                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                        .frame(width: on ? 26 : 9, height: 9)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(HoverButton())
                .accessibilityLabel("Banner \(i + 1) of \(items.count): \(items[i].heroTitle)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.25), value: index)
    }

}

/// Landscape card for the Continue Watching row: still image, accent progress bar, time left.
struct ClassicResumeCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false
    @AppStorage("accent") private var accentName = "red"

    var progress: Double { min(1, max(0, (item.UserData?.PlayedPercentage ?? 0) / 100)) }
    var timeLeft: String? {
        guard let total = item.RunTimeTicks, total > 0 else { return nil }
        let left = max(0, total - (item.UserData?.PlaybackPositionTicks ?? 0))
        return runtimeText(left) + " left"
    }
    var subtitle: String? {
        if item.isEpisode { return "S\(item.ParentIndexNumber ?? 0)·E\(item.IndexNumber ?? 0)" + (timeLeft.map { " · " + $0 } ?? "") }
        return timeLeft
    }
    /// Card click: an episode opens its series page on that episode's season; a movie opens its own page.
    func openPage() {
        guard item.isEpisode, let sid = item.SeriesId else { emby.openRequest = item; return }
        Task {
            if let series = await emby.itemRecord(sid) {
                emby.openSeason = item.ParentIndexNumber
                emby.openRequest = series
            }
        }
    }

    /// Episodes have a landscape primary image; movies use their backdrop.
    var imageURL: URL? {
        item.isEpisode ? emby.image(item.Id, width: 520, plain: true) : emby.image(item.backdropId ?? item.Id, "Backdrop", width: 520)
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: imageURL) { p in
                    p.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.15); Text(item.heroTitle).font(.cv(10, weight: .regular)).padding(6) }
                }
                .frame(width: 260, height: 146).clipped()
                // Title, bottom-left
                .overlay(alignment: .bottomLeading) {
                    // No background: a black outline keeps it readable
                    Text(item.heroTitle)
                        .font(.cv(12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        .classicBlackOutline()
                        .padding(.leading, 10).padding(.trailing, 44).padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Series info (S3·E3 · 42m left), top-left
                .overlay(alignment: .topLeading) {
                    if let subtitle {
                        Text(subtitle).font(.cv(10, weight: .semibold)).foregroundColor(.white)
                            .classicBlackOutline().padding(10)
                    }
                }
                // How far you got, bottom-right
                .overlay(alignment: .bottomTrailing) {
                    if progress > 0 && progress < 1 { ClassicProgressCircle(progress: progress).padding(8) }
                }
                // Play button: resumes playback; clicking anywhere else on the card opens the page
                .overlay {
                    if hover {
                        Button { Task { await emby.play(item) } } label: {
                            Label("Resume", systemImage: "play.fill").classicGlassPill(size: 46)
                        }.buttonStyle(.plainHand).accessibilityLabel("Resume")
                    }
                }
                .cornerRadius(8)
                .modifier(ClassicLightCard(radius: 8, hover: hover, accent: Theme.accent(accentName),
                                           size: CGSize(width: 260, height: 146)))   // the posters' light glass edge
                .classicHoverLift()
            }
            .frame(width: 260, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hover = ScrollActivity.hover(hover, $0) }
            .onTapGesture { openPage() }.handCursor()
            // Keyboard and VoiceOver: one element that opens the page (Return), with Resume as an action; the
            // Resume button itself only shows under the pointer
            .focusable()
            .focusEffectDisabled()   // no blue macOS focus ring after a click
            .onKeyPress(.return) { openPage(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(timeLeft ?? "")
            .accessibilityAction { openPage() }
            .accessibilityAction(named: "Resume") { Task { await emby.play(item) } }
            .accessibilityLabel(item.isEpisode ? "\(item.heroTitle) — \(item.Name)" : item.Name)   // no tooltip on these cards
        }
    }
}

struct ClassicBackdrop: View {
    @EnvironmentObject var emby: Emby
    let id: String
    var body: some View {
        CachedImage(url: emby.image(id, "Backdrop", width: 1600)) { p in
            p.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.1) }
    }
}

struct ClassicPosterCard: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.inFavorites) private var inFavorites
    @AppStorage("accent") private var accentName = "red"
    let item: Item
    @State private var hover = false
    // Settings → Libraries → Poster labels
    @AppStorage("posterShowTitle") private var showTitle = true
    @AppStorage("posterShowYear") private var showYear = true
    @AppStorage("posterLabelAlign") private var labelAlign = "center"
    var centered: Bool { labelAlign == "center" }
    @State private var ptr = PointerBox()    // pointer position on the poster (read lazily, no redraws)
    var body: some View {
        let played = emby.isPlayed(item)
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CachedImage(url: emby.image(item.posterId, width: 360)) { p in
                        p.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack { Color(white: 0.15); Text(item.Name).font(.cv(10, weight: .regular)).padding(6) }
                    }
                    .frame(width: 150, height: 225).clipped()
                    .opacity(played ? 0.6 : 1)
                    WatchBadge(item: item, played: played).padding(8)
                }
                .overlay(alignment: .topLeading) {
                    // Favorite heart, then your Trakt rating
                    HStack(spacing: 6) {
                        if emby.isFav(item) && !inFavorites {
                            // A glossy accent heart, like the rating star beside it
                            FavHeart(size: 22).helpLabel("Favorite")   // as big as the rating star beside it
                        }
                        MyRatingBadge(item: item)
                    }.padding(8)
                }
                .overlay(alignment: .bottom) {
                    if let pct = item.UserData?.PlayedPercentage, pct > 0, pct < 100, !played {
                        ProgressView(value: pct / 100).padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hover { ItemActionsButton(item: item).padding(8) }   // shows while the pointer is on the poster
                }
                .cornerRadius(8)
                .modifier(ClassicLightCard(radius: 8, hover: hover, accent: Theme.accent(accentName), size: CGSize(width: 150, height: 225)))
                // The Netflix-style preview card is drawn by ClassicHoverCardLayer (window level), centered on this poster.
                // Local + global pointer positions together give the poster's place in the window.
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let p) = phase { ptr.local = p }
                }
                .onContinuousHover(coordinateSpace: .global) { phase in
                    switch phase {
                    case .active(let p):
                        ptr.global = p
                        if !ptr.inside && !ScrollActivity.scrolling {   // not for posters scrolling past
                            ptr.inside = true
                            let box = ptr
                            ClassicHoverCardCenter.shared.posterHover(item, inside: true) {
                                CGRect(x: box.global.x - box.local.x, y: box.global.y - box.local.y, width: 150, height: 225)
                            }
                        }
                    case .ended:
                        ptr.inside = false
                        ClassicHoverCardCenter.shared.posterHover(item, inside: false) { .zero }
                    }
                }
                .modifier(HoverLift(hover: hover))
                if showTitle || showYear {
                    VStack(alignment: centered ? .center : .leading, spacing: 2) {
                        if showTitle { Text(item.Name).font(.cv(12, weight: .semibold)).lineLimit(1) }
                        if showYear { Text(item.yearText).font(.cv(10, weight: .regular)).foregroundColor(.secondary) }
                    }
                    .multilineTextAlignment(centered ? .center : .leading)
                    .frame(width: 150, alignment: centered ? .center : .leading)
                }
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { h in if !h || !ScrollActivity.scrolling { hover = h } }   // not while scrolling past
            .zIndex(hover ? 1 : 0)
        }.buttonStyle(.plainHand)
    }
}

/// Decides which poster's preview card is showing. Opens ~0.7 s after the pointer rests on a poster and stays
/// while the pointer is on the poster or on the card; closes ~0.3 s after it leaves both. Never while a video is
/// playing (the page behind the player is still alive). Closing is decided by polling the real pointer position,
/// so it doesn't depend on hover enter/exit events firing for a card that appears right under a resting pointer.
@MainActor
final class ClassicHoverCardCenter: ObservableObject {
    static let shared = ClassicHoverCardCenter()
    @Published var item: Item?
    @Published var anchor: CGRect = .zero        // the poster's frame in window coordinates
    var cardRect: CGRect = .zero                 // the card's frame in window coordinates (set by ClassicHoverCardLayer)
    private var overPoster: Item?
    private var anchorFor: (() -> CGRect)?
    private var openTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    /// Settings → Libraries → Hover preview
    private var enabled: Bool { UserDefaults.standard.object(forKey: "hoverPreviewEnabled") as? Bool ?? true }
    private var openDelayMs: Int {
        let d = UserDefaults.standard.double(forKey: "hoverPreviewDelay")      // seconds; unset = 0.7
        return Int((d > 0 ? d : 0.7) * 1000)
    }

    func posterHover(_ it: Item, inside: Bool, anchorProvider: @escaping () -> CGRect) {
        if inside { overPoster = it; anchorFor = anchorProvider }
        else if overPoster?.id == it.id { overPoster = nil }
        openTask?.cancel()
        guard inside, enabled, !PlaybackFlag.shared.active, item?.id != it.id else { return }
        openTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(openDelayMs))   // same delay for every poster
            if Task.isCancelled || PlaybackFlag.shared.active { return }
            guard overPoster?.id == it.id, let a = anchorFor?() else { return }
            item = it
            anchor = a
            startWatching()
        }
    }

    /// Closes everything (Play pressed, playback started).
    func hide() {
        openTask?.cancel(); watchTask?.cancel()
        item = nil; overPoster = nil
    }

    /// Closes just the card because the pointer left it. A card that is already waiting to open for the poster
    /// under the pointer must survive this (it used to be cancelled here, so the poster you moved onto never opened).
    private func closeCard() {
        watchTask?.cancel()
        item = nil
    }

    /// Scrolling with the card open: close it, so the wheel scrolls the page under it (the card would take it)
    private var scrollMonitor: Any?
    private func watchScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.item != nil else { return e }
            self.closeCard()
            // Hand this tick to the page under the pointer, as the card is still in the way for it
            if let w = e.window, let v = w.contentView?.hitTest(e.locationInWindow) {
                var sv: NSView? = v
                while let s = sv, !(s is NSScrollView) { sv = s.superview }
                if let scroll = sv as? NSScrollView { scroll.scrollWheel(with: e); return nil }
            }
            return e
        }
    }

    private func startWatching() {
        watchScroll()
        watchTask?.cancel()
        watchTask = Task { @MainActor in
            var away = 0
            while !Task.isCancelled && item != nil {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if PlaybackFlag.shared.active { hide(); return }
                away = pointerInside() || RatingButton.pickerOpen ? 0 : away + 1   // the star picker sits outside the card
                if away >= 3 { closeCard(); return }
            }
        }
    }

    /// Is the pointer over the poster or the card? (window coordinates with the origin at the top-left, like SwiftUI's .global)
    private func pointerInside() -> Bool {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow, let v = w.contentView else { return false }
        let m = w.mouseLocationOutsideOfEventStream
        let pt = CGPoint(x: m.x, y: v.bounds.height - m.y)
        return anchor.insetBy(dx: -4, dy: -4).contains(pt) || cardRect.insetBy(dx: -4, dy: -4).contains(pt)
    }
}

/// Window-level layer that draws the preview card centered on the hovered poster (kept inside the window),
/// above every row and column, so nothing clips or covers it.
/// The card zooms out of the middle of the poster when it opens and back into it when it closes
/// (Settings → Libraries → Hover preview: zoom on/off and duration).
struct ClassicHoverCardLayer: View {
    @ObservedObject private var center = ClassicHoverCardCenter.shared
    @AppStorage("hoverZoomEnabled") private var zoomOn = true
    @AppStorage("hoverZoomDuration") private var zoomDur = 0.3
    @AppStorage("hoverZoomStyle") private var zoomStyle = "spring"      // "smooth" | "spring"
    @State private var cardH: CGFloat = 340
    // The card stays on screen while it zooms back in, so the layer keeps its own copy of what it shows
    @State private var shownItem: Item?
    @State private var shownAnchor: CGRect = .zero
    @State private var open = false
    @State private var removeTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { g in
            if let it = shownItem {
                let o: CGPoint = g.frame(in: .global).origin
                let w: CGFloat = 320
                let cx: CGFloat = shownAnchor.midX - o.x
                let cy: CGFloat = shownAnchor.midY - o.y
                let left: CGFloat = min(max(8, cx - w / 2), max(8, g.size.width - w - 8))
                let top: CGFloat = min(max(8, cy - cardH / 2), max(8, g.size.height - cardH - 8))
                let rect = CGRect(x: o.x + left, y: o.y + top, width: w, height: cardH)
                // The card pivots on the poster's center and shrinks to poster size when it is not open
                let ux: CGFloat = min(max((shownAnchor.midX - rect.minX) / w, 0), 1)
                let uy: CGFloat = min(max((shownAnchor.midY - rect.minY) / cardH, 0), 1)
                HoverPreview(item: it) { center.hide() }
                    .frame(width: w)
                    .background(GeometryReader { c in Color.clear.preference(key: CardHeightKey.self, value: c.size.height) })
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .modifier(ClassicLightCard(radius: 12))
                    .shadow(color: .black.opacity(0.6), radius: 24)
                    .scaleEffect(open ? 1 : 150 / w, anchor: UnitPoint(x: ux, y: uy))
                    .opacity(open ? 1 : 0)
                    .animation(zoomOn ? zoomAnimation : nil, value: open)
                    .allowsHitTesting(open)
                    .onAppear { center.cardRect = rect }
                    .onChange(of: rect) { _, r in center.cardRect = r }
                    .offset(x: left, y: top)
                    .id(it.id)
            }
        }
        .onPreferenceChange(CardHeightKey.self) { cardH = $0 }
        .onChange(of: center.item?.id) { _, _ in sync() }
    }

    /// Smooth ease, or a spring with a small bounce; the same one is used for opening and closing.
    private var zoomAnimation: Animation {
        zoomStyle == "spring" ? .spring(response: zoomDur, dampingFraction: 0.82) : .easeInOut(duration: zoomDur)
    }

    /// Follows the hover center: a new poster zooms its card out, a closed card zooms back in and is then removed.
    private func sync() {
        removeTask?.cancel()
        if let it = center.item {
            if shownItem?.id != it.id {
                shownItem = it
                shownAnchor = center.anchor
                if zoomOn {
                    open = false
                    DispatchQueue.main.async { open = true }   // next tick, so the change animates from poster size
                } else {
                    open = true
                }
            } else {
                open = true
            }
        } else {
            open = false
            let wait: Double = zoomOn ? (zoomStyle == "spring" ? zoomDur * 1.4 : zoomDur) : 0   // a spring settles a bit later
            removeTask = Task { @MainActor in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { shownItem = nil }
            }
        }
    }
}


// MARK: - Library page (header, tabs, sort, filter; choices are remembered per library)

struct ClassicLibraryView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let lib: LibPref
    @State private var tab = 0
    @State private var items: [Item] = []
    @State private var total = 0
    @State private var loading = false
    @State private var loadFailed = false
    @State private var gen = 0
    @State private var sort: String
    @State private var desc: Bool
    @State private var watch: String
    @State private var genre: String
    @State private var genres: [String] = []
    @State private var letter = ""
    @State private var layout: String
    @State private var groupCol: Bool

    init(lib: LibPref) {
        self.lib = lib
        let d = UserDefaults.standard.dictionary(forKey: "lf-" + lib.id) ?? [:]
        _sort = State(initialValue: d["sort"] as? String ?? "name")
        _desc = State(initialValue: d["desc"] as? Bool ?? false)
        _watch = State(initialValue: d["watch"] as? String ?? "all")
        _genre = State(initialValue: d["genre"] as? String ?? "")
        _groupCol = State(initialValue: d["groupCollections"] as? Bool ?? false)
        _layout = State(initialValue: d["layout"] as? String
                        ?? UserDefaults.standard.string(forKey: "defaultLibraryLayout") ?? "grid")
    }

    var key: String { "\(tab)|\(sort)|\(desc)|\(watch)|\(genre)|\(letter)|\(grouping)" }
    /// "Group by Collection" applies to the main tab of movie libraries.
    var canGroup: Bool { lib.kind == "movies" && tab == 0 }
    var grouping: Bool { canGroup && groupCol }
    var filtered: Bool { watch != "all" || !genre.isEmpty }
    var types: String { (tab == 1 || lib.kind == "boxsets") ? "BoxSet" : "Movie,Series,Video,MusicVideo" }
    var sortLabel: String {
        switch sort {
        case "latest": return "Recently Added"
        case "release": return "Release Date"
        case "top": return "Rating"
        default: return "Name"
        }
    }

    func save() {
        let d: [String: Any] = ["sort": sort, "desc": desc, "watch": watch, "genre": genre, "layout": layout,
                                "groupCollections": groupCol]
        UserDefaults.standard.set(d, forKey: "lf-" + lib.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if tab == 2 { genreGrid } else { grid }
            }.padding(.leading, 40).padding(.trailing, 92).padding(.vertical, 24)   // room for the A–Z bar
        }
        .background(bg)
        .overlay(alignment: .trailing) { if tab != 2 { alphaBar } }
        .task(id: key) { await load(reset: true) }
        .task { genres = await emby.genres(lib) }
        .onChange(of: sort) { desc = (sort != "name") }
        .onChange(of: "\(sort)|\(desc)|\(watch)|\(genre)|\(layout)|\(groupCol)") { save() }
    }

    /// The letter under the pointer, for the Dock-style zoom of the A–Z bar.
    @State private var alphaHover: Int?
    func alphaScale(_ i: Int) -> CGFloat {
        guard let h = alphaHover else { return 1 }
        switch abs(i - h) { case 0: return 1.7; case 1: return 1.35; case 2: return 1.12; default: return 1 }
    }

    var alphaBar: some View {
        // Letters on a slim glass strip, as the top bar's sections
        VStack(spacing: 1) {
            ForEach(Array(classicAlphaLetters.enumerated()), id: \.element) { i, l in
                ClassicAlphaLetter(l: l, on: letter == l, action: { letter = (letter == l) ? "" : l },
                                   scale: alphaScale(i), hovering: { inside in
                    if inside { alphaHover = i } else if alphaHover == i { alphaHover = nil }
                })
            }
        }
        .animation(.easeOut(duration: 0.12), value: alphaHover)
        .padding(.vertical, 6).padding(.horizontal, 3)
        .background(Capsule().fill(Color.black.opacity(0.3)))
        .background(ClassicGlassBacking(shape: Capsule()))
        .padding(.trailing, 34)
    }

    var header: some View {
        VStack(spacing: 16) {
            ZStack {
                HStack { ClassicPageTitle(text: lib.title, icon: ClassicPageTitle.icon(lib.kind)); Spacer() }
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Button { tab = i } label: {
                            // Glossy lettering, as the top bar
                            Text3D(text: i == 0 ? lib.title : ["", "Collections", "Genres", "Favorites"][i], size: 12,
                                   weight: tab == i ? .bold : .semibold)
                                .opacity(tab == i ? 1 : 0.6)
                                .padding(.horizontal, 16).frame(height: 36)
                                .classicSelectedPill(tab == i)
                        .modifier(SectionHoverGlow(on: !(tab == i)))   // accent glow on hover, as the top bar
                        }.buttonStyle(.plainHand)
                    }
                }.padding(4).frame(height: 44).classicClearGlass()
            }
            if tab != 2 { controls }
        }
    }

    /// A button's icon and name in the top bar's glossy lettering.
    func glossyLabel(_ title: String, _ icon: String) -> some View {
        Label { Text3D(text: title, size: 16, weight: .semibold) } icon: { Text3D(image: Image(systemName: icon), size: 17) }
    }

    var controls: some View {
        HStack(spacing: 10) {
            Text("\(total) Items").foregroundColor(.secondary).padding(.trailing, 4)
            Button { Task { if let f = items.first { await emby.play(f) } } } label: {
                glossyLabel("Play", "play.fill").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton())
            Button { Task { await shuffle() } } label: {
                glossyLabel("Shuffle", "shuffle").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton())
            // Sort, filter and More open the glass list (not the macOS menu)
            GlassListButton(list: {
                let sorts = [("latest", "Recently Added"), ("name", "Name"), ("release", "Release Date"), ("top", "Rating")]
                let opts = ["Sort by"] + sorts.map(\.1) + ["Order", "Ascending", "Descending"]
                var ck: Set<Int> = [desc ? 7 : 6]
                if let i = sorts.firstIndex(where: { $0.0 == sort }) { ck.insert(i + 1) }
                return (opts, ck, [0, 5], { i in
                    if (1...4).contains(i) { sort = sorts[i - 1].0 } else if i == 6 { desc = false } else if i == 7 { desc = true }
                })
            }) {
                glossyLabel(sortLabel, desc ? "arrow.down" : "arrow.up").classicGlassPill(size: 44, iconOnly: false)
            }.helpLabel("Sort")
            GlassListButton(list: {
                let status = [("all", "All"), ("unwatched", "Unwatched"), ("watched", "Watched")]
                let opts = ["Status"] + status.map(\.1) + ["Genre", "All Genres"] + genres
                var ck: Set<Int> = []
                if let i = status.firstIndex(where: { $0.0 == watch }) { ck.insert(i + 1) }
                ck.insert(genre.isEmpty ? 5 : (genres.firstIndex(of: genre).map { $0 + 6 } ?? 5))
                return (opts, ck, [0, 4], { i in
                    if (1...3).contains(i) { watch = status[i - 1].0 }
                    else if i == 5 { genre = "" } else if i >= 6 { genre = genres[i - 6] }
                })
            }) {
                Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .classicGlassPill(size: 44)
            }.helpLabel("Filter")
            if !genre.isEmpty {
                Button { genre = "" } label: { glossyLabel(genre, "xmark").classicGlassPill(size: 44, iconOnly: false) }
                    .buttonStyle(HoverButton()).helpLabel("Clear genre")
            }
            layoutToggle
            GlassListButton(list: {
                let opts = (canGroup ? ["Group by Collection"] : []) + ["Refresh"]
                return (opts, canGroup && groupCol ? [0] : [], [], { i in
                    if canGroup && i == 0 { groupCol.toggle() } else { Task { await load(reset: true) } }
                })
            }) {
                Label("More", systemImage: "ellipsis").classicGlassPill(size: 44)
            }.helpLabel("More")
        }
    }

    var grid: some View {
        VStack(spacing: 20) {
            if layout == "list" {
                LazyVStack(spacing: 6) {
                    ForEach(items) { it in
                        ListRow(item: it).onAppear {
                            if it.id == nextPageAt || it.id == items.last?.id { Task { await load(reset: false) } }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                    ForEach(items) { it in
                        ClassicPosterCard(item: it).onAppear {
                            if it.id == nextPageAt || it.id == items.last?.id { Task { await load(reset: false) } }
                        }
                    }
                }
            }
            if loading { Spinner() }
            else if loadFailed {
                if items.isEmpty { ErrorStateView(message: emby.lastFailure ?? "Couldn't load this library.") { Task { await load(reset: true) } } }
                else { LoadMoreFailedView { Task { await load(reset: false) } } }
            }
            else if items.isEmpty { Text("Nothing here.").foregroundColor(.secondary).padding(40) }
        }
    }

    var layoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { layout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(layout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(layout == m.0)
                        .modifier(SectionHoverGlow(on: !(layout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicClearGlass()
    }

    var genreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(genres, id: \.self) { g in
                Button { genre = g; tab = 0 } label: {
                    // Glass tiles, as the buttons
                    Text(g).font(.cv(13, weight: .bold)).foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(HoverButton())
            }
        }
    }

    func fetch(start: Int, limit: Int, sort s: String) async -> ItemList? {
        await emby.libraryItems(lib, limit: limit, start: start, sort: s, desc: s == sort ? desc : nil,
                                watch: watch, genre: genre, letter: letter, favorites: tab == 3, types: types,
                                groupCollections: grouping)
    }

    func load(reset: Bool) async {
        if !reset && (loading || loadFailed || items.count >= total) { return }
        gen += 1
        let my = gen
        loading = true; loadFailed = false
        let r = await fetch(start: reset ? 0 : items.count, limit: 100, sort: sort)
        guard my == gen else { return }
        loading = false
        // A failed page keeps what's already shown and offers to try again (it used to end paging for good)
        guard let r else { loadFailed = true; return }
        if reset { items = r.Items } else { items += r.Items }
        total = r.TotalRecordCount ?? items.count
        // Posters of the new page start downloading now, before they scroll into view
        ImageCache.shared.prefetch(r.Items.prefix(40).map { emby.image($0.posterId, width: 360) })
    }

    /// The next page is fetched when this item appears, 30 before the end, so it's there before you reach it.
    var nextPageAt: String? { items.count > 30 ? items[items.count - 30].id : nil }

    func shuffle() async {
        let r = await fetch(start: 0, limit: 1, sort: "random")
        if let f = r?.Items.first { await emby.play(f) }
    }
}

// MARK: - Detail / movie info

struct ClassicCastTile: View {
    @EnvironmentObject var emby: Emby
    let p: Full.Person
    @AppStorage("castSize") private var castSize = "normal"   // Settings → Libraries → Movie and show pages
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    var body: some View {
        let big = castSize == "large"
        VStack(spacing: 6) {
            CachedImage(url: emby.image(p.Id, width: big ? 360 : 240)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.cv(big ? 44 : 30)).foregroundColor(.secondary) }
            }
            // Large: a portrait photo card (2:3); Normal: the round photo
            .frame(width: big ? 132 : 88, height: big ? 198 : 88)
            .clipShape(RoundedRectangle(cornerRadius: big ? 10 : 44))
            .modifier(ClassicLightCard(radius: big ? 10 : 44, hover: hover, accent: Theme.accent(accentName),
                                       size: big ? CGSize(width: 132, height: 198) : CGSize(width: 88, height: 88)))   // the posters' light glass edge
            .shadow(color: .black.opacity(big ? 0.45 : 0), radius: 6, y: 3)
            // Favorites show a small heart top left, as posters do
            .overlay(alignment: .topLeading) {
                if emby.isPersonFav(p.Id) {
                    FavHeart(size: 16).padding(big ? 8 : 2)
                }
            }
            // Favorite heart, bottom right on hover, as on posters
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    let fav = emby.isPersonFav(p.Id)
                    ItemActionsButton.circle(fav ? "heart.fill" : "heart", on: fav,
                                             help: fav ? "Remove from Favorites" : "Add to Favorites") {
                        Task { await emby.setFav(p.Id, !fav, name: p.Name) }
                    }.padding(big ? 8 : 0)
                }
            }
            .onHover { hover = ScrollActivity.hover(hover, $0) }
            .classicHoverLift()   // grows a little under the pointer, like posters
            Text(p.Name).font(.cv(big ? 12 : 10, weight: .semibold)).lineLimit(1)
            Text(p.Role ?? p.`Type` ?? "").font(.cv(10)).foregroundColor(.secondary).lineLimit(1)
        }.frame(width: CastTile.width(castSize)).multilineTextAlignment(.center)
    }
}

struct ClassicDetailView: View {
    @Environment(\.noBack) private var noBack
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let item: Item
    @AppStorage("accent") private var accentName = "red"   // episode cards' hover glow
    @AppStorage("moviePage") private var moviePage = "banner"   // Settings → Libraries → Movie page
    @State private var full: Full?
    @State private var kids: [Item] = []
    @State private var seasonItems: [Item] = []
    @State private var epLangs: [(code: String, name: String)] = []
    @AppStorage("episodeSubLang") private var epSubLang = ""
    @AppStorage("subAlways") private var subAlwaysOn = false
    @AppStorage("subLang") private var prefSubLang = "english"
    /// First entry of the Subtitles menu: the preferred language when that setting is on, otherwise Off.
    var defaultSubLabel: String { subAlwaysOn ? prefSubLang.capitalized : "Off" }
    // Shared with Settings → Libraries → Episode layout and the Glass theme: "row", "grid" or "list"
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("seasonLayoutTV") private var seasonLayout = "row"   // Settings → Libraries → Season layout
    @AppStorage("showEpisodeDescription") private var showEpDesc = true   // Settings → Libraries → Series
    @State private var showAllEps = false                                  // "Show all" / "Hide watched" in a season
    @State private var similar: [Item] = []
    @State private var includedIn: [Item] = []
    @AppStorage("similarLayout") private var similarLayout = "row"   // "row", "grid" or "list"; also in Settings → Libraries
    @State private var srcIdx = 0
    @State private var audioIdx = -1
    @State private var subIdx = -1
    @State private var quality = UserDefaults.standard.integer(forKey: "defaultQuality")
    @State private var season: Int? = nil
    @State private var nextEp: Item? = nil

    var sources: [MSource] { full?.MediaSources ?? [] }
    var src: MSource? { sources.indices.contains(srcIdx) ? sources[srcIdx] : nil }
    func streams(_ t: String) -> [MStream] { (src?.MediaStreams ?? []).filter { $0.`Type` == t } }
    var defaultAudio: Int {
        let a = streams("Audio")
        return (a.first(where: { $0.IsDefault == true }) ?? a.first)?.Index ?? -1
    }
    var simple: Bool { item.isSeries || item.isBox }

    /// Pre-selects the preferred subtitle language when "Always load" is on.
    func applyPreferredSub() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "subAlways"), let lang = d.string(forKey: "subLang"), !lang.isEmpty,
              let idx = preferredSub(src?.MediaStreams ?? [], lang: lang) else { return }
        subIdx = idx
    }

    /// `from` nil means resume where it was left off; 0 starts over.
    func playNow(from: Double? = nil) {
        if item.isSeries, let ep = nextEp { playEpisode(ep, from: from); return }
        if simple { Task { await emby.play(item) }; return }
        let audioChanged = audioIdx >= 0 && audioIdx != defaultAudio
        emby.playing = PlayRequest(item: item, sourceId: src?.Id,
                                   audio: audioChanged ? audioIdx : nil,
                                   sub: subIdx >= 0 ? subIdx : nil,
                                   maxBitrate: quality > 0 ? quality : nil,
                                   start: from ?? emby.resumeAt(item),
                                   noSub: subIdx < 0)
    }

    /// The item the big Play button acts on (next-up episode for a series).
    var playTarget: Item? { item.isSeries ? nextEp : (simple ? nil : item) }

    /// Where the Play target was left off (0 = not started); when > 0 a Resume button shows beside Play.
    var resumePoint: Double { playTarget.map { emby.resumeAt($0) } ?? 0 }

    /// The Play button starts from the beginning when there is a resume point (Resume sits next to it).
    var playLabel: String {
        if item.isSeries, let ep = nextEp { return "Play S\(ep.ParentIndexNumber ?? 0):E\(ep.IndexNumber ?? 0)" }
        return "Play"
    }

    /// Season layout → Cards: the show opens on a banner as big as Home's, the season deck in its bottom-right corner
    /// Decided by the setting alone (not by the seasons, which load a moment later), so the page never shows the
    /// old header first
    /// Movies and collections (Settings → Movie pages → Big banner) open the same way: a movie on the banner
    /// alone, a collection with its movies as the deck.
    var bigBanner: Bool { item.isSeries ? seasonLayout == "deck" : (!item.isEpisode && moviePage == "banner") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if bigBanner { showBanner } else { header }
                if item.isSeries { episodesList }
                if item.isBox { boxGrid }
                castSection.task { _ = await emby.favoritePeople() }   // hearts on the cast photos
                aboutSection
                includedInSection
                similarSection
            }.padding(.bottom, 50)
        }
        .ignoresSafeArea(edges: bigBanner ? .top : [])   // the banner runs up under the floating top bar
        .background(GeometryReader { g in
            Color.clear.onAppear { pageH = g.size.height }.onChange(of: g.size.height) { _, h in pageH = h }
        }.ignoresSafeArea(edges: .top))
        .background(alignment: .top) {
            if !bigBanner { ZStack {
                // Fill the page width without growing it: a filled image sized by its own width made the whole
                // page wider than the window (pushing the Top bar's Search and Settings off screen)
                Color.clear.frame(height: 520)
                    .overlay { ClassicBackdrop(id: item.backdropId ?? item.Id) }
                    .clipped().opacity(0.35)
                LinearGradient(colors: [Color.clear, bg], startPoint: .top, endPoint: .bottom)
            }.frame(height: 520) }
        }
        .background(bg)
        .task {
            full = await emby.full(item.id)
            audioIdx = defaultAudio
            applyPreferredSub()
            if item.isSeries {
                async let eps = emby.episodes(item.id)
                async let ss = emby.seasons(item.id)
                kids = await eps; seasonItems = await ss
                if let s = emby.openSeason { season = s; emby.openSeason = nil }
                nextEp = await emby.nextUp(item.id) ?? kids.first { !emby.isPlayed($0) } ?? kids.first
                if let first = kids.first { epLangs = Self.subLangs(await emby.full(first.id)) }
            }
            else if item.isBox { kids = await emby.children(item.id) }
            if !item.isEpisode && !item.isBox { includedIn = await emby.collections(containing: item.id) }
            if !item.isEpisode { similar = await emby.similar(item.id) }
        }
        .onChange(of: srcIdx) { audioIdx = defaultAudio; subIdx = -1; applyPreferredSub() }
        .onChange(of: season) { showAllEps = false }
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: noBack ? nil : { dismiss() }) }
        .classicHideToolbarTitle()
    }

    @State private var pageH: CGFloat = 800

    /// The show as a banner the size of the page (as Home's): backdrop edge to edge, title logo, facts, description
    /// and buttons on a dark fade at the left, the season deck bottom right.
    var showBanner: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(maxWidth: .infinity).frame(height: max(pageH, 420))
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: 2560) }.clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.6)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: bg.opacity(0.7), location: 0.8),
                                   .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(item: item, height: 110, font: 56)
                meta
                // A movie keeps its version, audio, subtitle and quality choices (a show picks per episode)
                if !item.isSeries && !simple {
                    // A set width, so Version, Audio, Subtitles and Quality fit on one line (left to size itself,
                    // the row was offered the narrow width of the text beside it and wrapped)
                    streamsRow.frame(width: 900, alignment: .leading)
                }
                buttons
                if !item.isSeries, let tag = full?.Taglines?.first { Text(tag).font(.cv(13, weight: .bold)) }
                Text(item.Overview ?? "").font(.cv(15)).lineLimit(3)
                    .foregroundColor(.white.opacity(0.85)).frame(maxWidth: 520, alignment: .leading)
            }
            .padding(.leading, 80).padding(.bottom, 56).padding(.trailing, item.isSeries || item.isBox ? 600 : 80)
            if item.isBox && !boxMovies.isEmpty {
                // A collection's movies as a deck, oldest first, the year under the front one
                let movies = boxMovies
                SeasonDeck(numbers: Array(movies.indices), selected: 0,
                           title: { movies[$0].Name },
                           image: { emby.image(movies[$0].posterId, width: 500) },
                           select: { _ in },
                           badge: { _ in nil },
                           seasonItem: { movies[$0] },
                           episodes: { _ in [] },
                           caption: { movies[$0].ProductionYear.map(String.init) },
                           link: { movies[$0] },
                           watched: { emby.isPlayed(movies[$0]) },
                           noun: "movie")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 44).padding(.bottom, 30)
                    .transition(.opacity)
            }
            if seasonNumbers.count > 1 {
                SeasonDeck(numbers: seasonNumbers, selected: currentSeason,
                           title: { seasonTitle($0) },
                           image: { n in emby.image(seasonItems.first { ($0.IndexNumber ?? 0) == n }?.Id ?? item.Id, width: 400) },
                           select: { season = $0 },
                       badge: { unwatched($0) },
                       seasonItem: { n in seasonItems.first { ($0.IndexNumber ?? 0) == n } },
                       episodes: { n in kids.filter { ($0.ParentIndexNumber ?? 0) == n } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 44).padding(.bottom, 56)
                    .transition(.opacity)
            }
        }
        .frame(height: max(pageH, 420))
        .foregroundColor(.white)
    }

    // Header: poster + info + pickers + buttons
    var header: some View {
        let deck = item.isSeries && seasonLayout == "deck" && seasonNumbers.count > 1
        return headerBody
            .padding(.trailing, deck ? 520 : 0)   // the text stays clear of the deck
            .frame(maxWidth: .infinity, alignment: .leading)   // full page width, so the deck reaches the corner
            .overlay(alignment: .bottomTrailing) {
                // Series, Settings → Season layout → Cards: the seasons as a deck of cards, as on the Home banner;
                // the front season is the one whose episodes are listed below
                if item.isSeries, seasonLayout == "deck", seasonNumbers.count > 1 {
                    SeasonDeck(numbers: seasonNumbers, selected: currentSeason,
                               title: { seasonTitle($0) },
                               image: { n in emby.image(seasonItems.first { ($0.IndexNumber ?? 0) == n }?.Id ?? item.Id, width: 400) },
                               select: { season = $0 },
                       badge: { unwatched($0) },
                       seasonItem: { n in seasonItems.first { ($0.IndexNumber ?? 0) == n } },
                       episodes: { n in kids.filter { ($0.ParentIndexNumber ?? 0) == n } })
                    .padding(.trailing, 40)   // in line with the episodes' right edge
                }
            }
    }

    var headerBody: some View {
        HStack(alignment: .top, spacing: 28) {
            CachedImage(url: emby.image(item.id, width: 500)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { ZStack { Color(white: 0.15); Text(item.Name).padding() } }
            .frame(width: item.isEpisode ? 320 : 220, height: item.isEpisode ? 180 : 330)
            .clipped().cornerRadius(10)
            .modifier(ClassicLightCard(radius: 10,
                                       size: item.isEpisode ? CGSize(width: 320, height: 180) : CGSize(width: 220, height: 330)))   // the posters' light glass edge and sheen, as the cards
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 14) {
                Text(item.Name).font(.cv(46, weight: .black))
                meta
                if !simple { streamsRow }
                buttons
                if let tag = full?.Taglines?.first { Text(tag).font(.cv(13, weight: .bold)) }
                Text(item.Overview ?? "").frame(maxWidth: 760, alignment: .leading)
                let directors = (full?.People ?? []).filter { $0.`Type` == "Director" }.map { $0.Name }
                if !directors.isEmpty {
                    (Text("Director: ").foregroundColor(.secondary) + Text(directors.joined(separator: ", ")).bold())
                        .font(.cv(12, weight: .regular))
                }
            }
        }.padding(.horizontal, 40).padding(.top, 40)
    }

    var meta: some View {
        HStack(spacing: 12) {
            if let r = full?.CommunityRating {
                HStack(spacing: 3) { Image(systemName: "star.fill").foregroundColor(.yellow); Text(String(format: "%.1f", r)) }
            }
            if let c = full?.CriticRating { Text("🍅 \(Int(c))%") }
            if let y = item.ProductionYear { Text(String(y)) }
            if let t = full?.RunTimeTicks { Text(runtimeText(t)) }
            if let o = full?.OfficialRating {
                Text(o).font(.cv(10, weight: .regular)).padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary))
            }
            if let g = full?.Genres?.first { Text(g) }
            if let t = full?.RunTimeTicks, !simple { Text("Ends at " + endsAtText(t)) }
        }.font(.cv(11, weight: .regular)).foregroundColor(.secondary)
    }

    /// Wraps onto more lines when the window is narrow, so long version names can't widen the page.
    var streamsRow: some View {
        FlowLayout(hSpacing: 20, vSpacing: 10) {
            if sources.count > 1 {
                labeled("Version") {
                    GlassPicker(selection: $srcIdx, options: sources.indices.map {
                        ($0, sources[$0].Name ?? sources[$0].Path ?? "Version \($0 + 1)")
                    }, maxWidth: 320)   // long file names are cut with "…"
                }
            }
            if let v = streams("Video").first {
                HStack(spacing: 6) { Text("Video").foregroundColor(.secondary); Text(v.DisplayTitle ?? "") }
            }
            if !streams("Audio").isEmpty {
                labeled("Audio") {
                    GlassPicker(selection: $audioIdx,
                                options: streams("Audio").map { ($0.Index, $0.DisplayTitle ?? "Track \($0.Index)") })
                }
            }
            labeled("Subtitles") {
                GlassPicker(selection: $subIdx,
                            options: [(-1, "Off")] + streams("Subtitle").map { ($0.Index, $0.DisplayTitle ?? "Track \($0.Index)") })
            }
            labeled("Quality") {
                GlassPicker(selection: $quality, options: [(0, "Original"), (8_000_000, "1080p · 8 Mbps"),
                                                           (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")])
            }
        }
        .font(.cv(12, weight: .regular))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary)
            content()
        }
    }

    var buttons: some View {
        let played = emby.isPlayed(item)
        let fav = emby.isFav(item)
        // All the same size and shape: 44-pt glass pills
        return HStack(spacing: 10) {
            let r = resumePoint
            Button { playNow(from: r > 0 ? 0 : nil) } label: {
                Label(playLabel, systemImage: "play.fill").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton()).accessibilityLabel(r > 0 ? playLabel + " from the beginning" : playLabel)
            if r > 0 {
                Button { playNow() } label: {
                    Label("Resume from \(timeString(r))", systemImage: "arrow.uturn.forward").classicGlassPill(size: 44, iconOnly: false)
                }.buttonStyle(HoverButton())
            }
            RatingButton(item: item, full: full, classic: true)
            if let u = SafeLink.url(full?.RemoteTrailers?.first?.Url) {
                Button { Trailer.open(u, item: item, emby: emby) } label: {
                    Label("Trailer", systemImage: "film").classicGlassPill(size: 44)
                }.buttonStyle(HoverButton()).helpLabel("Trailer")
            }
            Button { Task { await emby.setPlayed(item.id, !played, name: item.Name) } } label: {
                Label(played ? "Watched" : "Mark as Watched", systemImage: played ? "checkmark.circle.fill" : "checkmark.circle")
                    .classicGlassPill(size: 44)
            }.buttonStyle(HoverButton()).helpLabel(played ? "Mark as unwatched" : "Mark as watched")
            Button { Task { await emby.setFav(item.id, !fav, name: item.Name) } } label: {
                Label { Text(fav ? "Favorite" : "Add to Favorites") } icon: {
                    if fav { FavHeart(size: 17) } else { Image(systemName: "heart") }
                }
                .classicGlassPill(size: 44)
            }.buttonStyle(HoverButton()).helpLabel(fav ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    /// Language name from "English (SRT)" etc., so "eng" and "en" tracks group together.
    static func langName(_ st: MStream) -> String { subLangName(st) }   // same rule as "Always load…"

    /// Subtitle languages found in an item, keyed by language code.
    static func subLangs(_ f: Full?) -> [(code: String, name: String)] {
        var out: [(code: String, name: String)] = []
        for st in f?.MediaSources?.first?.MediaStreams ?? [] where st.`Type` == "Subtitle" {
            let name = langName(st)
            if out.contains(where: { $0.code == name.lowercased() }) { continue }
            out.append((name.lowercased(), name))
        }
        return out
    }

    /// Plays an episode with the subtitle language chosen for episodes (text formats like SRT preferred).
    /// Plays an episode; `from` nil means resume where it was left off.
    func playEpisode(_ ep: Item, from: Double? = nil) {
        let q = UserDefaults.standard.integer(forKey: "defaultQuality")
        let maxBitrate: Int? = q > 0 ? q : nil
        let start: Double = from ?? emby.resumeAt(ep)
        // Subtitles menu: "off" = explicitly none; empty = the default (the preferred language from Settings when
        // "Always load preferred subtitle language" is on, ignoring what was remembered for the series); else a language
        let d = UserDefaults.standard
        if epSubLang == "off" { emby.playing = PlayRequest(item: ep, maxBitrate: maxBitrate, start: start, noSub: true); return }
        let preferred: String = d.bool(forKey: "subAlways") ? (d.string(forKey: "subLang") ?? "").lowercased() : ""
        let wanted: String = epSubLang.isEmpty ? preferred : epSubLang
        if wanted.isEmpty { emby.playing = PlayRequest(item: ep, maxBitrate: maxBitrate, start: start); return }
        Task {
            let f = await emby.full(ep.id)
            let src = f?.MediaSources?.first
            let all = src?.MediaStreams ?? []
            let subs = all.filter { $0.`Type` == "Subtitle" && Self.langName($0).lowercased() == wanted }
            let text = ["srt", "subrip", "vtt", "ass", "ssa"]
            var pick = (subs.first { text.contains(($0.Codec ?? "").lowercased()) } ?? subs.first)?.Index
            if pick == nil { pick = preferredSub(all, lang: wanted) }
            emby.playing = PlayRequest(item: ep, sourceId: src?.Id, sub: pick, maxBitrate: maxBitrate, start: start)
        }
    }

    var seasonNumbers: [Int] {
        let set = Set(kids.map { $0.ParentIndexNumber ?? 0 })
        return set.sorted { (a: Int, b: Int) -> Bool in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }

    var currentSeason: Int {
        if let season { return season }
        if let firstUnwatched = kids.first(where: { !emby.isPlayed($0) })?.ParentIndexNumber { return firstUnwatched }
        return seasonNumbers.first ?? 0
    }

    func seasonTitle(_ n: Int) -> String {
        if n == 0 { return "Specials" }
        return seasonItems.first { ($0.IndexNumber ?? 0) == n }?.Name ?? "Season \(n)"
    }

    /// All episodes of the season being shown.
    /// currentSeason is worked out once: inside the filter it re-scanned every episode for each episode,
    /// which made every redraw of a long series slow (switching back to Cove, leaving full screen).
    var seasonEpisodes: [Item] {
        let s = currentSeason
        return kids.filter { ($0.ParentIndexNumber ?? 0) == s }
    }

    /// The season has both watched and unwatched episodes, so "hide watched" makes sense.
    var canFilterWatched: Bool {
        let all: [Item] = seasonEpisodes
        let open: Int = all.filter { !emby.isPlayed($0) }.count
        return open > 0 && open < all.count
    }

    /// Unwatched episodes only, unless the season is fully watched / fully unwatched or "Show all" is on.
    var shownEpisodes: [Item] {
        let all: [Item] = seasonEpisodes
        if canFilterWatched && !showAllEps { return all.filter { !emby.isPlayed($0) } }
        return all
    }

    /// Unwatched episodes in a season (nil while episodes are loading).
    func unwatched(_ n: Int) -> Int? {
        let eps = kids.filter { ($0.ParentIndexNumber ?? 0) == n }
        return eps.isEmpty ? nil : eps.filter { !emby.isPlayed($0) }.count
    }

    func seasonPoster(_ n: Int) -> some View {
        let sItem: Item? = seasonItems.first { ($0.IndexNumber ?? 0) == n }
        let title: String = seasonTitle(n)
        let selected: Bool = n == currentSeason
        return Button { season = n } label: {
            VStack(spacing: 8) {
                CachedImage(url: emby.image(sItem?.Id ?? item.Id, width: 400)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.15); Text(title) }
                }
                .frame(width: 170, height: 255).clipped().cornerRadius(8)
                .overlay(alignment: .topTrailing) { CountBadge(count: unwatched(n)).padding(8) }
                .modifier(ClassicLightCard(radius: 8, accent: Theme.accent(accentName), size: CGSize(width: 170, height: 255),
                                           tracksHover: true))   // the posters' light glass edge   // glass card, as the posters
                .overlay { if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 2) } }
                .shadow(radius: 6)
                .classicHoverLift()
                .hoverItemActions(sItem, .bottomTrailing, children: kids.filter { ($0.ParentIndexNumber ?? 0) == n })
                Text(title).font(.cv(13, weight: .regular)).foregroundColor(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plainHand)
    }

    var seasonRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons").font(.cv(15, weight: .bold)).padding(.horizontal, 40)
            if seasonLayout == "grid" {
                // All seasons at once, wrapped onto as many lines as needed
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 170), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(seasonNumbers, id: \.self) { n in seasonPoster(n) }
                }.padding(.horizontal, 40).padding(.vertical, 8)
            } else {
                ArrowScrollRow(ids: seasonNumbers, itemWidth: 170) { n in seasonPoster(n) }
            }
        }
    }

    var episodesHeader: some View {
        let multi: Bool = seasonNumbers.count > 1
        let heading: String = multi ? seasonTitle(currentSeason) : "Episodes"
        return HStack(spacing: 16) {
            Text(heading).font(.cv(15, weight: .bold))
            if canFilterWatched {
                Button(showAllEps ? "Hide watched" : "Show all") { showAllEps.toggle() }
                    .buttonStyle(.plainHand).font(.cv(12, weight: .semibold)).foregroundStyle(.tint)
            }
            Spacer()
            episodeLayoutToggle
            if !epLangs.isEmpty {
                Text("Subtitles").foregroundColor(.secondary)
                GlassPicker(selection: $epSubLang,
                            options: [("", defaultSubLabel)] + (subAlwaysOn ? [("off", "Off")] : [])
                                + epLangs.map { ($0.code, $0.name) })
            }
        }.padding(.horizontal, 40).padding(.top, 10)
    }

    /// Netflix-style episode row: big number, clean 16:9 still with progress, title + length, summary.
    func episodeRow(_ ep: Item) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        return NavigationLink(value: ep) {
            HStack(alignment: .center, spacing: 18) {
                Text("\(ep.IndexNumber ?? 0)").font(.cv(26, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 40)
                CachedImage(url: emby.image(ep.id, width: 480, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(white: 0.15) }
                .frame(width: 220, height: 124).clipped()
                .overlay(alignment: .bottomTrailing) {
                    if pct > 0, pct < 100, !played { ClassicProgressCircle(progress: pct / 100).padding(6) }
                }
                .cornerRadius(6)
                .modifier(ClassicLightCard(radius: 6, accent: Theme.accent(accentName), size: CGSize(width: 220, height: 124),
                                           tracksHover: true))   // the posters' light glass edge
                .classicHoverLift(play: 36) { playEpisode(ep) }
                .hoverItemActions(ep)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ep.Name).font(.cv(16, weight: .semibold)).lineLimit(1)
                        if played { Image(systemName: "checkmark.circle.fill").foregroundColor(.white.opacity(0.7)) }
                        Spacer()
                        if let t = ep.RunTimeTicks, t > 0 { Text(runtimeText(t)).foregroundColor(.secondary) }
                    }
                    if showEpDesc { Text(ep.Overview ?? "").lineLimit(3).font(.cv(12, weight: .regular)).foregroundColor(.secondary) }
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
            .contentShape(Rectangle())
        }.handCursor()
        .buttonStyle(.plainHand).padding(.horizontal, 40)
    }

    var episodesList: some View {
        let eps: [Item] = shownEpisodes
        return VStack(alignment: .leading, spacing: 12) {
            if seasonNumbers.count > 1 && seasonLayout != "deck" { seasonRow }   // the deck sits in the header instead
            episodesHeader
            // A new season's episodes cross-fade in as one block (cards sliding and resizing one by one looked glitchy)
            Group {
                if epLayout == "row" {
                    // One line that scrolls sideways
                    ArrowScrollRow(ids: eps.map { $0.id }, itemWidth: 300, spacing: 18) { id in
                        if let ep = eps.first(where: { $0.id == id }) { episodeTile(ep).frame(width: 300) }
                    }
                } else if epLayout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 22) {
                        ForEach(eps) { ep in episodeTile(ep) }
                    }.padding(.horizontal, 40)
                } else {
                    VStack(alignment: .leading, spacing: 12) { ForEach(eps) { ep in episodeRow(ep) } }
                }
            }
            .id(currentSeason)
            .transition(.opacity)
        }
    }

    var episodeLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { epLayout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(epLayout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(epLayout == m.0)
                        .modifier(SectionHoverGlow(on: !(epLayout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicClearGlass()
    }


    /// "S3·E3" plus " · 42m left" when the episode is partly watched.
    func episodeInfo(_ ep: Item, hasProgress: Bool) -> String {
        var t = "S\(ep.ParentIndexNumber ?? 0)·E\(ep.IndexNumber ?? 0)"
        if hasProgress, let total = ep.RunTimeTicks, total > 0 {
            let left = max(0, total - (ep.UserData?.PlaybackPositionTicks ?? 0))
            t += " · " + runtimeText(left) + " left"
        }
        return t
    }

    func episodeTile(_ ep: Item) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        let hasProgress: Bool = pct > 0 && pct < 100 && !played
        return NavigationLink(value: ep) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    CachedImage(url: emby.image(ep.id, width: 520, plain: true)) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color(white: 0.15) }
                    .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    .opacity(played ? 0.6 : 1)
                    WatchBadge(item: ep, played: played).padding(6)
                }
                // Episode name in the bottom-left corner of the thumbnail
                .overlay(alignment: .bottomLeading) {
                    // No background: a black outline keeps it readable (as on Continue Watching)
                    Text(ep.Name).font(.cv(14, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                        .classicBlackOutline()
                        .padding(.leading, 10).padding(.trailing, hasProgress ? 44 : 10)
                        .padding(.bottom, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Episode number in the top-left corner
                .overlay(alignment: .topLeading) {
                    Text(episodeInfo(ep, hasProgress: hasProgress)).font(.cv(10, weight: .semibold)).foregroundColor(.white)
                        .classicBlackOutline()
                        .padding(10)
                }
                // How far you got, bottom-right
                .overlay(alignment: .bottomTrailing) {
                    if hasProgress { ClassicProgressCircle(progress: pct / 100).padding(8) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .modifier(ClassicLightCard(radius: 6, accent: Theme.accent(accentName), tracksHover: true))   // the posters' light glass edge
                .classicHoverLift(play: 40) { playEpisode(ep) }
                // In the top-right corner, over the watched badge (the 28-point buttons cover the 24-point badge)
                .hoverItemActions(ep, .topTrailing, EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                if showEpDesc {
                    Text(ep.Overview ?? "").font(.cv(10, weight: .regular)).foregroundColor(.secondary).lineLimit(2)
                }
            }.contentShape(Rectangle())
        }.handCursor()
        .buttonStyle(.plainHand)
    }

    /// A collection's movies in release order (by year, then date), for the banner's deck.
    var boxMovies: [Item] {
        kids.sorted { ($0.ProductionYear ?? 9999, $0.PremiereDate ?? "") < ($1.ProductionYear ?? 9999, $1.PremiereDate ?? "") }
    }

    var boxGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
            ForEach(kids) { ClassicPosterCard(item: $0) }
        }.padding(.horizontal, 40)
    }

    @AppStorage("castSize") private var castSize = "normal"
    @ViewBuilder var castSection: some View {
        let people = Array((full?.People ?? []).prefix(30))
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & Crew").font(.cv(15, weight: .bold)).padding(.horizontal, 40)
                ArrowScrollRow(ids: Array(people.indices), itemWidth: CastTile.width(castSize)) { i in
                    NavigationLink(value: PersonRef(id: people[i].Id, name: people[i].Name)) { ClassicCastTile(p: people[i]) }
                        .buttonStyle(.plainHand).accessibilityLabel("Show everything with \(people[i].Name)")   // no tooltip on actors
                }
            }
        }
    }

    func mediaInfo(_ s: MSource, _ f: Full) -> String {
        var info = (s.Container ?? "").uppercased()
        if let z = s.Size { info += "  " + ByteCountFormatter.string(fromByteCount: z, countStyle: .file) }
        if let a = classicParseDate(f.DateCreated) { info += "  Added " + a.formatted(date: .abbreviated, time: .shortened) }
        return info
    }

    func aboutRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).bold()
            Text(text).foregroundColor(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder var aboutSection: some View {
        if let f = full {
            VStack(alignment: .leading, spacing: 16) {
                Text("About").font(.cv(15, weight: .bold))
                if let d = classicParseDate(f.UserData?.LastPlayedDate) {
                    aboutRow("Date Last Played", d.formatted(date: .abbreviated, time: .shortened))
                }
                if let g = f.Genres, !g.isEmpty { aboutRow("Genres", g.joined(separator: ", ")) }
                if let s = f.Studios, !s.isEmpty { aboutRow("Studios", s.map { $0.Name }.joined(separator: ", ")) }
                if let links = f.ExternalUrls, !links.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Links").bold()
                        HStack(spacing: 10) {
                            ForEach(links.indices, id: \.self) { i in
                                if let n = links[i].Name, let u = SafeLink.url(links[i].Url) { Link(n, destination: u).handCursor() }
                            }
                        }
                    }
                }
                if let s = src {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Media Info").bold()
                        if let p = s.Path { Text(p).foregroundColor(.secondary).textSelection(.enabled) }
                        Text(mediaInfo(s, f)).foregroundColor(.secondary)
                    }
                }
            }.padding(.horizontal, 40).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Included In": the collections this title belongs to; a click opens the collection's page.
    @ViewBuilder var includedInSection: some View {
        if !includedIn.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Included In").font(.cv(15, weight: .bold)).padding(.horizontal, 40)
                ArrowScrollRow(ids: Array(includedIn.indices), itemWidth: 150, spacing: 14) { ClassicPosterCard(item: includedIn[$0]) }
            }
        }
    }

    @ViewBuilder var similarSection: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("More Like This").font(.cv(15, weight: .bold))
                    Spacer()
                    similarLayoutToggle
                }.padding(.horizontal, 40)
                // Extra space below, and the header kept in front: a hovered poster grows a little (hover lift)
                // and could otherwise cover the view buttons and swallow their clicks
                .padding(.bottom, 14).zIndex(1)
                if similarLayout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(similar) { ClassicPosterCard(item: $0) }
                    }.padding(.horizontal, 40)
                } else if similarLayout == "list" {
                    LazyVStack(spacing: 6) { ForEach(similar) { ListRow(item: $0) } }.padding(.horizontal, 40)
                } else {
                    ArrowScrollRow(ids: Array(similar.indices), itemWidth: 150, spacing: 14) { ClassicPosterCard(item: similar[$0]) }
                }
            }
        }
    }

    var similarLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { similarLayout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(similarLayout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(similarLayout == m.0)
                        .modifier(SectionHoverGlow(on: !(similarLayout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicClearGlass()
    }
}

// MARK: - Player (inside the main window)

struct ClassicPlayerView: View {
    @EnvironmentObject var emby: Emby
    @StateObject private var model = PlayerModel()
    let req: PlayRequest
    /// Classic theme: glass buttons. These controls can also be picked under the Glass theme (Settings →
    /// Playback → Player controls); there they keep their plain look.
    @Environment(\.classicGlass) private var classic

    enum Panel { case subtitles, appearance, chapters, episodes }
    @State private var panel: Panel?
    @State private var showUI = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrub: Double = 0
    @State private var episodes: [Item] = []
    @FocusState private var focused: Bool
    @State private var showInfo = false
    @State var pickerSeason = 1
    @State private var infoLines: [(String, String)] = []
    @State private var hoverX: CGFloat?
    @State private var sliderW: CGFloat = 1
    @State private var upNextCancelled = false
    @State private var switching = false

    // Subtitle appearance (defaults: normal size, white, drop shadow, transparent, 10% from bottom)
    @AppStorage("subTextSize") private var subTextSize = "normal"
    @AppStorage("subColor") private var subColor = "white"
    @AppStorage("subShadowStyle") private var subShadow = "drop"
    @AppStorage("subBg") private var subBg = "none"
    @AppStorage("subBottom") private var subBottom = 10.0
    @AppStorage("skipSeconds") private var skipSecs = 10
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("clickToPause") private var clickToPause = true
    @AppStorage("accent") private var accentName = "red"
    var accent: Color { Theme.accent(accentName) }
    @State private var fsBusy = false   // a full screen animation is running
    @State private var isFullScreen = false
    @State private var escMonitor: Any?
    @State private var playerWin = WeakWindow()   // the window this player is in
    // Remembered across episodes (each episode gets a fresh ClassicPlayerView), so closing the player still leaves full screen
    var enteredFullScreen: Bool {
        get { PlaybackFlag.shared.enteredFullScreen }
        nonmutating set { PlaybackFlag.shared.enteredFullScreen = newValue }
    }

    static let sizes: [(String, String, Double)] = [("smaller", "Smaller", 0.032), ("small", "Small", 0.038),
        ("normal", "Normal", 0.045), ("large", "Large", 0.055), ("larger", "Larger", 0.066)]
    static let colors: [(String, String, Color)] = [("white", "White", .white), ("yellow", "Yellow", .yellow),
        ("gray", "Light gray", Color(white: 0.8)), ("black", "Black", .black)]
    static let shadows: [(String, String)] = [("none", "None"), ("drop", "Drop shadow"), ("outline", "Outline"), ("raised", "Raised")]
    static let bgs: [(String, String, Double)] = [("none", "Transparent", 0), ("semi", "Semi-transparent", 0.5), ("black", "Black", 1)]

    var item: Item { req.item }
    var current: Item? { episodes.firstIndex(where: { $0.Id == item.Id }).map { episodes[$0] } }
    var prevEp: Item? { episodes.firstIndex(where: { $0.Id == item.Id }).flatMap { $0 > 0 ? episodes[$0 - 1] : nil } }
    var nextEp: Item? { episodes.firstIndex(where: { $0.Id == item.Id }).flatMap { $0 + 1 < episodes.count ? episodes[$0 + 1] : nil } }

    /// The window this player is in (the separate player window is not always the key or main window)
    var window: NSWindow? { playerWin.window ?? NSApp.keyWindow ?? NSApp.mainWindow }

    /// Height of the window's title bar while windowed (0 in full screen, where there is none).
    /// The separate player window has no title bar (as in the Glass player): measuring one there changed the
    /// layout during the full screen animation, and leaving full screen stalled.
    var titleBarHeight: CGFloat {
        guard !UserDefaults.standard.bool(forKey: "separatePlayer"),
              !isFullScreen, let w = window, !w.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }
    /// Color of the strip under the title bar. The system draws the bar's own gray (about 93 % opaque) over it,
    /// and the result is the same gray on both sides only when this strip is (44, 45, 45).
    static let titleBarGray = Color(red: 44 / 255, green: 45 / 255, blue: 45 / 255)

    /// The Back classicPill that used to be drawn inside the player (top left). Off now; see `titleBarBack`.
    static let inPlayerBackPill = false
    /// The Back classicPill in the title bar of the windowed player. Off now: Esc leaves the player.
    static let titleBarBackPill = false

    /// Windowed player: Back classicPill up in the title bar, where the app's own Back classicPill sits on a page
    /// (right after the window buttons).
    /// Not drawn in full screen, where Esc leaves the player.
    var titleBarBack: some View {
        let h = titleBarHeight
        let x: CGFloat = 80
        let visible = h > 0 && (showUI || panel != nil)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                BackPill(compact: true) { back() }.helpLabel("Back (Esc)").padding(.leading, x)
                Spacer(minLength: 0)
            }.frame(height: h)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.2), value: showUI)
    }

    /// Full screen for the video; leaving the player restores the window if the player made it full screen.
    func toggleFullScreen() {
        // One toggle at a time: a second one during macOS's animation (a held or double-pressed F) left the
        // window stuck, ignoring every later toggle
        guard !fsBusy else { return }
        guard let w = window else { return }
        w.collectionBehavior.insert(.fullScreenPrimary)   // as in the Glass player
        fsBusy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { fsBusy = false }   // in case no notification comes
        let on = w.styleMask.contains(.fullScreen)
        if !on { enteredFullScreen = true }
        // After the key press has been handled: called from inside the key event, leaving full screen often
        // didn't start at all
        DispatchQueue.main.async { w.toggleFullScreen(nil) }
        isFullScreen = !on
    }

    /// Back button: in full screen the first click leaves full screen (the video keeps playing),
    /// the next click stops playback and returns to the app.
    func back() {
        if isFullScreen { toggleFullScreen() } else { close() }
    }

    func close() {
        if enteredFullScreen, let w = window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        enteredFullScreen = false
        // Past 90% the stop report marks it watched on the server (and here, see reportStopped). Marking it again
        // made the server's Trakt plugin log a second play ("watch" next to the "scrobble").
        model.stop()
        emby.playing = nil
    }

    /// Plays a neighbouring episode, keeping the current subtitle language.
    func play(_ ep: Item) {
        guard !switching else { return }
        switching = true
        let lang = model.subStreams.first { $0.Index == model.sub }.map { ClassicDetailView.langName($0) }
        Task {
            let f = await emby.full(ep.id)
            let src = f?.MediaSources?.first
            var pick: Int?
            if let lang {
                let subs = (src?.MediaStreams ?? []).filter { $0.`Type` == "Subtitle" && ClassicDetailView.langName($0) == lang }
                let text = ["srt", "subrip", "vtt", "ass", "ssa"]
                pick = (subs.first { text.contains(($0.Codec ?? "").lowercased()) } ?? subs.first)?.Index
            }
            model.stop()       // marks a finished episode watched (see close())
            let q = UserDefaults.standard.integer(forKey: "defaultQuality")
            emby.playing = PlayRequest(item: ep, sourceId: src?.Id, sub: pick, maxBitrate: q > 0 ? q : nil,
                                       start: emby.resumeAt(ep))
        }
    }

    func poke() {
        showUI = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled && model.playing && panel == nil {
                withAnimation { showUI = false }
                // Full screen: hide the pointer with the controls; it comes back when the mouse moves
                if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    var endClock: String {
        let left = max(0, model.duration - model.time) / Double(max(model.speed, 0.1))
        return Self.clockFormat.string(from: Date().addingTimeInterval(left))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let p = model.player {
                    AVPlayerViewRep(player: p, onLayer: model.attach).ignoresSafeArea().padding(.top, titleBarHeight)
                }
                else if model.error.isEmpty { Spinner(inPlayer: true).controlSize(.large) }
                if model.pipActive { classicPipPlaceholder }

                subtitleLayer(geo.size).animation(.easeOut(duration: 0.2), value: showUI)

                if showUI || panel != nil {
                    LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea().allowsHitTesting(false)
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        bottomBar
                    }
                    .transition(.opacity)
                }

                if model.player != nil, !model.isReady, model.error.isEmpty { Spinner() }

                if !model.error.isEmpty {
                    VStack(spacing: 12) {
                        Text(model.error).multilineTextAlignment(.center).frame(maxWidth: 420)
                        retryButton
                    }
                }

                if showInfo { classicInfoOverlay }
                classicCornerCards
                panelLayer
                // Title bar strip, above every layer (the controls' dark gradient used to darken it)
                VStack(spacing: 0) {
                    ClassicPlayerView.titleBarGray.frame(height: titleBarHeight)
                    Spacer(minLength: 0)
                }.ignoresSafeArea().allowsHitTesting(false)
                if Self.titleBarBackPill { titleBarBack }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if panel != nil { panel = nil }
                else if clickToPause { model.togglePlay(); poke() }
                else { withAnimation { showUI.toggle() } }
            }
        }
        .foregroundColor(.white)
        .onContinuousHover { _ in poke() }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) {
            if classicShowUpNext, let n = nextEp { play(n) } else { model.togglePlay() }
            poke(); return .handled
        }
        .onKeyPress(.return) {
            if classicShowUpNext, let n = nextEp { play(n); return .handled }
            return .ignored
        }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress("i") { showInfo.toggle(); return .handled }
        // No screen saver / display sleep while a video is playing (windowed or full screen)
        .onChange(of: model.playing) { _, on in KeepAwake.set(on, owner: model) }
        .onDisappear { KeepAwake.set(false, owner: model) }
        .onKeyPress("p") { model.togglePiP(); return .handled }
        .onKeyPress("e") {
            guard item.isEpisode && episodes.count > 1 else { return .ignored }
            if panel != .episodes { pickerSeason = item.ParentIndexNumber ?? 1 }
            panel = panel == .episodes ? nil : .episodes
            return .handled
        }
        // Keep keyboard focus on the player (Space must always reach it, e.g. for "Play now")
        .onChange(of: classicShowUpNext) { _, on in if on { focused = true } }
        .onChange(of: panel) { _, p in if p == nil { focused = true } }
        .onChange(of: focused) { _, f in if !f && panel == nil { DispatchQueue.main.async { focused = true } } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
        .onKeyPress("c") { if !model.chapterList.isEmpty { panel = panel == .chapters ? nil : .chapters }; return .handled }
        .task(id: showInfo) {
            while showInfo && !Task.isCancelled {
                infoLines = await model.playbackInfo()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if playerWin.owns(n.object) { fsBusy = false }
            guard playerWin.owns(n.object) else { return }
            isFullScreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            if playerWin.owns(n.object) { fsBusy = false }
            guard playerWin.owns(n.object) else { return }
            isFullScreen = false
            // Take the keyboard back after leaving full screen, so Esc / Space / F keep working
            (n.object as? NSWindow)?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onKeyPress(.leftArrow) { model.skip(-Double(skipSecs)); poke(); return .handled }
        .onKeyPress(.rightArrow) { model.skip(Double(skipSecs)); poke(); return .handled }
        // Esc: close a panel, else leave full screen (video keeps playing), else close the player.
        // Caught at the app level (AppKit sometimes swallows Esc before SwiftUI sees it, e.g. after full
        // screen), but only in the player's own window.
        .background(WindowReader { playerWin.window = $0 })
        .onAppear {
            let win = playerWin
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                guard let w = win.window, ev.window === w,
                      w.attachedSheet == nil, w.sheetParent == nil else { return ev }
                // F also here: in the separate player window the SwiftUI key handler doesn't always get it
                if ev.keyCode == 3, ev.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   !(w.firstResponder is NSText) {
                    if !ev.isARepeat { toggleFullScreen() }   // holding F must not toggle again and again
                    return nil
                }
                guard ev.keyCode == 53 else { return ev }
                if panel != nil { panel = nil } else if w.styleMask.contains(.fullScreen) { toggleFullScreen() } else { close() }
                return nil
            }
        }
        .onDisappear { if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil } }
        .task {
            focused = true
            isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
            poke()
            if item.isEpisode, let sid = item.SeriesId { episodes = await emby.episodes(sid) }
        }
        .task { await model.start(emby, req) }
        .onDisappear { model.stop(); if emby.playing == nil { RemoteControls.detach() } }   // keep keys when switching episodes
        // Closing the player window (red button or ⌘W) stops playback, like Esc (the Glass player does the same)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
            if (n.object as? NSWindow)?.title == "Player" { close() }
        }
        // Media keys / Control Center (shared with the Glass player)
        .onAppear { RemoteControls.attach(model, skip: Double(skipSecs)) }
        .onChange(of: model.playing) { RemoteControls.update(item, model) }
        .onChange(of: model.duration) { RemoteControls.update(item, model) }
        .onChange(of: Int(model.time / 10)) { RemoteControls.update(item, model) }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            if autoNext, !upNextCancelled, let n = nextEp { play(n) } else { close() }
        }
    }

    // MARK: Subtitles drawn by the app

    /// Subtitle distance from the bottom: the user's setting, but above the controls while they're showing.
    func subLift(_ size: CGSize) -> CGFloat {
        let base = size.height * subBottom / 100
        return (showUI || panel != nil) ? max(base, 190) : base
    }

    @ViewBuilder func subtitleLayer(_ size: CGSize) -> some View {
        if model.loadingSubs {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spinner(inPlayer: true).controlSize(.small)
                    Text("Loading subtitles…").font(.cv(14, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(.bottom, subLift(size))
            }.frame(maxWidth: .infinity).allowsHitTesting(false)
        }
        if !model.caption.isEmpty && !model.pipActive {   // not while the video is in picture in picture
            let fs = max(14, size.height * (Self.sizes.first { $0.0 == subTextSize }?.2 ?? 0.045))
            let color = Self.colors.first { $0.0 == subColor }?.2 ?? .white
            let shade: Color = subColor == "black" ? .white : .black
            VStack {
                Spacer()
                Text(model.caption)
                    .font(.cv(fs, weight: .medium))
                    .foregroundColor(color)
                    .multilineTextAlignment(.center)
                    .modifier(SubShadow(style: subShadow, color: shade))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.black.opacity(Self.bgs.first { $0.0 == subBg }?.2 ?? 0))
                    .cornerRadius(4)
                    .padding(.horizontal, size.width * 0.08)
                    .padding(.bottom, subLift(size))
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
    }

    // MARK: Top bar

    var topBar: some View {
        HStack(spacing: 16) {
            // The classicPill that used to sit here is hidden (kept, not deleted): in full screen Esc does the job, and in a
            // window it moved to the title bar (titleBarBack, now off too). Set inPlayerBackPill to true to bring it back.
            if Self.inPlayerBackPill {
                Group {
                    if classic {
                        Button { back() } label: { Label("Back", systemImage: "chevron.left").classicGlassPill(size: 44) }
                            .buttonStyle(HoverButton()).keyboardShortcut("[", modifiers: .command)
                    } else { BackPill { back() } }
                }.helpLabel(isFullScreen ? "Exit full screen (Esc)" : "Back (Esc)")
            }
            CachedImage(url: emby.image(item.SeriesId ?? item.Id, "Logo", width: 400)) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: { EmptyView() }
            .frame(maxWidth: 160, maxHeight: 40, alignment: .leading)
            Spacer()
            Group {
                if classic { GlassSlider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), range: 0...1) }
                else { Slider(value: $model.volume, in: 0...1).tint(.white).controlSize(.small) }
            }.frame(width: 160).handCursor()
            iconButton(model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 18) {
                model.volume = model.volume > 0 ? 0 : 1
            }.helpLabel(model.volume == 0 ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    // MARK: Bottom bar

    /// The timeline: the glass slider in the Classic theme, the standard one otherwise.
    @ViewBuilder var timeline: some View {
        let pos = Binding(get: { scrubbing ? scrub : model.time }, set: { scrub = $0 })
        let edit: (Bool) -> Void = { editing in
            if editing { scrub = model.time; scrubbing = true }
            else { model.seek(to: scrub); scrubbing = false }
        }
        if classic {
            GlassSlider(value: pos, range: 0...max(model.duration, 1), onEditing: edit)
        } else {
            Slider(value: pos, in: 0...max(model.duration, 1), onEditingChanged: edit).tint(accent).controlSize(.small)
        }
    }

    var episodeLine: String? {
        guard item.isEpisode else { return nil }
        return "S\(item.ParentIndexNumber ?? 0):E\(item.IndexNumber ?? 0) - \(item.Name)"
    }

    var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let l = episodeLine { Text(l).font(.cv(16, weight: .medium)).opacity(0.85) }
                    Text(item.heroTitle).font(.cv(28, weight: .bold))
                }
                Spacer()
                HStack(spacing: 26) {
                    iconButton("captions.bubble", on: panel != nil) {
                        withAnimation(.easeOut(duration: 0.2)) { panel = panel == nil ? .subtitles : nil }
                    }.helpLabel("Subtitles, audio, quality & speed")
                }
            }

            timeline
            .handCursor()
            .background(GeometryReader { g in
                Color.clear.onAppear { sliderW = g.size.width }.onChange(of: g.size.width) { _, w in sliderW = w }
            })
            .onContinuousHover { ph in
                if case .active(let p) = ph { hoverX = p.x } else { hoverX = nil }
            }
            .overlay(alignment: .bottomLeading) { scrubPreview }

            HStack {
                Text(fmt(scrubbing ? scrub : model.time))
                Spacer()
                Text("-\(fmt(max(0, model.duration - (scrubbing ? scrub : model.time))))  /  \(endClock)")
            }
            .font(.cv(14).monospacedDigit()).opacity(0.85)

            HStack(spacing: 30) {
                iconButton("backward.end.fill", size: 18) { if let p = prevEp { play(p) } else { model.seek(to: 0) } }
                    .helpLabel("Previous")
                iconButton("gobackward.\(skipSecs)", size: 22) { model.skip(-Double(skipSecs)) }.helpLabel("Back \(skipSecs) seconds")
                Button { model.togglePlay(); poke() } label: {
                    if classic {
                        Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                            .classicGlassPill(size: 60)
                    } else {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.cv(22, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color.white))
                            .contentShape(Circle())
                    }
                }.buttonStyle(HoverButton()).helpLabel(model.playing ? "Pause (Space)" : "Play (Space)")
                iconButton("goforward.\(skipSecs)", size: 22) { model.skip(Double(skipSecs)) }.helpLabel("Forward \(skipSecs) seconds")
                iconButton("forward.end.fill", size: 18) { if let n = nextEp { play(n) } }
                    .opacity(nextEp == nil ? 0.35 : 1).disabled(nextEp == nil).helpLabel("Next")
                Spacer()
                classicExtraButtons
                iconButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 18) {
                    toggleFullScreen()
                }.helpLabel(isFullScreen ? "Exit full screen (F)" : "Full screen (F)")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 34).padding(.bottom, 24)
    }

    @ViewBuilder func iconButton(_ name: String, size: CGFloat = 22, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        if classic {
            // Glass button; an open panel shows as a brighter icon
            Button { action(); poke() } label: {
                Label(name, systemImage: name).classicGlassPill(size: size + 24).opacity(on ? 1 : 0.92)
                    .overlay { if on { Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1) } }
            }.buttonStyle(HoverButton())
        } else {
            plainIconButton(name, size: size, on: on, action)
        }
    }

    func plainIconButton(_ name: String, size: CGFloat, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).font(.cv(size, weight: .medium))
                .frame(width: size + 12, height: size + 12)
                .foregroundColor(on ? accent : .white)
                .background(Circle().fill(Color.white.opacity(on ? 0.12 : 0)))
                .contentShape(Rectangle())
        }.buttonStyle(HoverButton(backing: true))
    }

    // MARK: Panels

    @ViewBuilder var panelLayer: some View {
        switch panel {
        case .subtitles:
            if classic {
                // Right above its button (top right of the controls), growing from it
                VStack { Spacer(); HStack { Spacer(); mediaPanel } }
                    .padding(.top, 84).padding(.bottom, 196).padding(.trailing, 30)
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                HStack { Spacer(); mediaPanel }
                    .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        case .appearance:
            HStack { Spacer(); appearancePanel }.transition(.move(edge: .trailing))
        case .episodes:
            HStack { Spacer(); classicEpisodesPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .chapters:
            HStack { Spacer(); classicChaptersPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case nil: EmptyView()
        }
    }

    @ViewBuilder var resetAppearanceButton: some View {
        let reset = { subTextSize = "normal"; subColor = "white"; subShadow = "drop"; subBg = "none"; subBottom = 10 }
        if classic {
            Button(action: reset) {
                Text("Reset to Default").font(.cv(13, weight: .semibold)).padding(.horizontal, 16).frame(height: 34).classicGlassPill()
            }.buttonStyle(HoverButton())
        } else {
            Button("Reset to Default", action: reset)
        }
    }

    @ViewBuilder var retryButton: some View {
        if classic {
            Button { Task { await model.retryTranscoded(emby) } } label: {
                Label("Retry with transcoding", systemImage: "arrow.clockwise").classicGlassPill(size: 40, iconOnly: false)
            }.buttonStyle(HoverButton())
        } else {
            Button("Retry with transcoding") { Task { await model.retryTranscoded(emby) } }
        }
    }

    func row(_ icon: String, _ title: String, sub: String? = nil, checked: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: classic ? 12 : 18) {
                Image(systemName: icon).font(.cv(classic ? 14 : 18)).frame(width: classic ? 20 : 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.cv(classic ? 13 : 16, weight: classic ? .medium : .regular)).lineLimit(1)
                    if let sub { Text(sub).font(.cv(classic ? 11 : 13)).foregroundColor(.secondary) }
                }
                Spacer()
                if checked { Image(systemName: "checkmark").font(.cv(classic ? 12 : 15, weight: .semibold)) }
            }
            .foregroundColor(classic ? .white : (checked ? accent : .white))
            .padding(.horizontal, classic ? 12 : 22).padding(.vertical, classic ? 7 : 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle(glass: classic))
        .padding(.horizontal, classic ? 6 : 0)
    }

    func sectionTitle(_ t: String) -> some View {
        Text(classic ? t.uppercased() : t).font(.cv(classic ? 10 : 13, weight: .semibold)).foregroundColor(.secondary)
            .kerning(classic ? 0.6 : 0)
            .padding(.horizontal, classic ? 18 : 22).padding(.top, classic ? 8 : 10).padding(.bottom, 4)
    }

    func panelDivider() -> some View { Divider().padding(.horizontal, 18).padding(.vertical, 6) }

    /// One side panel with everything the old Subtitles, Speed and Settings popups had.
    var mediaPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Subtitles")
                row("captions.bubble", "Off", checked: model.sub == nil) { Task { await model.setSub(emby, nil) } }
                ForEach(model.subStreams) { st in
                    row("captions.bubble", st.DisplayTitle ?? "Track \(st.Index)", checked: model.sub == st.Index) {
                        Task { await model.setSub(emby, st.Index) }
                    }
                }
                HStack(spacing: 18) {
                    Image(systemName: "timer").font(.cv(18)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Subtitle Offset").font(.cv(16))
                        Text("\(model.subOffset) ms").font(.cv(13)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { model.subOffset -= 100 } label: { Image(systemName: "minus.circle") }.buttonStyle(.plainHand)
                        .helpLabel("Show subtitles 100 ms earlier")
                    Button { model.subOffset = 0 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plainHand)
                        .opacity(model.subOffset == 0 ? 0.3 : 1).helpLabel("Reset offset")
                    Button { model.subOffset += 100 } label: { Image(systemName: "plus.circle") }.buttonStyle(.plainHand)
                        .helpLabel("Show subtitles 100 ms later")
                }
                .font(.cv(classic ? 14 : 18))
                .padding(.horizontal, classic ? 18 : 22).padding(.vertical, classic ? 6 : 9)
                row("textformat.size", "Subtitle Appearance") { withAnimation { panel = .appearance } }

                if model.audioStreams.count > 0 {
                    panelDivider()
                    sectionTitle("Audio")
                    ForEach(model.audioStreams) { st in
                        row("waveform", st.DisplayTitle ?? "Track \(st.Index)", checked: model.audio == st.Index) {
                            Task { await model.setAudio(emby, st.Index) }
                        }
                    }
                }

                panelDivider()
                sectionTitle("Quality")
                ForEach([(0, "Original"), (8_000_000, "1080p · 8 Mbps"), (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")], id: \.0) { q in
                    row("dial.medium", q.1, checked: model.quality == q.0) { Task { await model.setQuality(emby, q.0) } }
                }

                panelDivider()
                sectionTitle("Speed")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0] as [Float], id: \.self) { r in
                        let on = model.speed == r
                        Button { model.setSpeed(r) } label: {
                            Text(r == 1 ? "1×" : String(format: "%g×", r)).font(.cv(classic ? 12 : 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: classic ? 28 : 36)
                                .foregroundColor(classic || !on ? .white : .black)
                                .background {
                                    if classic {
                                        // glass pills; the chosen speed lit in the accent
                                        Capsule().fill(on ? accent.opacity(0.55) : Color.white.opacity(0.06))
                                            .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.4 : 0.15), lineWidth: 0.75))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8).fill(on ? accent : Color.white.opacity(0.1))
                                    }
                                }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plainHand).helpLabel(r == 1 ? "Normal speed" : "\(String(format: "%g", r))× speed")
                    }
                }
                .padding(.horizontal, classic ? 18 : 22).padding(.bottom, 6)
            }
            .padding(.vertical, classic ? 8 : 12)
        }
        .frame(width: classic ? 290 : 340)
        .frame(maxHeight: classic ? 440 : .infinity)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}   // keep taps inside the panel
    }

    @ViewBuilder func dropdown<T: Hashable>(_ label: String, _ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
        if classic {
            // Classic: the glass pill and glass list
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.cv(12, weight: .medium)).foregroundColor(.white.opacity(0.75))
                GlassPicker(selection: sel, options: opts, maxWidth: 300)
            }
        } else {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.cv(15)).foregroundColor(.white.opacity(0.85))
            Menu {
                ForEach(opts, id: \.0) { o in
                    Button { sel.wrappedValue = o.0 } label: {
                        if sel.wrappedValue == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                    }
                }
            } label: {
                HStack {
                    Text(opts.first { $0.0 == sel.wrappedValue }?.1 ?? "").font(.cv(16))
                    Spacer()
                    Image(systemName: "chevron.down").font(.cv(13, weight: .bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.white.opacity(0.1)).cornerRadius(6)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).handCursor()
        }
        }
    }

    var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                Button { withAnimation { panel = .subtitles } } label: { Image(systemName: "xmark").font(.cv(18, weight: .semibold)) }
                    .buttonStyle(.plainHand)
                Text("Subtitle Appearance").font(.cv(18, weight: .bold))
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dropdown("Text size", $subTextSize, Self.sizes.map { ($0.0, $0.1) })
                    dropdown("Text color", $subColor, Self.colors.map { ($0.0, $0.1) })
                    dropdown("Drop shadow", $subShadow, Self.shadows)
                    dropdown("Background color", $subBg, Self.bgs.map { ($0.0, $0.1) })
                    Text("Subtitle Position").font(.cv(20, weight: .bold)).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        dropdown("Bottom Edge Position", $subBottom, [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") })
                        Text("Set the vertical position of the subtitles relative to the bottom of the screen.")
                            .font(.cv(13)).foregroundColor(.secondary)
                    }
                    resetAppearanceButton.padding(.top, 6)
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .frame(width: classic ? 340 : 400)
        .frame(maxHeight: .infinity)
        .modifier(AppearanceSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }
}

extension ClassicPlayerView {
    // MARK: Extra controls

    static let qualities: [(Int, String)] = [(0, "Original"), (8_000_000, "1080p · 8 Mbps"),
                                             (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")]

    /// Quick dropdown: subtitle language.
    var classicSubtitleMenu: some View {
        Menu {
            Button { Task { await model.setSub(emby, nil) } } label: {
                if model.sub == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            ForEach(model.subStreams) { st in
                let name = st.DisplayTitle ?? "Track \(st.Index)"
                Button { Task { await model.setSub(emby, st.Index) } } label: {
                    if model.sub == st.Index { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            classicMenuIcon("captions.bubble", on: model.sub != nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().modifier(HoverBacking())
        .helpLabel("Subtitles")
    }

    /// Quick dropdown: video quality.
    var classicQualityMenu: some View {
        Menu {
            ForEach(Self.qualities, id: \.0) { q in
                Button { Task { await model.setQuality(emby, q.0) } } label: {
                    if model.quality == q.0 { Label(q.1, systemImage: "checkmark") } else { Text(q.1) }
                }
            }
        } label: {
            classicMenuIcon("dial.medium", on: model.quality != 0)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().modifier(HoverBacking())
        .helpLabel("Video quality")
    }

    func classicMenuIcon(_ name: String, on: Bool) -> some View {
        Image(systemName: name).font(.cv(18, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundColor(on ? accent : .white)
            .contentShape(Rectangle())
    }

    var classicExtraButtons: some View {
        HStack(spacing: 22) {
            if item.isEpisode && episodes.count > 1 {
                iconButton("rectangle.stack", size: 18, on: panel == .episodes) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if panel != .episodes { pickerSeason = item.ParentIndexNumber ?? 1 }
                        panel = panel == .episodes ? nil : .episodes
                    }
                }.helpLabel("Episodes (E)")
            }
            if classic {
                // Glass buttons opening the glass list, as the other controls
                if !model.subStreams.isEmpty {
                    let subs = [nil] + model.subStreams.map { Optional($0.Index) }
                    GlassMenuButton(icon: "captions.bubble", on: model.sub != nil,
                                    options: ["Off"] + model.subStreams.map { $0.DisplayTitle ?? "Track \($0.Index)" },
                                    selected: subs.firstIndex(of: model.sub) ?? 0) { i in
                        Task { await model.setSub(emby, subs[i]) }
                    }.accessibilityLabel("Subtitles")
                }
                GlassMenuButton(icon: "dial.medium", on: model.quality != 0, options: Self.qualities.map(\.1),
                                selected: Self.qualities.firstIndex { $0.0 == model.quality } ?? 0) { i in
                    Task { await model.setQuality(emby, Self.qualities[i].0) }
                }.accessibilityLabel("Video quality")
            } else {
                if !model.subStreams.isEmpty { classicSubtitleMenu }
                classicQualityMenu
            }
            if !model.chapterList.isEmpty {
                iconButton("list.bullet.rectangle", size: 18, on: panel == .chapters) {
                    withAnimation(.easeOut(duration: 0.2)) { panel = panel == .chapters ? nil : .chapters }
                }.helpLabel("Chapters (C)")
            }
            iconButton("info.circle", size: 18, on: showInfo) { showInfo.toggle() }.helpLabel("Playback info (I)")
            if model.pipSupported {
                iconButton(model.pipActive ? "pip.exit" : "pip.enter", size: 18, on: model.pipActive) { model.togglePiP() }
                    .helpLabel("Picture in picture (P)")
            }
        }
    }

    var classicPipPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip").font(.cv(44))
            Text("Playing in picture in picture").font(.cv(16, weight: .medium))
        }.opacity(0.6).allowsHitTesting(false)
    }

    // MARK: Scrub preview

    @ViewBuilder var scrubPreview: some View {
        let x: CGFloat? = scrubbing ? CGFloat(scrub / max(model.duration, 1)) * sliderW : hoverX
        if let x, model.duration > 0 {
            let t = Double(max(0, min(x, sliderW)) / max(sliderW, 1)) * model.duration
            let img = model.hasThumbs ? model.thumb(at: t) : nil
            let w: CGFloat = img == nil ? 64 : 220
            VStack(spacing: 4) {
                if let img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: w).cornerRadius(classic ? 10 : 6)
                        .modifier(PreviewFrame(classic: classic))
                }
                Text(fmt(t)).font(.cv(13, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, classic ? 10 : 6).padding(.vertical, classic ? 4 : 2)
                    .modifier(TimeBubble(classic: classic))
            }
            .frame(width: w)
            .offset(x: min(max(0, x - w / 2), max(0, sliderW - w)), y: -26)
            .allowsHitTesting(false)
        }
    }

    // MARK: Intro / up next (bottom-right corner)

    var classicShowUpNext: Bool {
        guard item.isEpisode, nextEp != nil, !upNextCancelled, model.duration > 120 else { return false }
        return model.time >= model.duration - 30 && model.time < model.duration - 0.5
    }

    /// Whole seconds until the episode ends.
    var classicSecsLeft: Int { max(0, Int((model.duration - model.time).rounded(.up))) }

    var classicCornerCards: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()
            if model.skippedIntro {
                HStack(spacing: 12) {
                    Image(systemName: "forward.fill")
                    Text("Intro skipped").font(.cv(15, weight: .semibold))
                    Button("Watch intro") { model.watchIntro() }.buttonStyle(.plainHand)
                        .font(.cv(15, weight: .semibold)).foregroundColor(accent)
                }
                .padding(.horizontal, 18).frame(height: 44)
                .searchGlass()
                .transition(.opacity)
            } else if model.inIntro {
                Button { model.skipIntro() } label: {
                    Label("Skip Intro", systemImage: "forward.fill").font(.cv(16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22).frame(height: 44)
                        .searchGlass()
                }.buttonStyle(HoverButton())
            }
            if classicShowUpNext, let n = nextEp { classicUpNextCard(n) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 34)
        .padding(.bottom, showUI ? 200 : 40)
        .animation(.easeOut(duration: 0.2), value: model.skippedIntro)
    }

    func classicUpNextCard(_ n: Item) -> some View {
        HStack(spacing: 14) {
            CachedImage(url: emby.image(n.Id, "Primary", width: 400, plain: true)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.white.opacity(0.1) }
            .frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Up next").font(.cv(12, weight: .semibold)).foregroundColor(.secondary)
                Text("S\(n.ParentIndexNumber ?? 0):E\(n.IndexNumber ?? 0) · \(n.Name)")
                    .font(.cv(15, weight: .semibold)).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 10) {
                    Button { play(n) } label: {
                        Text("Play now").font(.cv(14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .classicGlassPill()
                    }.buttonStyle(HoverButton())
                    Button { upNextCancelled = true } label: {
                        Text("Cancel").font(.cv(14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .classicGlassPill()
                    }.buttonStyle(HoverButton())
                }
                if autoNext {
                    Text("Next starts in \(classicSecsLeft)s")
                        .font(.cv(11)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .glassPanel()
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    // MARK: Playback info

    var classicInfoOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Playback info").font(.cv(13, weight: .bold))
                    ForEach(Array(infoLines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(l.0).foregroundColor(.white.opacity(0.6)).frame(width: 120, alignment: .leading)
                            Text(l.1).frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
                .font(.cv(12).monospacedDigit())
                .padding(14)
                .modifier(InfoSurface(classic: classic))
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 70).padding(.leading, 20)
        .allowsHitTesting(false)
    }

    // MARK: Episodes panel

    var classicEpisodesPanel: some View {
        let seasons = Array(Set(episodes.map { $0.ParentIndexNumber ?? 0 })).sorted()
        let list = episodes.filter { ($0.ParentIndexNumber ?? 0) == pickerSeason }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Episodes").font(.cv(18, weight: .bold))
                Spacer()
                if seasons.count > 1 {
                    if classic {
                        GlassPicker(selection: $pickerSeason, options: seasons.map { ($0, $0 == 0 ? "Specials" : "Season \($0)") })
                    } else {
                        Picker("", selection: $pickerSeason) {
                            ForEach(seasons, id: \.self) { n in Text(n == 0 ? "Specials" : "Season \(n)").tag(n) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { ep in classicEpisodePickerRow(ep).id(ep.Id) }
                    }.padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo(item.Id, anchor: .center) }
            }
        }
        .frame(width: 400)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    func classicEpisodePickerRow(_ ep: Item) -> some View {
        let current = ep.Id == item.Id
        let played = emby.isPlayed(ep)
        return Button { if !current { panel = nil; play(ep) } } label: {
            HStack(spacing: 12) {
                CachedImage(url: emby.image(ep.Id, width: 320, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 120, height: 68).clipped().cornerRadius(5)
                .overlay {
                    if current {
                        Image(systemName: "speaker.wave.2.fill").font(.cv(18)).foregroundColor(.white)
                            .padding(6).background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if played && !current {
                        Image(systemName: "checkmark.circle.fill").font(.cv(14))
                            .foregroundColor(.white).shadow(radius: 2).padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ep.IndexNumber ?? 0). \(ep.Name)").font(.cv(14, weight: .semibold)).lineLimit(2)
                    if let t = ep.RunTimeTicks, t > 0 {
                        Text(runtimeText(t)).font(.cv(12)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(classic || !current ? .white : accent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background {
                // Classic: the playing one on an accent glass band, as the chosen line in the glass lists
                if classic && current { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.4)) }
                else if current { Color.white.opacity(0.08) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle(glass: classic)).padding(.horizontal, classic ? 6 : 0)
    }

    // MARK: Chapters panel

    var classicChaptersPanel: some View {
        let list = model.chapterList
        let cur = list.lastIndex { $0.c.start <= model.time }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Chapters")
                ForEach(Array(list.enumerated()), id: \.offset) { k, e in
                    classicChapterRow(e.i, e.c, current: k == cur)
                }
            }.padding(.vertical, 12)
        }
        .frame(width: 380)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    func classicChapterRow(_ i: Int, _ c: Chapter, current: Bool) -> some View {
        Button { model.seek(to: c.start); panel = nil } label: {
            HStack(spacing: 14) {
                Group {
                    if let tag = c.ImageTag {
                        CachedImage(url: emby.chapterImage(item.Id, i, tag)) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color.white.opacity(0.08) }
                    } else { Color.white.opacity(0.08) }
                }
                .frame(width: 112, height: 63).clipped().cornerRadius(5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.Name ?? "Chapter \(i + 1)").font(.cv(15)).lineLimit(2)
                    Text(fmt(c.start)).font(.cv(13).monospacedDigit()).foregroundColor(.secondary)
                }
                Spacer()
            }
            .foregroundColor(classic || !current ? .white : accent)
            .padding(.horizontal, classic ? 12 : 18).padding(.vertical, 7)
            .background {
                if classic && current { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.4)) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle(glass: classic)).padding(.horizontal, classic ? 6 : 0)
    }
}


extension View {
    /// `play`: size of the play button shown on hover (0 = none).
    func classicHoverLift(play: CGFloat = 0, onPlay: (() -> Void)? = nil) -> some View { modifier(SelfHoverLift(play: play, onPlay: onPlay)) }
}

/// A page's name at the top left (a library, Favorites): its icon and name in 3D lettering.
struct ClassicPageTitle: View {
    let text: String
    var icon: String? = nil
    static func icon(_ kind: String?) -> String {
        switch kind {
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
            if let icon { Text3D(image: Image(systemName: icon), size: 18) }
            Text3D(text: text, size: 22)
        }
    }
}

/// Lettering with depth: glossy white (light on top, shade at the bottom), grey layers stepped down-right under
/// it as its thickness, and a soft shadow.
struct Text3D: View {
    var text: String = ""
    var image: Image? = nil
    var size: CGFloat
    /// The grey thickness under the letters (off: just the glossy face and its shadow).
    var thick = false
    var weight: Font.Weight = .heavy
    @ViewBuilder var glyph: some View {
        if let image { image.font(.cv(size * 0.85, weight: .bold)) } else { Text(text).font(.cv(size, weight: weight)) }
    }
    var body: some View {
        let depth = max(2, Int(size / 6))
        ZStack {
            // Thickness: dark layers stepped down-right
            if thick { ForEach(1...depth, id: \.self) { i in
                glyph.foregroundColor(Color(white: 0.5 - Double(i) * 0.05))   // grey, so it shows on a black page
                    .offset(x: CGFloat(i) * 0.7, y: CGFloat(i) * 1.0)
            } }
            glyph.foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.92), Color(white: 0.62)],
                                                 startPoint: .top, endPoint: .bottom))
        }
        .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 3)
    }
}

/// One letter of the Classic A–Z bar: the original look, plus a pointing hand and a light circle under the mouse.
struct ClassicAlphaLetter: View {
    let l: String
    let on: Bool
    let action: () -> Void
    /// Dock-style zoom: set by the bar from how close the pointer is to this letter.
    var scale: CGFloat = 1
    var hovering: (Bool) -> Void = { _ in }
    @State private var hover = false
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        Button(action: action) {
            // The chosen letter lit in the accent, the one under the pointer in the top bar's hover look
            Text(l).font(.cv(11, weight: .bold))
                .frame(width: 20, height: 18)
                .foregroundColor(on || hover ? .white : .white.opacity(0.55))
                .background {
                    if on {
                        Circle().fill(Theme.accent(accentName).opacity(0.6))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                    } else if hover {
                        ClassicHoverEffect()   // the top bar's hover look (Settings → General → Hover effect)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .scaleEffect(scale)
        .padding(.vertical, (scale - 1) * 9)   // a zoomed letter makes room, so its neighbours move apart
        // The pointer covers the letter itself: a large preview of it beside the bar, to the left, in a teardrop pointing at it
        .overlay(alignment: .trailing) {
            if hover {
                Text(l).font(.cv(19, weight: .heavy)).foregroundColor(.black.opacity(0.85))
                    .frame(width: 34, height: 36)
                    .offset(x: 7, y: -15)   // the turn moves the drop's round part up-left; the letter follows
                    .padding(.trailing, 8)   // the point
                    // The drop lies like a backslash: round part up-left, the point down-right at the letter
                    .background(TeardropGlass().rotationEffect(.degrees(45), anchor: .trailing))
                    .fixedSize()
                    .offset(x: -15, y: -6)   // the point reaches toward the letter under the pointer
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(scale > 1 ? 1 : 0)
        .onHover { inside in
            hover = inside
            hovering(inside)
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(on ? "Show all" : l == "#" ? "Titles starting with a number" : "Jump to \(l)")   // no tooltip
    }
}

/// One favorite person: poster-sized portrait and name; opens their page, heart on hover removes them.
struct ClassicFavPersonCard: View {
    @EnvironmentObject var emby: Emby
    let p: Item
    var body: some View {
        NavigationLink(value: PersonRef(id: p.id, name: p.Name)) {
            VStack(spacing: 8) {
                CachedImage(url: emby.image(p.id, width: 360)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.cv(50)).foregroundColor(.secondary) }
                }
                .frame(width: 150, height: 225).clipShape(RoundedRectangle(cornerRadius: 12))
                .modifier(ClassicLightCard(radius: 12, size: CGSize(width: 150, height: 225)))   // the posters' light glass edge
                .modifier(HoverPersonHeart(id: p.id, name: p.Name))
                .classicHoverLift()
                Text(p.Name).font(.cv(12, weight: .semibold)).lineLimit(1)
            }.frame(width: 150)
        }.buttonStyle(.plainHand)
    }
}

/// Every favorite person in a grid.
struct ClassicFavoritePeopleView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    @State private var people: [Item] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClassicPageTitle(text: "Favorite People", icon: "person.2.fill")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(people.filter { emby.isFav($0) }) { ClassicFavPersonCard(p: $0) }
                }
            }.padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .navigationTitle("Favorite People")
        .navigationBarBackButtonHidden(true)
        .toolbar { ClassicTitleBarItems(back: { dismiss() }) }
        .classicHideToolbarTitle()
        .task { people = await emby.favoritePeople() }
        .onChange(of: emby.favRevision) { Task { people = await emby.favoritePeople() } }
    }
}

