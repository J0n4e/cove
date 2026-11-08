import IOKit.pwr_mgt
import SwiftUI
import MediaPlayer
import AVKit

// MARK: - Theme

private struct BGKey: EnvironmentKey { static let defaultValue = Color.black }
extension EnvironmentValues {
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

/// One letter of the library A–Z bar.
struct AlphaLetter: View {
    let l: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(l).font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 17)
                .foregroundColor(on ? .white : hover ? .primary : .secondary)
                .background(Capsule().fill(on ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(hover ? 0.18 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(on ? "Show all" : l == "#" ? "Titles starting with a number" : "Jump to \(l)")
    }
}

/// Toolbar button in Apple TV glass; `active` (a filter in use) gets a lighter fill.
struct PillStyle: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.font(.callout.weight(.medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16).frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(active ? 0.22 : 0)))
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
        self.font(.title3).frame(width: 44, height: 44)
            .background(Color.white.opacity(0.14)).clipShape(Circle())
    }
}

let alphaLetters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

func runtimeText(_ t: Int64) -> String {
    let m = Int(t / 600_000_000)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}
func endsAtText(_ t: Int64) -> String {
    Date().addingTimeInterval(Double(t) / 10_000_000).formatted(date: .omitted, time: .shortened)
}
func parseDate(_ s: String?) -> Date? {
    guard let s, s.count >= 19 else { return nil }
    return ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
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
            HoverCardLayer()
            if inline, let req = emby.playing {
                PlayerView(req: req).id(req.id).zIndex(10)
            }
        }
        // Settings → Playback → "Open videos in a separate window" (Apple TV style): open it when something
        // starts, close it when it stops
        .onChange(of: emby.playing?.id) { _, id in
            PlaybackFlag.shared.active = id != nil
            if id != nil { HoverCardCenter.shared.hide() }
            guard separatePlayer else { return }
            if id != nil { openWindow(id: "player") } else { dismissWindow(id: "player") }
        }
        // Switching the setting while a video plays: stop it cleanly (it would otherwise be left without a player)
        .onChange(of: separatePlayer) { _, _ in
            if emby.playing != nil { emby.playing = nil; dismissWindow(id: "player") }
        }
    }
}

struct LoginView: View {
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
                if !error.isEmpty { Text(error).foregroundColor(.orange).font(.caption).multilineTextAlignment(.center) }
            }
            .frame(width: showForm ? 340 : 520).padding(36)
            .background(Color.black.opacity(0.75)).cornerRadius(8)
        }
    }

    var serverList: some View {
        VStack(spacing: 14) {
            Text("Select Server").font(.title.bold()).padding(.bottom, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                ForEach(emby.servers) { s in serverCard(s) }
                Button { startAdd() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 34, weight: .light))
                            .frame(width: 150, height: 100)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6])))
                        Text("Add Server").font(.headline)
                        Text(" ").font(.caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if busy { Spinner().controlSize(.small) }
        }
    }

    func serverCard(_ s: SavedServer) -> some View {
        Button { open(s) } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "server.rack").font(.system(size: 38))
                        .frame(width: 150, height: 100)
                        .background(Color.white.opacity(0.08)).cornerRadius(10)
                    if s.token != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(6)
                            .help("Signed in")
                    }
                }
                HStack(spacing: 5) { ConnectionBadge(address: s.url).font(.caption); Text(s.name).font(.headline).lineLimit(1) }
                Text((s.user.isEmpty ? s.url : "\(s.user) · \(s.url)") + " · " + emby.kindLabel(s))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 150).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy)
        .contextMenu {
            Button("Edit / Sign In Again") { edit(s) }
            Button("Remove Server", role: .destructive) { emby.removeServer(s) }
        }
    }

    var form: some View {
        VStack(spacing: 14) {
            HStack {
                if !emby.servers.isEmpty {
                    Button { adding = false; error = "" } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).help("Back to servers")
                }
                Spacer()
                Text(emby.servers.isEmpty ? "Sign In" : "Add Server").font(.title.bold())
                Spacer()
                if !emby.servers.isEmpty { Image(systemName: "chevron.left").hidden() }
            }.padding(.bottom, 6)
            TextField("Name (optional, e.g. Home Jellyfin)", text: $serverLabel).focused($focus, equals: .name)
                .onSubmit { focus = .server }
            TextField("Server (e.g. 192.168.1.10:8096)", text: $server).focused($focus, equals: .server)
                .onSubmit { focus = .user }
            TextField("Username", text: $user).focused($focus, equals: .user).onSubmit { focus = .pw }
            SecureField("Password", text: $pw).focused($focus, equals: .pw).onSubmit(go)
            Button(action: go) {
                HStack {
                    if busy { Spinner().controlSize(.small) }
                    Text("Sign In").bold().onAccent()
                }.frame(maxWidth: .infinity).padding(8)
            }.buttonStyle(.borderedProminent).disabled(busy || server.isEmpty || user.isEmpty)
        }
        .textFieldStyle(.roundedBorder).controlSize(.large)
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
            catch { self.error = "Couldn't sign in. Check server address and credentials." }
            busy = false
        }
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
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
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
            Image(systemName: icon).foregroundColor(Color(red: 0.24, green: 0.56, blue: 1))
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
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }.buttonStyle(.plain)
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
                .navigationDestination(for: Item.self) { DetailView(item: $0) }
                .navigationDestination(for: PersonRef.self) { PersonView(person: $0) }
                .navigationDestination(for: Feed.self) { FeedView(feed: $0) }
                .navigationDestination(for: FavoriteGridRef.self) { FavoriteGridView(title: $0.title, ids: $0.ids) }
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
                TopNavBar(back: path.isEmpty ? nil : { path.removeLast() })
                    .frame(width: geo.size.width).zIndex(1)
                detailPane(withSearch: false)
                    .frame(width: geo.size.width).clipped()
            }
        }.background(bg)
    }

    var body: some View {
        Group {
            if navStyle == "topbar" { topLayout } else { splitLayout }
        }
        .task { await emby.loadLibs() }
        .onAppear { updateTitleBarH(); nav.popToRoot = { path = NavigationPath(); nav.query = "" } }
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
        .onChange(of: [showFavorites, showNowPlaying, showRecent]) {
            let hidden = (!showFavorites && sel == "favorites") || (!showNowPlaying && sel == "nowplaying") || (!showRecent && sel == "recent")
            if hidden { nav.sel = "home" }
        }
        .onChange(of: emby.openRequest) { _, item in
            guard let item else { return }
            path.append(item)
            emby.openRequest = nil
        }
        .sheet(isPresented: showSettingsB) { SettingsView { reloadToken += 1 } }
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
    @Published var activeCount = 0
    @Published var showSettings = false
    var popToRoot: () -> Void = {}
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
            ViewThatFits(in: .horizontal) {
                TopNavButtons()
                ScrollView(.horizontal, showsIndicators: false) { TopNavButtons() }
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
    @EnvironmentObject var emby: Emby
    @ObservedObject private var nav = NavState.shared
    @AppStorage("showFavorites") private var showFavorites = true
    @AppStorage(NavOrder.key) private var navOrder = ""
    @AppStorage("showNowPlaying") private var showNowPlaying = true
    @AppStorage("showRecent") private var showRecent = true
    @AppStorage("topBarLabels") private var labels = "both"   // Settings → General: "both", "names" or "icons"
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
                .foregroundColor(on ? .white : .secondary)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(on ? Color.white.opacity(0.22) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(labels == "icons" ? title : "")   // names show on hover when only icons are shown
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
            if nav.searchOpen {
                HStack(spacing: 6) {
                    TextField("Search movies, shows, people", text: $nav.query).textFieldStyle(.plain).frame(width: 220)
                    if !nav.query.isEmpty {
                        Button { nav.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.white.opacity(0.1)).clipShape(Capsule())
            }
            Button { nav.searchOpen.toggle(); if !nav.searchOpen { nav.query = "" } } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .contentShape(Circle())
            }.buttonStyle(.plain).help("Search")
        }
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
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut("[", modifiers: .command)
        .help("Back (⌘[)")
        .disabled(emby.playing != nil)
    }
}

struct SearchBar: View {
    @Binding var query: String
    @Environment(\.appBG) var bg
    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search movies, shows, people", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: 280)
        }
        .padding(.horizontal, 32).padding(.vertical, 10)
        .background(bg)
    }
}

struct SearchView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let query: String
    @State private var results: [Item] = []
    @State private var people: [Item] = []
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Results for “\(query)”").font(.title2.bold())
                if !people.isEmpty { peopleRow }
                if !people.isEmpty && !results.isEmpty { Text("Titles").font(.title3.bold()).padding(.top, 8) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 18) {
                    ForEach(results) { PosterCard(item: $0) }
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

    /// Matching people as round photo tiles; each opens the person's page.
    var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(people) { p in
                        NavigationLink(value: PersonRef(id: p.Id, name: p.Name)) {
                            VStack(spacing: 6) {
                                CachedImage(url: emby.image(p.Id, width: 240)) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.system(size: 30)).foregroundColor(.secondary) }
                                }
                                .frame(width: 96, height: 96).clipShape(Circle())
                                .hoverLift()
                                Text(p.Name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(width: 110)
                        }
                        .buttonStyle(.plain).help("Show everything with \(p.Name)")
                    }
                }.padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Favorites

/// Movies and shows marked as favorite, in two sections. Refreshes each time the page is shown,
/// and hides anything un-favorited from the detail page right away.
struct FavoritesView: View {
    @EnvironmentObject var emby: Emby
    /// "row" (scrolling row per section), "grid" or "list"; set in Settings → Libraries.
    @AppStorage("favoritesLayout") private var layout = "row"
    @Environment(\.appBG) var bg
    @State private var items: [Item] = []
    @State private var loading = true

    var body: some View {
        let favs = items.filter { emby.isFav($0) }
        let movies = favs.filter { !$0.isSeries && !$0.isBox }
        let shows = favs.filter { $0.isSeries }
        let collections = favs.filter { $0.isBox }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Favorites").font(.title.bold())
                    if !favs.isEmpty { Text("\(favs.count) Items").foregroundColor(.secondary) }
                }
                if !movies.isEmpty { section("Favorite Movies", movies) }
                if !shows.isEmpty { section("Favorite Shows", shows) }
                if !collections.isEmpty { section("Favorite Collections", collections) }
                if loading && items.isEmpty { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if favs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "heart").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("No favorites yet").font(.headline)
                        Text("Tap the heart on a movie, show or collection to add it here.").foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .onAppear { Task { items = await emby.favorites(); loading = false } }
    }

    /// Emby-style row: "Favorite Movies ›" heading (opens the full grid) and a scrolling row of posters.
    func section(_ title: String, _ list: [Item]) -> some View {
        let byId = Dictionary(list.map { ($0.Id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 8) {
            // Opened through the page path (like every other page), so Back shows and the top bar can leave it
            NavigationLink(value: FavoriteGridRef(title: title, ids: list.map(\.Id))) {
                HStack(spacing: 6) {
                    Text(title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundColor(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Show all")
            if layout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(list) { PosterCard(item: $0) }
                }
            } else if layout == "list" {
                LazyVStack(spacing: 6) { ForEach(list) { ListRow(item: $0) } }
            } else {
                ArrowScrollRow(ids: list.map(\.Id), itemWidth: 170, spacing: 16, inset: 0) { id in
                    if let it = byId[id] { PosterCard(item: it) }
                }
            }
        }
    }
}

/// Full grid for one Favorites section (the › in the heading).
/// A Favorites section ("Favorite Movies ›" and so on) opened as a page.
struct FavoriteGridRef: Hashable {
    let title: String
    let ids: [String]
}

struct FavoriteGridView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let title: String
    let ids: [String]
    @State private var items: [Item] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                    ForEach(items.filter { emby.isFav($0) }) { PosterCard(item: $0) }
                }
            }.padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            let all = await emby.favorites()
            let set = Set(ids)
            items = all.filter { set.contains($0.Id) }
        }
    }
}

// MARK: - Now Playing (active sessions on the server)

struct NowPlayingView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @State private var sessions: [ActiveSession] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Now Playing").font(.title.bold())
                    if !sessions.isEmpty { Text("\(sessions.count) active").foregroundColor(.secondary) }
                }
                if !loaded { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "play.slash").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("Nothing is playing right now").font(.headline)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(sessions) { SessionCard(s: $0) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .task {
            while !Task.isCancelled {
                sessions = await emby.nowPlaying()
                loaded = true
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct SessionCard: View {
    @EnvironmentObject var emby: Emby
    let s: ActiveSession

    func clock(_ ticks: Int64?) -> String { timeString(Double(ticks ?? 0) / 10_000_000) }

    var icon: String {
        let c = (s.Client ?? "").lowercased() + " " + (s.DeviceName ?? "").lowercased()
        if c.contains("cove") || c.contains("embyflix") || c.contains("mac") { return "desktopcomputer" }
        if c.contains("web") || c.contains("chrome") || c.contains("firefox") || c.contains("safari") { return "globe" }
        if c.contains("iphone") || c.contains("ios") || c.contains("android") { return "iphone" }
        if c.contains("tv") || c.contains("roku") || c.contains("kodi") { return "tv" }
        return "display"
    }

    var body: some View {
        let it = s.NowPlayingItem!
        let pos = Double(s.PlayState?.PositionTicks ?? 0), dur = Double(it.RunTimeTicks ?? 0)
        let transcoding = s.PlayState?.PlayMethod == "Transcode"
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                CachedImage(url: emby.image(it.SeriesId ?? it.Id, width: 160)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 64, height: 96).clipped().cornerRadius(4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(it.SeriesName ?? it.Name).font(.headline).lineLimit(1)
                    if it.SeriesName != nil {
                        Text("S\(it.ParentIndexNumber ?? 0):E\(it.IndexNumber ?? 0) - \(it.Name)")
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if s.PlayState?.IsPaused == true { Image(systemName: "pause.fill").font(.caption) }
                        Text("\(clock(s.PlayState?.PositionTicks)) / \(clock(it.RunTimeTicks))").monospacedDigit()
                    }.foregroundColor(.secondary)
                    Text(transcoding ? "Transcode" : "Direct play")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(transcoding ? Color.orange.opacity(0.25) : Color.green.opacity(0.25)))
                        .help(s.TranscodingInfo?.TranscodeReasons?.joined(separator: ", ") ?? "")
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            // Progress: watched position, plus how far the server has transcoded
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.15))
                    if let c = s.TranscodingInfo?.CompletionPercentage {
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: g.size.width * min(1, c / 100))
                    }
                    Rectangle().fill(Color.accentColor).frame(width: dur > 0 ? g.size.width * min(1, pos / dur) : 0)
                }
            }.frame(height: 4)
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 26)).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.Client ?? "Unknown") \(s.ApplicationVersion ?? "")").font(.callout.weight(.semibold))
                    Text([s.DeviceName, s.UserName].compactMap { $0 }.joined(separator: " · ")).foregroundColor(.secondary)
                    if let ip = s.RemoteEndPoint { Text(ip).font(.caption).foregroundColor(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
    }
}

// MARK: - Person

struct PersonRef: Hashable { let id: String; let name: String }

/// Everything in the user's libraries featuring one actor / director.
struct PersonView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let person: PersonRef
    @Environment(\.dismiss) var dismiss
    @State private var items: [Item] = []
    @State private var bio = ""
    @State private var loading = true
    @State private var showBio = false

    var body: some View {
        let movies = items.filter { !$0.isSeries }
        let shows = items.filter { $0.isSeries }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !movies.isEmpty { section("Movies", movies) }
                if !shows.isEmpty { section("Shows", shows) }
                if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if items.isEmpty {
                    Text("Nothing in your libraries with \(person.name).").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .navigationTitle(person.name)
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            async let list = emby.itemsWithPerson(person.id)
            async let me = emby.person(person.id)
            items = await list
            bio = await me?.Overview ?? ""
            loading = false
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 24) {
            CachedImage(url: emby.image(person.id, width: 300)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.system(size: 50)).foregroundColor(.secondary) }
            }
            .frame(width: 140, height: 140).clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(person.name).font(.largeTitle.bold())
                if !loading {
                    Text("\(items.count) title\(items.count == 1 ? "" : "s") in your libraries").foregroundColor(.secondary)
                }
                if !bio.isEmpty {
                    Text(bio).foregroundColor(.secondary).lineLimit(showBio ? nil : 4).textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                    Button(showBio ? "Less" : "More") { showBio.toggle() }.buttonStyle(.plain).foregroundColor(.accentColor)
                }
            }
        }
    }

    func section(_ title: String, _ list: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) (\(list.count))").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                ForEach(list) { PosterCard(item: $0) }
            }
        }
    }
}

// MARK: - Home

struct HomeContent: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var nav = NavState.shared

    /// "Title ›" like Apple TV: opens the full list (feed page) or the library.
    @ViewBuilder func rowTitle(_ row: Row) -> some View {
        let label = HStack(spacing: 6) {
            Text(row.title).font(.system(size: 22, weight: .bold))
            Image(systemName: "chevron.right").font(.system(size: 17, weight: .bold)).foregroundColor(.secondary)
        }.contentShape(Rectangle())
        if let f = row.feed {
            NavigationLink(value: f) { label }.buttonStyle(.plain).help("Show all")
        } else if let id = row.libId {
            Button { nav.sel = id } label: { label }.buttonStyle(.plain).help("Open \(row.title)")
        } else {
            Text(row.title).font(.system(size: 22, weight: .bold))
        }
    }
    @Environment(\.appBG) var bg
    let reloadToken: Int
    @State private var rows: [Row] = []
    @State private var loading = true

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
            VStack(alignment: .leading, spacing: 30) {
                if !hero.isEmpty { Hero(items: hero) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 12) {
                        rowTitle(row).padding(.leading, 52)
                        if row.feed == .resume || row.feed == .nextUp {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 340, spacing: 22, inset: 52) {
                                ResumeCard(item: row.items[$0])
                            }
                        } else {
                            ArrowScrollRow(ids: Array(row.items.indices), itemWidth: 170, spacing: 22, inset: 52) {
                                PosterCard(item: row.items[$0])
                            }
                        }
                    }
                }
                if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
            }.padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)          // banner runs up under the title bar, as in Apple TV
        .background(bg)
        .task(id: reloadToken) {
            rows = await emby.loadHome(); loading = false
            // Look ahead: the first pictures of every row start downloading right away (low priority)
            var urls: [URL?] = []
            for row in rows {
                for it in row.items.prefix(10) {
                    if row.feed == .resume || row.feed == .nextUp {
                        urls.append(it.isEpisode ? emby.image(it.Id, width: 520, plain: true)
                                                 : emby.image(it.backdropId ?? it.Id, "Backdrop", width: 520))
                    } else {
                        urls.append(emby.image(it.posterId, width: 360))
                    }
                }
            }
            ImageCache.shared.prefetch(urls)
        }
    }
}

extension View {
    /// Black outline around text (four hairline shadows plus a soft one) so it reads on any picture.
    func blackOutline(_ w: CGFloat = 1) -> some View {
        self.shadow(color: .black, radius: 0, x: w, y: 0).shadow(color: .black, radius: 0, x: -w, y: 0)
            .shadow(color: .black, radius: 0, x: 0, y: w).shadow(color: .black, radius: 0, x: 0, y: -w)
            .shadow(color: .black.opacity(0.7), radius: 4)
    }
}

struct Hero: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let items: [Item]
    @State private var index = 0
    @State private var hover = false
    @State private var width: CGFloat = 1200
    var bannerH: CGFloat { min(max(width * 9 / 16, 460), 900) }

    /// "TV Show · Comedy · Sport", like Apple TV.
    func meta(_ item: Item) -> String {
        var m: [String] = [item.isEpisode || item.isSeries ? "TV Show" : "Movie"]
        m += (item.Genres ?? []).prefix(2)
        return m.joined(separator: " · ")
    }

    func step(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.6)) { index = (index + d + items.count) % items.count }
    }

    var body: some View {
        let item = items[index % items.count]
        ZStack(alignment: .bottomLeading) {
            // The banner takes the picture's own shape (16:9), so the whole backdrop shows instead of a cropped
            // strip; it never gets shorter than 460 pt (narrow windows) or taller than 860 pt (very wide ones)
            // Full window width always; height follows the picture's 16:9 shape (460–900 pt). On very wide
            // windows the picture fills the width and is trimmed a little at top and bottom, never side gaps.
            Color.clear.frame(maxWidth: .infinity).frame(height: bannerH)
                .overlay { Backdrop(id: item.backdropId ?? item.Id, width: min(Int(width * 2), 2560)) }.clipped()   // Retina-sharp, not oversized
                .id("b" + item.id).transition(.opacity)
            // Dark fade on the left and at the bottom, so the text reads and the page flows into the rows
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5))
            LinearGradient(colors: [.clear, .clear, bg.opacity(0.6), bg], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                if item.isEpisode {
                    Text("S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0)")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
                }
                TitleLogo(item: item, height: 90, font: 54)
                HStack(spacing: 8) {
                    Text(meta(item))
                    if let y = item.ProductionYear { Text("· \(String(y))") }
                    if let r = item.CommunityRating {
                        HStack(spacing: 3) { Image(systemName: "star.fill"); Text(String(format: "%.1f", r)) }
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.7)))
                            .font(.system(size: 12, weight: .semibold))
                    }
                }.font(.system(size: 16, weight: .medium))
                Text(item.Overview ?? "").font(.system(size: 15)).lineLimit(3)
                    .foregroundColor(.white.opacity(0.8)).frame(maxWidth: 420, alignment: .leading)
                HStack(spacing: 14) {
                    Button { Task { await emby.play(item) } } label: {
                        Label(emby.resumeAt(item) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 170, height: 46)
                            .background(Capsule().fill(.white)).foregroundColor(.black)
                    }.buttonStyle(.plain)
                    let fav = emby.isFav(item)
                    Button { Task { await emby.setFav(item.id, !fav) } } label: {
                        Image(systemName: fav ? "checkmark" : "plus").font(.system(size: 18, weight: .semibold))
                            .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(.plain).help(fav ? "Remove from Favorites" : "Add to Favorites")
                    NavigationLink(value: item) {
                        Image(systemName: "info").font(.system(size: 18, weight: .semibold))
                            .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(.plain).help("More info")
                }.padding(.top, 8)
            }
            .padding(.leading, 52).padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("t" + item.id).transition(.opacity)
            // Page dots, centered at the bottom
            HStack(spacing: 9) {
                ForEach(items.indices, id: \.self) { i in
                    Circle().fill(Color.white.opacity(i == index % items.count ? 1 : 0.4)).frame(width: 7, height: 7)
                        .contentShape(Rectangle().inset(by: -5))
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.6)) { index = i } }
                }
            }
            .frame(maxWidth: .infinity).padding(.bottom, 26)
        }
        .overlay {
            if hover && items.count > 1 {
                HStack {
                    heroArrow("chevron.left") { step(-1) }
                    Spacer()
                    heroArrow("chevron.right") { step(1) }
                }.padding(.horizontal, 14)
            }
        }
        .onHover { hover = $0 }
        .clipped()
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        .foregroundColor(.white)
        .task(id: index) {
            // Look ahead: the next two banners (picture and title logo) download while this one shows
            let w = min(Int(width * 2), 2560)
            var next: [URL?] = []
            for k in 1...2 where items.count > 1 {
                let it = items[(index + k) % items.count]
                next.append(emby.image(it.backdropId ?? it.Id, "Backdrop", width: w))
                next.append(emby.image(it.SeriesId ?? it.Id, "Logo", width: 700))
            }
            ImageCache.shared.prefetch(next)
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !Task.isCancelled { step(1) }
        }
    }

    func heroArrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 30, weight: .light))
                .frame(width: 44, height: 80).contentShape(Rectangle())
                .shadow(color: .black.opacity(0.6), radius: 4)
        }.buttonStyle(.plain)
    }
}

/// The title's logo image from Emby (Apple TV style); falls back to big bold text when there is none.
struct TitleLogo: View {
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
                Text(item.heroTitle).font(.system(size: font, weight: .heavy)).lineLimit(2)
                    .minimumScaleFactor(0.6).frame(maxWidth: 620, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
        }
        .frame(minHeight: 40, alignment: .bottomLeading)
    }
}

/// Landscape card for the Continue Watching row: still image, accent progress bar, time left.
struct ResumeCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false

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

    /// "42m" (time left), as on Apple TV's cards.
    var leftShort: String? {
        guard let total = item.RunTimeTicks, total > 0 else { return nil }
        return runtimeText(max(0, total - (item.UserData?.PlaybackPositionTicks ?? 0)))
    }

    var body: some View {
        CachedImage(url: imageURL) { p in
            p.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack { Color(white: 0.15); Text(item.heroTitle).font(.caption).padding(6) }
        }
        .frame(width: 340, height: 191).clipped()
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.heroTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if item.isEpisode {
                    Text("S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0) · \(item.Name)")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                }
                // Apple TV's bottom line: ▶ short progress bar, time left
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    if progress > 0 && progress < 1 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.35))
                            Capsule().fill(Color.white).frame(width: 34 * progress)
                        }.frame(width: 34, height: 4)
                    }
                    if let l = leftShort { Text(l).font(.system(size: 13, weight: .medium)) }
                    Spacer()
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.top, 36).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            if hover {
                Button { Task { await emby.play(item) } } label: {
                    Image(systemName: "play.fill").font(.system(size: 22)).foregroundColor(.white)
                        .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
                }.buttonStyle(.plain).help("Resume")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .thinBorder(12)
        .hoverLift()
        .frame(width: 340, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { openPage() }
        .help(item.isEpisode ? "\(item.heroTitle) — \(item.Name)" : item.Name)
    }
}

/// Full page for Continue Watching, Up Next or Recently Added.
struct FeedView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let feed: Feed
    var root = false
    @State private var items: [Item] = []
    @State private var loading = true
    var landscape: Bool { feed != .recent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(feed.rawValue).font(.system(size: 30, weight: .bold))
                if loading { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if items.isEmpty { Text("Nothing here yet.").foregroundColor(.secondary) }
                if landscape {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 22)], alignment: .leading, spacing: 22) {
                        ForEach(items) { ResumeCard(item: $0) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], alignment: .leading, spacing: 22) {
                        ForEach(items) { PosterCard(item: $0) }
                    }
                }
            }
            .padding(.horizontal, 52).padding(.vertical, 24)
        }
        .background(bg)
        .task { items = await emby.feed(feed); loading = false }
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: root ? nil : { dismiss() }) }
        .hideToolbarTitle()
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

struct PosterCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false
    // Settings → Libraries → Poster labels
    @AppStorage("posterShowTitle") private var showTitle = true
    @AppStorage("posterShowYear") private var showYear = true
    @AppStorage("posterLabelAlign") private var labelAlign = "center"
    var centered: Bool { labelAlign == "center" }
    var body: some View {
        let played = emby.isPlayed(item)
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CachedImage(url: emby.image(item.posterId, width: 360)) { p in
                        p.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack { Color(white: 0.15); Text(item.Name).font(.caption).padding(6) }
                    }
                    .frame(width: 170, height: 255).clipped()
                    .opacity(played ? 0.6 : 1)
                    WatchBadge(item: item, played: played).padding(8)
                }
                .overlay(alignment: .topLeading) {
                    if emby.isFav(item) {
                        Image(systemName: "heart.fill").font(.system(size: 14)).foregroundStyle(.tint)
                            .shadow(color: .black.opacity(0.6), radius: 3).padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let pct = item.UserData?.PlayedPercentage, pct > 0, pct < 100, !played {
                        ProgressView(value: pct / 100).padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .thinBorder(12)
                .modifier(HoverLift(hover: hover))
                if showTitle || showYear {
                    VStack(alignment: centered ? .center : .leading, spacing: 2) {
                        if showTitle { Text(item.Name).font(.callout.weight(.semibold)).lineLimit(1) }
                        if showYear { Text(item.yearText).font(.caption).foregroundColor(.secondary) }
                    }
                    .multilineTextAlignment(centered ? .center : .leading)
                    .frame(width: 170, alignment: centered ? .center : .leading)
                }
            }
            .frame(width: 170, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .zIndex(hover ? 1 : 0)
        }.buttonStyle(.plain)
    }
}

/// Pointer position on a poster in its own and in window coordinates (a class: writes don't redraw the poster).
final class PointerBox {
    var local = CGPoint.zero
    var global = CGPoint.zero
    var inside = false
}

/// Decides which poster's preview card is showing. Opens ~0.7 s after the pointer rests on a poster and stays
/// while the pointer is on the poster or on the card; closes ~0.3 s after it leaves both. Never while a video is
/// playing (the page behind the player is still alive). Closing is decided by polling the real pointer position,
/// so it doesn't depend on hover enter/exit events firing for a card that appears right under a resting pointer.
@MainActor
final class HoverCardCenter: ObservableObject {
    static let shared = HoverCardCenter()
    @Published var item: Item?
    @Published var anchor: CGRect = .zero        // the poster's frame in window coordinates
    var cardRect: CGRect = .zero                 // the card's frame in window coordinates (set by HoverCardLayer)
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

    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { @MainActor in
            var away = 0
            while !Task.isCancelled && item != nil {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if PlaybackFlag.shared.active { hide(); return }
                away = pointerInside() ? 0 : away + 1
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

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 340
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Window-level layer that draws the preview card centered on the hovered poster (kept inside the window),
/// above every row and column, so nothing clips or covers it.
/// The card zooms out of the middle of the poster when it opens and back into it when it closes
/// (Settings → Libraries → Hover preview: zoom on/off and duration).
struct HoverCardLayer: View {
    @ObservedObject private var center = HoverCardCenter.shared
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
                    .thinBorder(12)
                    .shadow(color: .black.opacity(0.6), radius: 24)
                    .scaleEffect(open ? 1 : 170 / w, anchor: UnitPoint(x: ux, y: uy))
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

/// One row in the library list view: poster, title, year, overview and watched badge.
struct ListRow: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    @State private var hover = false
    var body: some View {
        let played = emby.isPlayed(item)
        NavigationLink(value: item) {
            HStack(alignment: .top, spacing: 16) {
                CachedImage(url: emby.image(item.posterId, width: 160)) { p in
                    p.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(white: 0.15) }
                .frame(width: 60, height: 90).clipped().cornerRadius(4)
                .opacity(played ? 0.6 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.Name).font(.headline).lineLimit(1)
                    if let y = item.ProductionYear { Text(String(y)).font(.subheadline).foregroundColor(.secondary) }
                    Text(item.Overview ?? "").font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                WatchBadge(item: item, played: played)
            }
            .padding(8)
            .background(Color.white.opacity(hover ? 0.08 : 0.03)).cornerRadius(6)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }.buttonStyle(.plain)
    }
}

/// "‹ Back" pill button used on detail pages and in the player.
struct BackPill: View {
    var compact = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: "chevron.left").font(.system(size: compact ? 14 : 18, weight: .bold))
                Text("Back").font(.system(size: compact ? 14 : 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 5 : 10)
            .background(Capsule().fill(Color.black.opacity(hover ? 0.85 : 0.6)))
            .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.7 : 0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// Green badge: a check when the count is 0, otherwise the number.
struct CountBadge: View {
    let count: Int?
    var body: some View {
        if let n = count {
            if n == 0 {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(WatchBadge.green)).overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 3).help("All watched")
            } else {
                Text(n > 99 ? "99+" : "\(n)").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(WatchBadge.green)).overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .help("\(n) unwatched episode\(n == 1 ? "" : "s")")
            }
        }
    }
}

/// Top-right poster badge: green check when watched, unwatched-episode count for series.
/// Small white progress ring (how much of the episode you have watched), for the corner of a thumbnail.
struct ProgressRing: View {
    let progress: Double      // 0...1
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0.03, progress))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 3)
    }
}

/// Thin progress line along the bottom edge of a thumbnail (accent color, dim track).
struct EdgeProgressBar: View {
    let progress: Double      // 0...1
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.5))
                Rectangle().fill(.tint).frame(width: g.size.width * CGFloat(min(1, max(0, progress))))
            }
        }.frame(height: 3)
    }
}

struct WatchBadge: View {
    let item: Item
    let played: Bool
    /// Neutral badge fill (dark, with a light ring), so "watched" doesn't compete with the accent color.
    static let green = Color.black.opacity(0.7)

    var body: some View {
        if played {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Self.green)).overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .help("Watched")
        } else if item.isSeries, let n = item.UserData?.UnplayedItemCount, n > 0 {
            Text(n > 99 ? "99+" : "\(n)").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
                .background(Capsule().fill(Self.green)).overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .help("\(n) unwatched episode\(n == 1 ? "" : "s")")
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

    var body: some View {
        // No scrollbar: the arrows page the row; trackpad / wheel scrolling still works.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(ids, id: \.self) { id in content(id).id(id) }
            }
            .padding(.vertical, 8)
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
        .overlay(alignment: .leading) {
            if finder.canBack {
                arrow("chevron.left", help: "Previous") { finder.page(-1, step: itemWidth + spacing) }.padding(.leading, 6)
            }
        }
        .overlay(alignment: .trailing) {
            if finder.canFwd {
                arrow("chevron.right", help: "Next") { finder.page(1, step: itemWidth + spacing) }.padding(.trailing, 6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: finder.canBack)
        .animation(.easeOut(duration: 0.15), value: finder.canFwd)
    }

    func arrow(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.7)))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
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
        let v = NSView()
        DispatchQueue.main.async { finder.attach(v.enclosingScrollView) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if finder.scrollView == nil { DispatchQueue.main.async { finder.attach(v.enclosingScrollView) } }
    }
}

// MARK: - Library page (header, tabs, sort, filter; choices are remembered per library)

struct LibraryView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let lib: LibPref
    @State private var tab = 0
    @State private var items: [Item] = []
    @State private var total = 0
    @State private var loading = false
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
            }.padding(.leading, 40).padding(.trailing, 76).padding(.vertical, 24)   // room for the A–Z bar
        }
        .background(bg)
        .overlay(alignment: .trailing) { if tab != 2 { alphaBar } }
        .task(id: key) { await load(reset: true) }
        .task { genres = await emby.genres(lib) }
        .onChange(of: sort) { desc = (sort != "name") }
        .onChange(of: "\(sort)|\(desc)|\(watch)|\(genre)|\(layout)|\(groupCol)") { save() }
    }

    /// A–Z jump bar in a glass capsule. Each letter shows a pointing hand and lights up under the mouse;
    /// the chosen letter is filled with the accent color (click it again to show everything).
    var alphaBar: some View {
        VStack(spacing: 1) {
            ForEach(alphaLetters, id: \.self) { l in AlphaLetter(l: l, on: letter == l) { letter = (letter == l) ? "" : l } }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.black.opacity(0.4)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .padding(.trailing, 22)   // clear of the window's scroll bar
    }

    var header: some View {
        VStack(spacing: 16) {
            ZStack {
                HStack { Text(lib.title).font(.title2.bold()); Spacer() }
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Button { tab = i } label: {
                            Text(i == 0 ? lib.title : ["", "Collections", "Genres", "Favorites"][i])
                                .font(.callout.weight(tab == i ? .semibold : .regular))
                                .padding(.horizontal, 18).frame(height: 32)
                                .background(Capsule().fill(tab == i ? Color.white.opacity(0.22) : Color.clear))
                                .foregroundColor(tab == i ? .white : .secondary)
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).focusEffectDisabled()
                    }
                }.padding(4).frame(height: 40).glassCapsule()
            }
            if tab != 2 { controls }
        }
    }

    var controls: some View {
        HStack(spacing: 10) {
            Text("\(total) Items").foregroundColor(.secondary).padding(.trailing, 4)
            Button { Task { if let f = items.first { await emby.play(f) } } } label: {
                Label("Play", systemImage: "play.fill").pill()
            }.buttonStyle(.plain)
            Button { Task { await shuffle() } } label: {
                Label("Shuffle", systemImage: "shuffle").pill()
            }.buttonStyle(.plain)
            Menu {
                Picker("Sort by", selection: $sort) {
                    Text("Recently Added").tag("latest")
                    Text("Name").tag("name")
                    Text("Release Date").tag("release")
                    Text("Rating").tag("top")
                }.pickerStyle(.inline)
                Picker("Order", selection: $desc) {
                    Text("Ascending").tag(false)
                    Text("Descending").tag(true)
                }.pickerStyle(.inline)
            } label: {
                Label(sortLabel, systemImage: desc ? "arrow.down" : "arrow.up").pill()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                Picker("Status", selection: $watch) {
                    Text("All").tag("all")
                    Text("Unwatched").tag("unwatched")
                    Text("Watched").tag("watched")
                }.pickerStyle(.inline)
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag("")
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").pill(active: filtered)
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            if !genre.isEmpty {
                Button { genre = "" } label: { Label(genre, systemImage: "xmark").pill(active: true) }.buttonStyle(.plain)
            }
            layoutToggle
            Menu {
                if canGroup {
                    Toggle("Group by Collection", isOn: $groupCol)
                    Divider()
                }
                Button("Refresh") { Task { await load(reset: true) } }
            } label: { Image(systemName: "ellipsis").pill() }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    var grid: some View {
        VStack(spacing: 20) {
            if layout == "list" {
                LazyVStack(spacing: 6) {
                    ForEach(items) { it in
                        ListRow(item: it).onAppear {
                            if it.id == items.last?.id { Task { await load(reset: false) } }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 18) {
                    ForEach(items) { it in
                        PosterCard(item: it).onAppear {
                            if it.id == items.last?.id { Task { await load(reset: false) } }
                        }
                    }
                }
            }
            if loading { Spinner() }
            else if items.isEmpty { Text("Nothing here.").foregroundColor(.secondary).padding(40) }
        }
    }

    var layoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { layout = m.0 } label: {
                    Image(systemName: m.1).font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 28)
                        .background(Capsule().fill(layout == m.0 ? Color.white.opacity(0.22) : Color.clear))
                        .foregroundColor(layout == m.0 ? .white : .secondary)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).help(m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 36).glassCapsule()
    }

    var genreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(genres, id: \.self) { g in
                Button { genre = g; tab = 0 } label: {
                    Text(g).font(.headline).frame(maxWidth: .infinity, minHeight: 70)
                        .background(Color.white.opacity(0.1)).cornerRadius(8)
                }.buttonStyle(.plain)
            }
        }
    }

    func fetch(start: Int, limit: Int, sort s: String) async -> ItemList {
        await emby.libraryItems(lib, limit: limit, start: start, sort: s, desc: s == sort ? desc : nil,
                                watch: watch, genre: genre, letter: letter, favorites: tab == 3, types: types,
                                groupCollections: grouping)
    }

    func load(reset: Bool) async {
        if !reset && (loading || items.count >= total) { return }
        gen += 1
        let my = gen
        loading = true
        let r = await fetch(start: reset ? 0 : items.count, limit: 100, sort: sort)
        guard my == gen else { return }
        if reset { items = r.Items } else { items += r.Items }
        total = r.TotalRecordCount ?? items.count
        loading = false
    }

    func shuffle() async {
        let r = await fetch(start: 0, limit: 1, sort: "random")
        if let f = r.Items.first { await emby.play(f) }
    }
}

// MARK: - Detail / movie info

struct CastTile: View {
    @EnvironmentObject var emby: Emby
    let p: Full.Person
    var body: some View {
        VStack(spacing: 6) {
            CachedImage(url: emby.image(p.Id, width: 240)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack { Color(white: 0.18); Image(systemName: "person.fill").font(.system(size: 30)).foregroundColor(.secondary) }
            }
            .frame(width: 88, height: 88).clipShape(Circle())
            Text(p.Name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(p.Role ?? p.`Type` ?? "").font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }.frame(width: 104).multilineTextAlignment(.center)
    }
}

struct DetailView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @Environment(\.dismiss) var dismiss
    let item: Item
    @State private var full: Full?
    @State private var kids: [Item] = []
    @State private var seasonItems: [Item] = []
    @State private var epLangs: [(code: String, name: String)] = []
    @AppStorage("episodeSubLang") private var epSubLang = ""
    @AppStorage("subAlways") private var subAlwaysOn = false
    @AppStorage("subLang") private var prefSubLang = "english"
    /// First entry of the Subtitles menu: the preferred language when that setting is on, otherwise Off.
    var defaultSubLabel: String { subAlwaysOn ? prefSubLang.capitalized : "Off" }
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("showEpisodeDescription") private var showEpDesc = true   // Settings → Libraries → Series
    @State private var showAllEps = false                                  // "Show all" / "Hide watched" in a season
    @State private var similar: [Item] = []
    @State private var includedIn: [Item] = []
    @AppStorage("showIncludedIn") private var showIncludedIn = true   // Settings → Libraries
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

    var playLabel: String {
        let r = playTarget.map { emby.resumeAt($0) } ?? 0
        let verb = r > 0 ? "Resume" : "Play"
        if item.isSeries, let ep = nextEp { return "\(verb) S\(ep.ParentIndexNumber ?? 0):E\(ep.IndexNumber ?? 0)" }
        if r > 0 { return "Resume from \(timeString(r))" }
        return verb
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header.id("pageTop")
                    pickers
                    if item.isSeries { episodesList }
                    if item.isBox { boxGrid }
                    castSection
                    aboutSection
                    includedInSection
                    similarSection
                }.padding(.bottom, 50)
            }
            // Switching views adds or removes the Seasons posters above the episodes (row view has none), which
            // pushed the episodes and the view buttons out of sight on long shows: go back to the top of the page
            .onChange(of: epLayout) {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("pageTop", anchor: .top) }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
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
            if !item.isEpisode && !item.isBox && showIncludedIn { includedIn = await emby.collections(containing: item.id) }
            if !item.isEpisode { similar = await emby.similar(item.id) }
        }
        .onChange(of: srcIdx) { audioIdx = defaultAudio; subIdx = -1; applyPreferredSub() }
        .onChange(of: season) { showAllEps = false }
        .navigationBarBackButtonHidden(true)
        .toolbar { TitleBarItems(back: { dismiss() }) }
        .hideToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    @State private var moreText = false

    /// "Movie · Action · Drama", like Apple TV.
    var kindLine: String {
        let kind = item.isSeries ? "TV Show" : item.isEpisode ? "Episode" : item.isBox ? "Collection" : "Movie"
        return ([kind] + (full?.Genres ?? item.Genres ?? []).prefix(2)).joined(separator: " · ")
    }

    /// 4K / HD and CC badges from the media.
    var badges: [String] {
        var b: [String] = []
        if let w = streams("Video").first?.Width { b.append(w >= 3200 ? "4K" : w >= 1200 ? "HD" : "SD") }
        if !streams("Subtitle").isEmpty { b.append("CC") }
        return b
    }

    func badge(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.75), lineWidth: 1))
    }

    var starring: [String] { (full?.People ?? []).filter { $0.`Type` == "Actor" }.prefix(3).map { $0.Name } }
    var directors: [String] { (full?.People ?? []).filter { $0.`Type` == "Director" }.prefix(2).map { $0.Name } }

    // Header: Apple TV style, a full-width backdrop with the logo, info and buttons in the bottom-left corner
    var header: some View {
        ZStack(alignment: .bottomLeading) {
            // Fill the page width without growing it (a filled image sized by its own width widened the page)
            Color.clear.frame(maxWidth: .infinity).frame(height: 600)
                .overlay { Backdrop(id: item.backdropId ?? item.Id) }.clipped()
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .init(x: 0.65, y: 0.5))
            LinearGradient(colors: [.clear, .clear, bg.opacity(0.7), bg], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if item.isEpisode, let sn = item.SeriesName {
                        Text("\(sn) · S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0)")
                            .font(.system(size: 15, weight: .semibold)).opacity(0.85)
                    }
                    if item.isEpisode { Text(item.Name).font(.system(size: 44, weight: .heavy)).lineLimit(2) }
                    else { TitleLogo(item: item, height: 110, font: 52) }
                    HStack(spacing: 8) {
                        Text(kindLine)
                        if let o = full?.OfficialRating { badge(o) }
                        if let r = full?.CommunityRating {
                            HStack(spacing: 3) { Image(systemName: "star.fill").foregroundColor(.yellow); Text(String(format: "%.1f", r)) }
                        }
                    }.font(.system(size: 15, weight: .medium))
                    if let o = item.Overview, !o.isEmpty {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(o).lineLimit(moreText ? nil : 2).frame(maxWidth: 440, alignment: .leading)
                            if o.count > 110 {
                                Button(moreText ? "LESS" : "MORE") { withAnimation { moreText.toggle() } }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.white.opacity(0.18)))
                            }
                        }.font(.system(size: 15)).foregroundColor(.white.opacity(0.85))
                    }
                    HStack(spacing: 8) {
                        if let y = item.ProductionYear { Text(item.isSeries ? item.yearText : String(y)) }
                        if let t = full?.RunTimeTicks, t > 0 { Text("· " + runtimeText(t)) }
                        if let t = full?.RunTimeTicks, t > 0, !simple { Text("· Ends at " + endsAtText(t)) }
                        ForEach(badges, id: \.self) { badge($0) }
                    }.font(.system(size: 14)).foregroundColor(.white.opacity(0.85))
                    buttons.padding(.top, 8)
                }
                Spacer(minLength: 30)
                VStack(alignment: .leading, spacing: 2) {
                    if !starring.isEmpty {
                        (Text("Starring ").foregroundColor(.white.opacity(0.55)) + Text(starring.joined(separator: ", ")))
                    }
                    if !directors.isEmpty {
                        (Text("Director ").foregroundColor(.white.opacity(0.55)) + Text(directors.joined(separator: ", ")))
                    }
                }
                .font(.system(size: 14)).frame(maxWidth: 280, alignment: .leading).padding(.bottom, 8)
            }
            .padding(.horizontal, 52).padding(.bottom, 30)
        }
        .frame(height: 600)
        .clipped()
        .foregroundColor(.white)
    }

    /// Version, audio, subtitle and quality pickers under the header (movies and episodes).
    @ViewBuilder var pickers: some View {
        if !simple {
            VStack(alignment: .leading, spacing: 8) {
                if let tag = full?.Taglines?.first { Text(tag).font(.headline) }
                streamsRow
            }.padding(.horizontal, 52)
        }
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
                Text(o).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary))
            }
            if let g = full?.Genres?.first { Text(g) }
            if let t = full?.RunTimeTicks, !simple { Text("Ends at " + endsAtText(t)) }
        }.font(.subheadline).foregroundColor(.secondary)
    }

    /// Wraps onto more lines when the window is narrow, so long version names can't widen the page.
    var streamsRow: some View {
        FlowLayout(hSpacing: 20, vSpacing: 10) {
            if sources.count > 1 {
                HStack(spacing: 6) {
                    Text("Version").foregroundColor(.secondary)
                    Picker("", selection: $srcIdx) {
                        ForEach(sources.indices, id: \.self) { Text(sources[$0].Name ?? sources[$0].Path ?? "Version \($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: 320)   // long file names are cut with "…"
                }
            }
            if let v = streams("Video").first {
                HStack(spacing: 6) { Text("Video").foregroundColor(.secondary); Text(v.DisplayTitle ?? "") }
            }
            if !streams("Audio").isEmpty {
                labeled("Audio") {
                    Picker("", selection: $audioIdx) {
                        ForEach(streams("Audio")) { Text($0.DisplayTitle ?? "Track \($0.Index)").tag($0.Index) }
                    }
                }
            }
            labeled("Subtitles") {
                Picker("", selection: $subIdx) {
                    Text("Off").tag(-1)
                    ForEach(streams("Subtitle")) { Text($0.DisplayTitle ?? "Track \($0.Index)").tag($0.Index) }
                }
            }
            labeled("Quality") {
                Picker("", selection: $quality) {
                    Text("Original").tag(0)
                    Text("1080p · 8 Mbps").tag(8_000_000)
                    Text("720p · 4 Mbps").tag(4_000_000)
                    Text("480p · 1.5 Mbps").tag(1_500_000)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundColor(.secondary)
            content().pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }

    var buttons: some View {
        let played = emby.isPlayed(item)
        let fav = emby.isFav(item)
        return HStack(spacing: 12) {
            Button { playNow() } label: {
                Label(playLabel, systemImage: "play.fill").font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 34).frame(height: 46)
                    .background(Capsule().fill(.white)).foregroundColor(.black)
            }.buttonStyle(.plain)
            if let t = playTarget, emby.resumeAt(t) > 0 {
                glassCircle("arrow.counterclockwise", help: "Start Over") { playNow(from: 0) }
            }
            glassCircle(fav ? "checkmark" : "plus", help: fav ? "Remove from Favorites" : "Add to Favorites") {
                Task { await emby.setFav(item.id, !fav) }
            }
            glassCircle(played ? "eye.slash" : "eye", help: played ? "Mark as unwatched" : "Mark as watched") {
                Task { await emby.setPlayed(item.id, !played) }
            }
            if let u = SafeLink.url(full?.RemoteTrailers?.first?.Url) {
                glassCircle("film", help: "Trailer") { NSWorkspace.shared.open(u) }
            }
        }
    }

    func glassCircle(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(help)
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
    var seasonEpisodes: [Item] { kids.filter { ($0.ParentIndexNumber ?? 0) == currentSeason } }

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
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(selected ? 1 : 0.85), lineWidth: selected ? 3 : 1))
                .shadow(radius: 6)
                .hoverLift()
                Text(title).font(.body).foregroundColor(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var seasonRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons").font(.system(size: 22, weight: .bold)).padding(.horizontal, 52)
            ArrowScrollRow(ids: seasonNumbers, itemWidth: 170, inset: 52) { n in seasonPoster(n) }
        }
    }

    var episodesHeader: some View {
        let multi: Bool = seasonNumbers.count > 1
        let heading: String = multi ? seasonTitle(currentSeason) : "Episodes"
        return HStack(spacing: 16) {
            if multi {
                Menu {
                    ForEach(seasonNumbers, id: \.self) { n in Button(seasonTitle(n)) { season = n } }
                } label: {
                    HStack(spacing: 6) {
                        Text(heading).font(.system(size: 22, weight: .bold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                    }
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            } else {
                Text(heading).font(.system(size: 22, weight: .bold))
            }
            if canFilterWatched {
                Button(showAllEps ? "Hide watched" : "Show all") { showAllEps.toggle() }
                    .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(.tint)
            }
            Spacer()
            episodeLayoutToggle
            if !epLangs.isEmpty {
                Text("Subtitles").foregroundColor(.secondary)
                Picker("", selection: $epSubLang) {
                    Text(defaultSubLabel).tag("")
                    if subAlwaysOn { Text("Off").tag("off") }
                    ForEach(epLangs, id: \.code) { l in Text(l.name).tag(l.code) }
                }.labelsHidden().fixedSize()
            }
        }.padding(.horizontal, 52).padding(.top, 10)
    }

    /// Netflix-style episode row: big number, clean 16:9 still with progress, title + length, summary.
    func episodeRow(_ ep: Item) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        return Button { playEpisode(ep) } label: {
            HStack(alignment: .center, spacing: 18) {
                Text("\(ep.IndexNumber ?? 0)").font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.secondary).frame(width: 40)
                CachedImage(url: emby.image(ep.id, width: 480, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color(white: 0.15) }
                .frame(width: 220, height: 124).clipped()
                .overlay(alignment: .bottomTrailing) {
                    if pct > 0, pct < 100, !played { ProgressRing(progress: pct / 100).padding(8) }
                }
                .cornerRadius(6)
                .thinBorder(6)
                .hoverLift(play: 36)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ep.Name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        if played { Image(systemName: "checkmark.circle.fill").foregroundColor(.white.opacity(0.7)) }
                        Spacer()
                        if let t = ep.RunTimeTicks, t > 0 { Text(runtimeText(t)).foregroundColor(.secondary) }
                    }
                    if showEpDesc { Text(ep.Overview ?? "").lineLimit(3).font(.callout).foregroundColor(.secondary) }
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 52)
        .contextMenu {
            Button("Play from Beginning") { playEpisode(ep, from: 0) }
            Button(played ? "Mark as unwatched" : "Mark as watched") {
                Task { await emby.setPlayed(ep.id, !played) }
            }
        }
    }

    var episodesList: some View {
        let eps: [Item] = shownEpisodes
        return VStack(alignment: .leading, spacing: 12) {
            // Row view picks the season from the "Season 7" menu; grid and list also show the season posters
            if seasonNumbers.count > 1 && epLayout != "row" { seasonRow }
            // Extra space below the header, and the header kept in front: a hovered episode card grows a little
            // (hover lift) and could otherwise cover the view buttons and swallow their clicks
            episodesHeader.padding(.bottom, 14).zIndex(1)
            if epLayout == "row" {
                ArrowScrollRow(ids: eps.map { $0.id }, itemWidth: 360, spacing: 22, inset: 52) { id in
                    if let ep = eps.first(where: { $0.id == id }) { episodeCard(ep) }
                }
            } else if epLayout == "grid" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 22) {
                    ForEach(eps) { ep in episodeCard(ep, fill: true) }
                }.padding(.horizontal, 52)
            } else {
                ForEach(eps) { ep in episodeRow(ep) }
            }
        }
    }

    var episodeLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { epLayout = m.0 } label: {
                    Image(systemName: m.1).font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 28)
                        .background(Capsule().fill(epLayout == m.0 ? Color.white.opacity(0.22) : Color.clear))
                        .foregroundColor(epLayout == m.0 ? .white : .secondary)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).help(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 36).glassCapsule()
    }


    /// Apple TV episode card: still with "EPISODE 1", the title, summary and "▶ 59m" over a dark fade.
    /// `fill`: the card fills its grid column (same shape as the 360-wide card in the row) instead of a fixed width.
    func episodeCard(_ ep: Item, fill: Bool = false) -> some View {
        let played: Bool = emby.isPlayed(ep)
        let pct: Double = ep.UserData?.PlayedPercentage ?? 0
        let hasProgress: Bool = pct > 0 && pct < 100 && !played
        let height: CGFloat = showEpDesc ? 330 : 203
        return Button { playEpisode(ep) } label: {
            Group {
                if fill {
                    Color.clear.frame(minWidth: 0, maxWidth: .infinity).aspectRatio(360 / height, contentMode: .fit)
                        .overlay { episodeStill(ep) }
                } else {
                    episodeStill(ep).frame(width: 360, height: height)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EPISODE \(ep.IndexNumber ?? 0)").font(.system(size: 12, weight: .medium)).opacity(0.7)
                    Text(ep.Name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if showEpDesc {
                        Text(ep.Overview ?? "").font(.system(size: 13)).opacity(0.8).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: played ? "checkmark" : "play.fill").font(.system(size: 11))
                        if hasProgress {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.35))
                                Capsule().fill(Color.white).frame(width: 34 * pct / 100)
                            }.frame(width: 34, height: 4)
                        }
                        if let t = ep.RunTimeTicks, t > 0 {
                            let left = hasProgress ? max(0, t - (ep.UserData?.PlaybackPositionTicks ?? 0)) : t
                            Text(runtimeText(left) + (hasProgress ? " left" : "")).font(.system(size: 13, weight: .medium))
                        }
                    }.padding(.top, 4)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.top, 70).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .black.opacity(0.75), location: 0.45),
                                                   .init(color: .black.opacity(0.9), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .thinBorder(12)
            .hoverLift(play: 44)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play from Beginning") { playEpisode(ep, from: 0) }
            Button(played ? "Mark as unwatched" : "Mark as watched") {
                Task { await emby.setPlayed(ep.id, !played) }
            }
        }
    }

    func episodeStill(_ ep: Item) -> some View {
        CachedImage(url: emby.image(ep.id, width: 720, plain: true)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color(white: 0.15) }
    }

    var boxGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 18) {
            ForEach(kids) { PosterCard(item: $0) }
        }.padding(.horizontal, 52)
    }

    @ViewBuilder var castSection: some View {
        let people = Array((full?.People ?? []).prefix(30))
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & Crew").font(.system(size: 22, weight: .bold)).padding(.horizontal, 52)
                ArrowScrollRow(ids: Array(people.indices), itemWidth: 104, inset: 52) { i in
                    NavigationLink(value: PersonRef(id: people[i].Id, name: people[i].Name)) { CastTile(p: people[i]) }
                        .buttonStyle(.plain).help("Show everything with \(people[i].Name)")
                }
            }
        }
    }

    func mediaInfo(_ s: MSource, _ f: Full) -> String {
        var info = (s.Container ?? "").uppercased()
        if let z = s.Size { info += "  " + ByteCountFormatter.string(fromByteCount: z, countStyle: .file) }
        if let a = parseDate(f.DateCreated) { info += "  Added " + a.formatted(date: .abbreviated, time: .shortened) }
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
                Text("About").font(.title3.bold())
                if let d = parseDate(f.UserData?.LastPlayedDate) {
                    aboutRow("Date Last Played", d.formatted(date: .abbreviated, time: .shortened))
                }
                if let g = f.Genres, !g.isEmpty { aboutRow("Genres", g.joined(separator: ", ")) }
                if let s = f.Studios, !s.isEmpty { aboutRow("Studios", s.map { $0.Name }.joined(separator: ", ")) }
                if let links = f.ExternalUrls, !links.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Links").bold()
                        HStack(spacing: 10) {
                            ForEach(links.indices, id: \.self) { i in
                                if let n = links[i].Name, let u = SafeLink.url(links[i].Url) { Link(n, destination: u) }
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
            }.padding(.horizontal, 52).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Included In": the collections this title belongs to; a click opens the collection's page.
    @ViewBuilder var includedInSection: some View {
        if showIncludedIn && !includedIn.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Included In").font(.system(size: 22, weight: .bold)).padding(.horizontal, 52)
                ArrowScrollRow(ids: Array(includedIn.indices), itemWidth: 170, spacing: 14, inset: 52) { PosterCard(item: includedIn[$0]) }
            }
        }
    }

    @ViewBuilder var similarSection: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("More Like This").font(.system(size: 22, weight: .bold))
                    Spacer()
                    similarLayoutToggle
                }.padding(.horizontal, 52)
                // Extra space below, and the header kept in front: a hovered poster grows a little (hover lift)
                // and could otherwise cover the view buttons and swallow their clicks
                .padding(.bottom, 14).zIndex(1)
                if similarLayout == "grid" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(similar) { PosterCard(item: $0) }
                    }.padding(.horizontal, 52)
                } else if similarLayout == "list" {
                    LazyVStack(spacing: 6) { ForEach(similar) { ListRow(item: $0) } }.padding(.horizontal, 52)
                } else {
                    ArrowScrollRow(ids: Array(similar.indices), itemWidth: 170, spacing: 14, inset: 52) { PosterCard(item: similar[$0]) }
                }
            }
        }
    }

    var similarLayoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("row", "rectangle.split.3x1"), ("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { similarLayout = m.0 } label: {
                    Image(systemName: m.1).font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 28)
                        .background(Capsule().fill(similarLayout == m.0 ? Color.white.opacity(0.22) : Color.clear))
                        .foregroundColor(similarLayout == m.0 ? .white : .secondary)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).help(m.0 == "row" ? "Row view" : m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 36).glassCapsule()
    }
}

// MARK: - Media keys and Control Center

/// Play/pause and skip from the keyboard's media keys, AirPods and Control Center, with the title and
/// progress shown in the Mac's Now Playing widget.
@MainActor
enum RemoteControls {
    static func attach(_ m: PlayerModel, skip: Double) {
        let c = MPRemoteCommandCenter.shared()
        detach()
        c.togglePlayPauseCommand.addTarget { _ in m.togglePlay(); return .success }
        c.playCommand.addTarget { _ in if !m.playing { m.togglePlay() }; return .success }
        c.pauseCommand.addTarget { _ in if m.playing { m.togglePlay() }; return .success }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        c.skipForwardCommand.addTarget { _ in m.skip(skip); return .success }
        c.skipBackwardCommand.addTarget { _ in m.skip(-skip); return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            m.seek(to: e.positionTime); return .success
        }
    }

    static func detach() {
        let c = MPRemoteCommandCenter.shared()
        for cmd in [c.togglePlayPauseCommand, c.playCommand, c.pauseCommand, c.skipForwardCommand,
                    c.skipBackwardCommand, c.changePlaybackPositionCommand] as [MPRemoteCommand] {
            cmd.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    static func update(_ item: Item, _ m: PlayerModel) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.isEpisode ? item.Name : item.heroTitle,
            MPMediaItemPropertyPlaybackDuration: m.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: m.time,
            MPNowPlayingInfoPropertyPlaybackRate: m.playing ? Double(m.speed) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if item.isEpisode {
            info[MPMediaItemPropertyArtist] = "\(item.heroTitle) · S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0)"
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = m.playing ? .playing : .paused
    }
}

// MARK: - Player window

/// Contents of the separate player window. Closing the window (red button) stops playback.
struct PlayerWindow: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let req = emby.playing { PlayerView(req: req).id(req.id) }
        }
        .ignoresSafeArea()
        .onAppear {
            if emby.playing == nil || !UserDefaults.standard.bool(forKey: "separatePlayer") { dismiss(); return }
            // Let the green button and F make the player window full screen
            DispatchQueue.main.async {
                NSApp.windows.first { $0.title == "Player" }?.collectionBehavior.insert(.fullScreenPrimary)
            }
        }   // never show an empty player (e.g. restored at launch)
        .onDisappear { if emby.playing != nil { emby.playing = nil } }
    }
}

// MARK: - Player

struct PlayerView: View {
    @EnvironmentObject var emby: Emby
    @StateObject private var model = PlayerModel()
    let req: PlayRequest

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
    @State private var escMonitor: Any?
    @State private var playerWin = WeakWindow()   // the window this player is in

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
    @State private var isFullScreen = false
    // Remembered across episodes (each episode gets a fresh PlayerView), so closing the player still leaves full screen
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

    var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Height of the window's title bar while windowed (0 in full screen, where there is none).
    /// The player has its own window with no title bar, so the video fills it all (the window buttons float on top).
    var titleBarHeight: CGFloat {
        guard !separate, !isFullScreen, let w = window, !w.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }
    var separate: Bool { UserDefaults.standard.bool(forKey: "separatePlayer") }
    /// Room for the floating window buttons above the top controls (separate window only, none in full screen).
    var windowButtonsGap: CGFloat { separate && !isFullScreen ? 22 : 0 }
    /// Color of the strip under the title bar. The system draws the bar's own gray (about 93 % opaque) over it,
    /// and the result is the same gray on both sides only when this strip is (44, 45, 45).
    static let titleBarGray = Color(red: 44 / 255, green: 45 / 255, blue: 45 / 255)

    /// The Back pill that used to be drawn inside the player (top left). Off now; see `titleBarBack`.
    static let inPlayerBackPill = false
    /// The Back pill in the title bar of the windowed player. Off now: Esc leaves the player.
    static let titleBarBackPill = false

    /// Windowed player: Back pill up in the title bar, where the app's own Back pill sits on a page
    /// (right after the window buttons).
    /// Not drawn in full screen, where Esc leaves the player.
    var titleBarBack: some View {
        let h = titleBarHeight
        let x: CGFloat = 80
        let visible = h > 0 && (showUI || panel != nil)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                BackPill(compact: true) { back() }.help("Back (Esc)").padding(.leading, x)
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
        guard let w = window else { return }
        w.collectionBehavior.insert(.fullScreenPrimary)   // the separate player window isn't full-screen capable by default
        let on = w.styleMask.contains(.fullScreen)
        if !on { enteredFullScreen = true }
        w.toggleFullScreen(nil)
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
        let done = model.watchedEnough
        model.stop()
        emby.playing = nil
        if done { Task { await emby.setPlayed(req.item.id, true) } }
    }

    /// Plays a neighbouring episode, keeping the current subtitle language.
    func play(_ ep: Item) {
        guard !switching else { return }
        switching = true
        let lang = model.subStreams.first { $0.Index == model.sub }.map { DetailView.langName($0) }
        Task {
            let f = await emby.full(ep.id)
            let src = f?.MediaSources?.first
            var pick: Int?
            if let lang {
                let subs = (src?.MediaStreams ?? []).filter { $0.`Type` == "Subtitle" && DetailView.langName($0) == lang }
                let text = ["srt", "subrip", "vtt", "ass", "ssa"]
                pick = (subs.first { text.contains(($0.Codec ?? "").lowercased()) } ?? subs.first)?.Index
            }
            if model.watchedEnough { await emby.setPlayed(item.id, true) }
            model.stop()
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
                if model.pipActive { pipPlaceholder }

                subtitleLayer(geo.size).animation(.easeOut(duration: 0.2), value: showUI)

                if showUI || panel != nil {
                    LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea().allowsHitTesting(false)
                    centerControls.transition(.opacity)
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        bottomBar
                    }
                    .padding(.top, titleBarHeight)
                    .transition(.opacity)
                }

                if !model.error.isEmpty {
                    VStack(spacing: 12) {
                        Text(model.error).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button("Retry with transcoding") { Task { await model.retryTranscoded(emby) } }
                    }
                }

                if showInfo { infoOverlay }
                cornerCards
                panelLayer
                // Title bar strip, above every layer (the controls' dark gradient used to darken it)
                VStack(spacing: 0) {
                    PlayerView.titleBarGray.frame(height: titleBarHeight)
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
            if showUpNext, let n = nextEp { play(n) } else { model.togglePlay() }
            poke(); return .handled
        }
        .onKeyPress(.return) {
            if showUpNext, let n = nextEp { play(n); return .handled }
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
        .onChange(of: showUpNext) { _, on in if on { focused = true } }
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
            guard playerWin.owns(n.object) else { return }
            isFullScreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            guard playerWin.owns(n.object) else { return }
            isFullScreen = false
            // Take the keyboard back after leaving full screen, so Esc / Space / F keep working
            (n.object as? NSWindow)?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onKeyPress(.leftArrow) { model.skip(-Double(skipSecs)); poke(); return .handled }
        .onKeyPress(.rightArrow) { model.skip(Double(skipSecs)); poke(); return .handled }
        // Esc: close a panel, else leave full screen (video keeps playing), else close the player.
        // Caught at the app level: AppKit sometimes swallows Esc before SwiftUI's key handlers see it
        // (after full screen, and in the separate player window). Only in the player's own window: Esc in the
        // main window must not stop a video playing in the separate one.
        .background(WindowReader { playerWin.window = $0 })
        .onAppear {
            let win = playerWin
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                guard ev.keyCode == 53, let w = win.window, ev.window === w,
                      w.attachedSheet == nil, w.sheetParent == nil else { return ev }
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
        // Media keys / Control Center
        .onAppear { RemoteControls.attach(model, skip: Double(skipSecs)) }
        .onChange(of: model.playing) { RemoteControls.update(item, model) }
        .onChange(of: model.duration) { RemoteControls.update(item, model) }
        .onChange(of: Int(model.time / 10)) { RemoteControls.update(item, model) }
        // Closing the player window (red button or ⌘W) stops playback, like Esc
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
            if (n.object as? NSWindow)?.title == "Player" { close() }
        }
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
                    Text("Loading subtitles…").font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(.bottom, subLift(size))
            }.frame(maxWidth: .infinity).allowsHitTesting(false)
        }
        if !model.caption.isEmpty {
            let fs = max(14, size.height * (Self.sizes.first { $0.0 == subTextSize }?.2 ?? 0.045))
            let color = Self.colors.first { $0.0 == subColor }?.2 ?? .white
            let shade: Color = subColor == "black" ? .white : .black
            VStack {
                Spacer()
                Text(model.caption)
                    .font(.system(size: fs, weight: .medium))
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
        HStack(alignment: .top, spacing: 16) {
            if Self.inPlayerBackPill { BackPill { back() }.help(isFullScreen ? "Exit full screen (Esc)" : "Back (Esc)") }
            // Left glass group: picture in picture, full screen, info (Apple TV style)
            HStack(spacing: 6) {
                if model.pipSupported {
                    glassIcon(model.pipActive ? "pip.exit" : "pip.enter", on: model.pipActive) { model.togglePiP() }
                        .help("Picture in picture (P)")
                }
                glassIcon(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    toggleFullScreen()
                }.help(isFullScreen ? "Exit full screen (F)" : "Full screen (F)")
                glassIcon("info.circle", on: showInfo) { showInfo.toggle() }.help("Playback info (I)")
            }
            .padding(.horizontal, 8).frame(height: 50).background(.ultraThinMaterial, in: Capsule())
            Spacer()
            // Right glass group: volume
            HStack(spacing: 12) {
                Slider(value: $model.volume, in: 0...1).frame(width: 170).tint(.white).controlSize(.small)
                Button { model.volume = model.volume > 0 ? 0 : 1 } label: {
                    Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 17))
                        .frame(width: 26)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).frame(height: 50).background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 20).padding(.top, 16 + windowButtonsGap)
        .environment(\.colorScheme, .dark)
    }

    /// Small icon button inside a glass capsule.
    func glassIcon(_ name: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundColor(on ? accent : .white)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Apple TV style: back 10, play / pause and forward 10 as big glass circles in the middle of the picture.
    var centerControls: some View {
        HStack(spacing: 44) {
            centerCircle("gobackward.\(skipSecs)", size: 30, box: 92) { model.skip(-Double(skipSecs)) }
                .help("Back \(skipSecs) seconds")
            centerCircle(model.playing ? "pause.fill" : "play.fill", size: 50, box: 140) { model.togglePlay() }
                .help(model.playing ? "Pause (Space)" : "Play (Space)")
            centerCircle("goforward.\(skipSecs)", size: 30, box: 92) { model.skip(Double(skipSecs)) }
                .help("Forward \(skipSecs) seconds")
        }
        .environment(\.colorScheme, .dark)
    }

    func centerCircle(_ name: String, size: CGFloat, box: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .frame(width: box, height: box)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(.plain)
    }

    // MARK: Bottom bar

    var episodeLine: String? {
        guard item.isEpisode else { return nil }
        return "S\(item.ParentIndexNumber ?? 0):E\(item.IndexNumber ?? 0) - \(item.Name)"
    }

    var bottomBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                // Episode name small above the show's name, as on Apple TV
                VStack(alignment: .leading, spacing: 4) {
                    if item.isEpisode {
                        Text("S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0) · \(item.Name)")
                            .font(.system(size: 17, weight: .semibold)).opacity(0.85)
                    }
                    Text(item.heroTitle).font(.system(size: 34, weight: .bold)).lineLimit(1)
                }
                Spacer()
                // Right glass group: previous / next episode, episodes, subtitles, quality, chapters, all options
                HStack(spacing: 6) {
                    if item.isEpisode && episodes.count > 1 {
                        glassIcon("backward.end.fill") { if let p = prevEp { play(p) } else { model.seek(to: 0) } }
                            .help("Previous")
                        glassIcon("forward.end.fill") { if let n = nextEp { play(n) } }
                            .opacity(nextEp == nil ? 0.35 : 1).disabled(nextEp == nil).help("Next")
                        glassIcon("rectangle.stack", on: panel == .episodes) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                if panel != .episodes { pickerSeason = item.ParentIndexNumber ?? 1 }
                                panel = panel == .episodes ? nil : .episodes
                            }
                        }.help("Episodes (E)")
                    }
                    if !model.subStreams.isEmpty { subtitleMenu.padding(.horizontal, 5) }
                    qualityMenu.padding(.horizontal, 5)
                    if !model.chapterList.isEmpty {
                        glassIcon("list.bullet.rectangle", on: panel == .chapters) {
                            withAnimation(.easeOut(duration: 0.2)) { panel = panel == .chapters ? nil : .chapters }
                        }.help("Chapters (C)")
                    }
                    glassIcon("waveform", on: panel != nil && panel != .episodes && panel != .chapters) {
                        withAnimation(.easeOut(duration: 0.2)) { panel = panel == nil ? .subtitles : nil }
                    }.help("Subtitles, audio, quality & speed")
                }
                .padding(.horizontal, 8).frame(height: 50).background(.ultraThinMaterial, in: Capsule())
            }

            // Scrubber in a glass capsule: elapsed time, bar, time left
            HStack(spacing: 14) {
                Text(fmt(scrubbing ? scrub : model.time)).frame(minWidth: 52, alignment: .leading)
                Slider(value: Binding(get: { scrubbing ? scrub : model.time },
                                      set: { scrub = $0 }),
                       in: 0...max(model.duration, 1)) { editing in
                    if editing { scrub = model.time; scrubbing = true }
                    else { model.seek(to: scrub); scrubbing = false }
                }
                .tint(.white).controlSize(.small)
                .background(GeometryReader { g in
                    Color.clear.onAppear { sliderW = g.size.width }.onChange(of: g.size.width) { _, w in sliderW = w }
                })
                .onContinuousHover { ph in
                    if case .active(let p) = ph { hoverX = p.x } else { hoverX = nil }
                }
                .overlay(alignment: .bottomLeading) { scrubPreview }
                Text("-" + fmt(max(0, model.duration - (scrubbing ? scrub : model.time))))
                    .frame(minWidth: 60, alignment: .trailing)
                    .help("Ends at \(endClock)")
            }
            .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 22).frame(height: 50)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .environment(\.colorScheme, .dark)
    }

    func iconButton(_ name: String, size: CGFloat = 22, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).font(.system(size: size, weight: .medium))
                .frame(width: size + 12, height: size + 12)
                .foregroundColor(on ? accent : .white)
                .background(Circle().fill(Color.white.opacity(on ? 0.12 : 0)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Panels

    @ViewBuilder var panelLayer: some View {
        switch panel {
        case .subtitles:
            HStack { Spacer(); mediaPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .appearance:
            HStack { Spacer(); appearancePanel }.transition(.move(edge: .trailing))
        case .episodes:
            HStack { Spacer(); episodesPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .chapters:
            HStack { Spacer(); chaptersPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case nil: EmptyView()
        }
    }

    func row(_ icon: String, _ title: String, sub: String? = nil, checked: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16))
                    if let sub { Text(sub).font(.system(size: 13)).foregroundColor(.secondary) }
                }
                Spacer()
                if checked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)) }
            }
            .foregroundColor(checked ? accent : .white)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle())
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 4)
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
                    Image(systemName: "timer").font(.system(size: 18)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Subtitle Offset").font(.system(size: 16))
                        Text("\(model.subOffset) ms").font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { model.subOffset -= 100 } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        .help("Show subtitles 100 ms earlier")
                    Button { model.subOffset = 0 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain)
                        .opacity(model.subOffset == 0 ? 0.3 : 1).help("Reset offset")
                    Button { model.subOffset += 100 } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain)
                        .help("Show subtitles 100 ms later")
                }
                .font(.system(size: 18))
                .padding(.horizontal, 22).padding(.vertical, 9)
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
                            Text(r == 1 ? "1×" : String(format: "%g×", r)).font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .foregroundColor(on ? .black : .white)
                                .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent : Color.white.opacity(0.1)))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(r == 1 ? "Normal speed" : "\(String(format: "%g", r))× speed")
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 6)
            }
            .padding(.vertical, 12)
        }
        .frame(width: 340)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color(white: 0.15).opacity(0.85))
        .cornerRadius(14)
        .environment(\.colorScheme, .dark)
        .onTapGesture {}   // keep taps inside the panel
    }

    func dropdown<T: Hashable>(_ label: String, _ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 15)).foregroundColor(.white.opacity(0.85))
            Menu {
                ForEach(opts, id: \.0) { o in
                    Button { sel.wrappedValue = o.0 } label: {
                        if sel.wrappedValue == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                    }
                }
            } label: {
                HStack {
                    Text(opts.first { $0.0 == sel.wrappedValue }?.1 ?? "").font(.system(size: 16))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.white.opacity(0.1)).cornerRadius(6)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
    }

    var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                Button { withAnimation { panel = .subtitles } } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)) }
                    .buttonStyle(.plain)
                Text("Subtitle Appearance").font(.system(size: 18, weight: .bold))
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dropdown("Text size", $subTextSize, Self.sizes.map { ($0.0, $0.1) })
                    dropdown("Text color", $subColor, Self.colors.map { ($0.0, $0.1) })
                    dropdown("Drop shadow", $subShadow, Self.shadows)
                    dropdown("Background color", $subBg, Self.bgs.map { ($0.0, $0.1) })
                    Text("Subtitle Position").font(.system(size: 20, weight: .bold)).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        dropdown("Bottom Edge Position", $subBottom, [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") })
                        Text("Set the vertical position of the subtitles relative to the bottom of the screen.")
                            .font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    Button("Reset to Default") {
                        subTextSize = "normal"; subColor = "white"; subShadow = "drop"; subBg = "none"; subBottom = 10
                    }.padding(.top, 6)
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.16).opacity(0.97))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }
}

extension PlayerView {
    // MARK: Extra controls

    static let qualities: [(Int, String)] = [(0, "Original"), (8_000_000, "1080p · 8 Mbps"),
                                             (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")]

    /// Quick dropdown: subtitle language.
    var subtitleMenu: some View {
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
            menuIcon("captions.bubble", on: model.sub != nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Subtitles")
    }

    /// Quick dropdown: video quality.
    var qualityMenu: some View {
        Menu {
            ForEach(Self.qualities, id: \.0) { q in
                Button { Task { await model.setQuality(emby, q.0) } } label: {
                    if model.quality == q.0 { Label(q.1, systemImage: "checkmark") } else { Text(q.1) }
                }
            }
        } label: {
            menuIcon("dial.medium", on: model.quality != 0)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Video quality")
    }

    func menuIcon(_ name: String, on: Bool) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundColor(on ? accent : .white)
            .contentShape(Rectangle())
    }

    var extraButtons: some View {
        HStack(spacing: 22) {
            if item.isEpisode && episodes.count > 1 {
                iconButton("rectangle.stack", size: 18, on: panel == .episodes) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if panel != .episodes { pickerSeason = item.ParentIndexNumber ?? 1 }
                        panel = panel == .episodes ? nil : .episodes
                    }
                }.help("Episodes (E)")
            }
            if !model.subStreams.isEmpty { subtitleMenu }
            qualityMenu
            if !model.chapterList.isEmpty {
                iconButton("list.bullet.rectangle", size: 18, on: panel == .chapters) {
                    withAnimation(.easeOut(duration: 0.2)) { panel = panel == .chapters ? nil : .chapters }
                }.help("Chapters (C)")
            }
            iconButton("info.circle", size: 18, on: showInfo) { showInfo.toggle() }.help("Playback info (I)")
            if model.pipSupported {
                iconButton(model.pipActive ? "pip.exit" : "pip.enter", size: 18, on: model.pipActive) { model.togglePiP() }
                    .help("Picture in picture (P)")
            }
        }
    }

    var pipPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip").font(.system(size: 44))
            Text("Playing in picture in picture").font(.system(size: 16, weight: .medium))
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
                        .frame(width: w).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6), lineWidth: 1))
                }
                Text(fmt(t)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
            }
            .frame(width: w)
            .offset(x: min(max(0, x - w / 2), max(0, sliderW - w)), y: -26)
            .allowsHitTesting(false)
        }
    }

    // MARK: Intro / up next (bottom-right corner)

    var showUpNext: Bool {
        guard item.isEpisode, nextEp != nil, !upNextCancelled, model.duration > 120 else { return false }
        return model.time >= model.duration - 30 && model.time < model.duration - 0.5
    }

    /// Whole seconds until the episode ends.
    var secsLeft: Int { max(0, Int((model.duration - model.time).rounded(.up))) }

    var cornerCards: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()
            if model.skippedIntro {
                HStack(spacing: 12) {
                    Image(systemName: "forward.fill")
                    Text("Intro skipped").font(.system(size: 15, weight: .semibold))
                    Button("Watch intro") { model.watchIntro() }.buttonStyle(.plain)
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(accent)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .transition(.opacity)
            } else if model.inIntro {
                Button { model.skipIntro() } label: {
                    Text("Skip Intro").font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                }.buttonStyle(.plain)
            }
            if showUpNext, let n = nextEp { upNextCard(n) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 34)
        .padding(.bottom, showUI ? 200 : 40)
        .animation(.easeOut(duration: 0.2), value: model.skippedIntro)
    }

    func upNextCard(_ n: Item) -> some View {
        HStack(spacing: 14) {
            CachedImage(url: emby.image(n.Id, "Primary", width: 400, plain: true)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.white.opacity(0.1) }
            .frame(width: 160, height: 90).clipped().cornerRadius(6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Up next").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                Text("S\(n.ParentIndexNumber ?? 0):E\(n.IndexNumber ?? 0) · \(n.Name)")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 10) {
                    Button { play(n) } label: {
                        Text("Play now").font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black).padding(.horizontal, 14).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent, lineWidth: 3))
                    }.buttonStyle(.plain)
                    Button { upNextCancelled = true } label: {
                        Text("Cancel").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                    }.buttonStyle(.plain)
                }
                if autoNext {
                    Text("Next starts in \(secsLeft)s")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.8)))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    // MARK: Playback info

    var infoOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Playback info").font(.system(size: 13, weight: .bold))
                    ForEach(Array(infoLines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(l.0).foregroundColor(.white.opacity(0.6)).frame(width: 120, alignment: .leading)
                            Text(l.1).frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: 12).monospacedDigit())
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 70).padding(.leading, 20)
        .allowsHitTesting(false)
    }

    // MARK: Episodes panel

    var episodesPanel: some View {
        let seasons = Array(Set(episodes.map { $0.ParentIndexNumber ?? 0 })).sorted()
        let list = episodes.filter { ($0.ParentIndexNumber ?? 0) == pickerSeason }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Episodes").font(.system(size: 18, weight: .bold))
                Spacer()
                if seasons.count > 1 {
                    Picker("", selection: $pickerSeason) {
                        ForEach(seasons, id: \.self) { n in Text(n == 0 ? "Specials" : "Season \(n)").tag(n) }
                    }.labelsHidden().fixedSize()
                }
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { ep in episodePickerRow(ep).id(ep.Id) }
                    }.padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo(item.Id, anchor: .center) }
            }
        }
        .frame(width: 400)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color(white: 0.15).opacity(0.85))
        .cornerRadius(14)
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    func episodePickerRow(_ ep: Item) -> some View {
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
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 18)).foregroundColor(.white)
                            .padding(6).background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if played && !current {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                            .foregroundColor(.white).shadow(radius: 2).padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ep.IndexNumber ?? 0). \(ep.Name)").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if let t = ep.RunTimeTicks, t > 0 {
                        Text(runtimeText(t)).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(current ? accent : .white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(current ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle())
    }

    // MARK: Chapters panel

    var chaptersPanel: some View {
        let list = model.chapterList
        let cur = list.lastIndex { $0.c.start <= model.time }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Chapters")
                ForEach(Array(list.enumerated()), id: \.offset) { k, e in
                    chapterRow(e.i, e.c, current: k == cur)
                }
            }.padding(.vertical, 12)
        }
        .frame(width: 380)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color(white: 0.15).opacity(0.85))
        .cornerRadius(14)
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    func chapterRow(_ i: Int, _ c: Chapter, current: Bool) -> some View {
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
                    Text(c.Name ?? "Chapter \(i + 1)").font(.system(size: 15)).lineLimit(2)
                    Text(fmt(c.start)).font(.system(size: 13).monospacedDigit()).foregroundColor(.secondary)
                }
                Spacer()
            }
            .foregroundColor(current ? accent : .white)
            .padding(.horizontal, 18).padding(.vertical, 7)
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle())
    }
}

struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.15 : 0))
    }
}

struct SubShadow: ViewModifier {
    let style: String
    let color: Color
    func body(content: Content) -> some View {
        switch style {
        case "drop":
            content.shadow(color: color.opacity(0.9), radius: 2, x: 1.5, y: 1.5).shadow(color: color.opacity(0.6), radius: 4)
        case "outline":
            content.shadow(color: color, radius: 0, x: 1, y: 1).shadow(color: color, radius: 0, x: -1, y: -1)
                .shadow(color: color, radius: 0, x: 1, y: -1).shadow(color: color, radius: 0, x: -1, y: 1)
        case "raised":
            content.shadow(color: color, radius: 0, x: 1, y: 2)
        default:
            content
        }
    }
}

/// AppKit video surface with no built-in controls; the SwiftUI overlay draws the UI.
/// (SwiftUI's VideoPlayer crashes on load on this macOS version.)
/// A plain AVPlayerLayer (picture-in-picture needs the layer). Clicks pass through to SwiftUI (click = play/pause).
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A window reference that doesn't keep the window alive.
final class WeakWindow {
    weak var window: NSWindow?
    /// Whether a notification's object is this window (false while the window isn't known yet).
    func owns(_ object: Any?) -> Bool { window != nil && (object as? NSWindow) === window }
}

/// Reports the window a view is in, when it's added to one (both themes' players use it to keep keys and
/// full-screen events to their own window).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { self.onWindow(w) }
        }
    }
}

struct AVPlayerViewRep: NSViewRepresentable {
    let player: AVPlayer
    var onLayer: (AVPlayerLayer) -> Void = { _ in }
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        let cb = onLayer, l = v.playerLayer
        DispatchQueue.main.async { cb(l) }
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
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


/// Holds an IOKit assertion that stops the screen saver and display sleep while any player is playing.
/// Each player is an "owner", so the old player closing can't release the assertion the next episode just took.
enum KeepAwake {
    private static var id: IOPMAssertionID = 0
    private static var owners = Set<ObjectIdentifier>()
    static func set(_ on: Bool, owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if on { owners.insert(key) } else { owners.remove(key) }
        if !owners.isEmpty, id == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Cove is playing a video" as CFString, &id)
        } else if owners.isEmpty, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

/// The poster hover effect: lift 6 % with a shadow, drawn above its neighbours.
struct HoverLift: ViewModifier {
    var hover: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.06 : 1)
            .shadow(radius: hover ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: hover)
            .zIndex(hover ? 1 : 0)
    }
}

/// HoverLift that tracks the pointer itself; optionally shows a play button on hover (as on Continue Watching).
struct SelfHoverLift: ViewModifier {
    var play: CGFloat = 0
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .overlay {
                if hover && play > 0 {
                    Image(systemName: "play.circle.fill").font(.system(size: play)).foregroundColor(.white)
                        .shadow(radius: 6)
                }
            }
            .modifier(HoverLift(hover: hover)).onHover { hover = $0 }
    }
}

extension View {
    /// `play`: size of the play button shown on hover (0 = none).
    func hoverLift(play: CGFloat = 0) -> some View { modifier(SelfHoverLift(play: play)) }
}

/// Netflix-style expanded card shown when resting on a poster: backdrop, details and quick actions.
struct HoverPreview: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    let close: () -> Void

    var facts: String {
        var f: [String] = []
        if let y = item.ProductionYear { f.append(String(y)) }
        if let t = item.RunTimeTicks, t > 0, !item.isSeries { f.append(runtimeText(t)) }
        if let r = item.CommunityRating { f.append(String(format: "★ %.1f", r)) }
        return f.joined(separator: "  ·  ")
    }

    var body: some View {
        let played = emby.isPlayed(item), fav = emby.isFav(item)
        VStack(alignment: .leading, spacing: 10) {
            CachedImage(url: emby.image(item.backdropId ?? item.Id, item.backdropId == nil ? "Primary" : "Backdrop", width: 640)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color(white: 0.15) }
            .frame(width: 320, height: 180).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(item.Name).font(.headline).lineLimit(2)
                if !facts.isEmpty { Text(facts).font(.caption).foregroundColor(.secondary) }
                if let g = item.Genres, !g.isEmpty {
                    Text(g.prefix(3).joined(separator: " • ")).font(.caption).foregroundColor(.secondary)
                }
                if let o = item.Overview, !o.isEmpty {
                    Text(o).font(.caption).lineLimit(3).foregroundColor(.white.opacity(0.85))
                }
                HStack(spacing: 10) {
                    Button { close(); Task { await emby.play(item) } } label: {
                        Label("Play", systemImage: "play.fill").font(.callout.weight(.bold))
                            .foregroundColor(.black).padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white))
                    }.buttonStyle(.plain)
                    circle(fav ? "heart.fill" : "heart", on: fav, help: fav ? "Remove from favorites" : "Add to favorites") {
                        Task { await emby.setFav(item.id, !fav) }
                    }
                    circle(played ? "checkmark.circle.fill" : "checkmark", on: played,
                           help: played ? "Mark as unwatched" : "Mark as watched") {
                        Task { await emby.setPlayed(item.id, !played) }
                    }
                }.padding(.top, 2)
            }.padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(width: 320)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
        // Clicking anywhere on the card (outside its buttons) opens this item's page
        .contentShape(Rectangle())
        .onTapGesture { close(); emby.openRequest = item }
    }

    func circle(_ icon: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1.5))
                .contentShape(Circle())
        }.buttonStyle(.plain).help(help)
    }
}

/// Lays children out left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 8

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var sz = v.sizeThatFits(.unspecified)
            if sz.width > width { sz = v.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + sz.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, sz))
            x += sz.width + hSpacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let r = rows(width, subviews)
        var h: CGFloat = 0, w: CGFloat = 0
        for row in r {
            var rowW: CGFloat = 0, rowH: CGFloat = 0
            for (_, sz) in row { rowW += sz.width; rowH = max(rowH, sz.height) }
            rowW += hSpacing * CGFloat(max(0, row.count - 1))
            w = max(w, rowW)
            h += rowH
        }
        h += vSpacing * CGFloat(max(0, r.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let h = row.map(\.1.height).max() ?? 0
            for (i, sz) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + hSpacing
            }
            y += h + vSpacing
        }
    }
}
