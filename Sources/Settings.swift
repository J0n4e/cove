import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// App settings: one window with a sidebar of sections.
/// Values live in UserDefaults (the same keys the rest of the app reads).
struct SettingsView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @AppStorage("accent") private var accentName = "red"
    var accent: Color { Theme.accent(accentName) }

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", home = "Home", libraries = "Libraries",
             subtitles = "Subtitles", playback = "Playback", servers = "Connect", trakt = "Trakt", about = "About"   // Shortcuts moved to Help → Keyboard shortcuts (owner)
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "paintpalette"
            case .home: return "house"
            case .libraries: return "square.grid.2x2"
            case .subtitles: return "captions.bubble"
            case .playback: return "play.rectangle"
            case .servers: return "link"
            case .trakt: return "chart.bar"
            case .about: return "info.circle"
            }
        }
    }
    @State private var section: Section = .general
    @ObservedObject private var trakt = Trakt.shared
    /// The Trakt tab shows only while Trakt is connected.
    var sections: [Section] { Section.allCases.filter { $0 != .trakt || trakt.isConnected } }

    var body: some View {
        VStack(spacing: 0) {
            // A row of glass icon tabs; the selected tab names the page, so no title above them
            HStack(spacing: Glass3DTokens.Space.xs) {
                ForEach(sections) { s in
                    Glass3DSettingsTab(title: s.rawValue, icon: s.icon, on: section == s) { section = s }
                }
            }.padding(.top, Glass3DTokens.Space.l).padding(.bottom, Glass3DTokens.Space.m)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case .general: GeneralSettings()
                    case .home: HomeSettings()
                    case .libraries: LibrariesSettings()
                    case .subtitles: SubtitleSettings()
                    case .playback: PlaybackSettings()
                    case .servers: ServerSettings()
                    case .trakt: TraktStatsSettings()
                    case .about: AboutSettings()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Glass3DTokens.Space.xxl).padding(.top, Glass3DTokens.Space.m).padding(.bottom, Glass3DTokens.Space.l)
            }
            .frame(maxHeight: .infinity)   // the scroll area runs to the window's bottom edge
        }
        // Disconnected while on the Trakt tab: go to Connect, where Trakt is set up again
        .onChange(of: trakt.isConnected) { _, on in if !on && section == .trakt { section = .servers } }
        .tint(accent)     // switches, menus and links inside Settings too
        // Room for the traffic lights in the transparent title bar
        .padding(.top, Glass3DTokens.Space.xl)
        // Fill the whole window; the background goes on last so it also covers the top padding and
        // every safe-area edge (it used to sit inside a fixed 640pt frame, leaving a grey strip at the bottom).
        // No opaque background: the content sits straight on the window's glass (GlassWindowContainer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The Settings window's content, with what the main window's scene injects (Background follows the setting live).
struct SettingsWindowRoot: View {
    let emby: Emby
    @AppStorage("bg") private var bgName = "black"
    var body: some View {
        SettingsView().environmentObject(emby).environment(\.appBG, Theme.bg(bgName))
            .frame(width: 680, height: 640)
            .dropdownLayer()   // the glass dropdowns open over the whole window
            .preferredColorScheme(.dark).focusEffectDisabled()
    }
}

/// Settings in their own window with the traffic lights (one at a time; opening again brings it to the front).
/// Every setting applies as soon as it's changed; closing (red button, Esc or ⌘W) saves the library choices
/// and reloads the pages, as Done did.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var onClose: () -> Void = {}
    private weak var emby: Emby?

    static func show(emby: Emby, onClose: @escaping () -> Void) { shared.show(emby: emby, onClose: onClose) }
    /// Closes the window (runs the close work); used before quitting for an update.
    static func close() { shared.window?.close() }

    private func show(emby: Emby, onClose: @escaping () -> Void) {
        self.emby = emby
        self.onClose = onClose
        if window == nil {
            let size = NSSize(width: 680, height: 640)   // owner: was 760, a little too wide
            let host = NSHostingView(rootView: SettingsWindowRoot(emby: emby))
            host.sizingOptions = []   // fixed size; never let SwiftUI layout drive the window frame
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            CoveWindowLook.applyGlass(w, content: host, size: size)   // see-through glass like the update alert
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        emby?.saveLibs()
        onClose()
    }
}

// MARK: - Building blocks

/// Width of the right-aligned label column, shared by every row so all controls line up.
let prefLabelW: CGFloat = 160

/// A group of related rows: a small heading over a rounded card (System Settings style).
struct PrefSection<C: View>: View {
    var title: String? = nil
    var last = false
    @ViewBuilder var content: C
    var body: some View {
        // Tight, with the panel radius and outline from Glass3DTokens
        let r: CGFloat = Glass3DTokens.Radius.panel
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
            if let title {
                Text(title.uppercased()).coveFont(size: 11, weight: .semibold).foregroundColor(Color.white.opacity(0.8))
                    .glassReadable().padding(.leading, Glass3DTokens.Space.s)
            }
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) { content }
                // Buttons without a style of their own (Clear, Save…, Connect…) get the shared secondary button
                .buttonStyle(GlassButtonStyle(.secondary))
                .padding(.vertical, Glass3DTokens.Space.m).padding(.trailing, Glass3DTokens.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The shared GlassCard surface (elevation 2)
                .elevation(2, radius: r)
        }
        .padding(.vertical, Glass3DTokens.Space.s)
    }
}

/// "Label:" right-aligned in the label column, the control beside it.
struct PrefRow<C: View>: View {
    var label: String = ""
    @ViewBuilder var control: C
    var body: some View {
        HStack(alignment: .top, spacing: Glass3DTokens.Space.m) {
            Text(label.isEmpty ? "" : label + ":").foregroundColor(.white).glassReadable()
                .frame(width: prefLabelW, alignment: .trailing)
                .padding(.top, Glass3DTokens.Space.xs)
            control
            Spacer(minLength: 0)
        }
    }
}

/// Grey help text lined up under the controls.
struct PrefNote: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).coveFont(size: 12).foregroundColor(Color.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.leading, prefLabelW + 10)
    }
}

// Old building blocks, still used by a few rows
struct SettingsGroup<C: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: C
    var body: some View {
        PrefSection {
            PrefRow(label: title) { VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) { content } }
            if let note { PrefNote(note) }
        }
    }
}

struct SettingRow<C: View>: View {
    let label: String
    @ViewBuilder var control: C
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.m) { Text(label).foregroundColor(Glass3DTokens.Grey.secondary); control; Spacer(minLength: 0) }
    }
}

func menuPicker<T: Hashable>(_ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
    SettingsMenuPicker(sel: sel, opts: opts)
}

/// A Settings choice: Cove's glass dropdown.
struct SettingsMenuPicker<T: Hashable>: View {
    let sel: Binding<T>
    let opts: [(T, String)]
    var body: some View { GlassPicker(selection: sel, options: opts) }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage("accent") private var accent = "red"
    @AppStorage("classicFont") private var classicFont = ClassicFont.defaultValue
    @AppStorage("textSize") private var textSize = "default"
    @AppStorage("classicHover") private var classicHover = "fog"
    @AppStorage("bg") private var bg = "black"
    @AppStorage(GlassFrost.followKey) private var glassFollow = true
    @AppStorage(GlassFrost.frostKey) private var glassFrost = GlassFrost.defaultFrost
    @AppStorage("navStyle") private var navStyle = "sidebar"
    @AppStorage("topBarLabels") private var topBarLabels = "both"
    @AppStorage("homeLayout") private var homeLayout = "row"

    func swatches(_ list: [(String, Color)], selection: Binding<String>) -> some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            ForEach(list, id: \.0) { name, color in
                Button { selection.wrappedValue = name } label: {
                    Circle().fill(color).frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                        // selection ring sits outside the swatch so it also shows on the white one
                        .overlay(Circle().stroke(Color.white, lineWidth: 3).padding(-5)
                            .opacity(selection.wrappedValue == name ? 1 : 0))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }.buttonStyle(.plainHand).tip(name.capitalized)
            }
        }
    }

    /// Background picker: labelled tiles, the selected one ringed in the accent color.
    func bgTiles(selection: Binding<String>) -> some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            ForEach(Theme.backgrounds, id: \.0) { name, color in
                let on = selection.wrappedValue == name
                Button { selection.wrappedValue = name } label: {
                    VStack(spacing: Glass3DTokens.Space.s) {
                        RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field).fill(color).frame(width: 64, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field)
                                .stroke(on ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.15)), lineWidth: on ? 3 : 1))
                        Text(name.capitalized).coveFont(size: 10).foregroundColor(on ? .primary : .secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plainHand)
            }
        }
    }

    @AppStorage("showRecent") private var showRecent = true
    @AppStorage("posterShowTitle") private var showTitle = true
    @AppStorage("posterShowYear") private var showYear = true
    @AppStorage("posterLabelAlign") private var labelAlign = "center"
    @AppStorage(WatchedDim.key) private var dimWatched = true

    var body: some View {
        PrefSection(title: "Appearance") {
            PrefRow(label: "Font") { menuPicker($classicFont, ClassicFont.choices) }
            PrefRow { ClassicFontPreview(choice: classicFont) }
            PrefRow(label: "Hover effect") { menuPicker($classicHover, HoverStyle.options) }
            PrefRow(label: "Glass") {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    if GlassFrost.hasLiquidGlass { Toggle("Follow macOS", isOn: $glassFollow) }
                    HStack(spacing: Glass3DTokens.Space.s) {
                        Text("Clear").coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary)
                        Slider(value: $glassFrost, in: 0...1).frame(width: 160)
                        Text("Tinted").coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                    .disabled(GlassFrost.hasLiquidGlass && glassFollow)
                    .opacity(GlassFrost.hasLiquidGlass && glassFollow ? 0.5 : 1)
                    GlassFrostPreview()
                }
            }
            PrefNote(GlassFrost.hasLiquidGlass
                     ? "The top bar, its buttons, the search pill and the player controls. Follow macOS uses the Liquid Glass setting in System Settings → Appearance; off, cove frosts the glass itself."
                     : "The top bar, its buttons, the search pill and the player controls: from clear to tinted.")
            PrefRow(label: "Text size") { menuPicker($textSize, TextScale.choices) }
            PrefRow(label: "Accent color") { swatches(Theme.accents, selection: $accent) }
            PrefRow(label: "Background") { bgTiles(selection: $bg) }
        }
        PrefSection(title: "Navigation") {
            PrefRow(label: "Style") { menuPicker($navStyle, [("sidebar", "Sidebar"), ("topbar", "Top bar")]) }
            // One choice, not two switches: the bar can never end up with neither icons nor names
            PrefRow(label: "Top bar shows") {
                menuPicker($topBarLabels, [("both", "Icons and Names"), ("names", "Names"), ("icons", "Icons")])
            }.disabled(navStyle != "topbar")
            PrefNote("Top bar replaces the sidebar with a bar across the top. Settings are in the Cove menu (⌘,).")
            PrefRow(label: "Also show") { Toggle("Recently Added", isOn: $showRecent) }
            PrefNote("Home is always there. Libraries, Favorites and Activity are chosen in Libraries.")
        }
        PrefSection(title: "Posters", last: true) {
            PrefRow(label: "Show under poster") {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    Toggle("Title", isOn: $showTitle)
                    Toggle("Year", isOn: $showYear)
                }
            }
            PrefRow(label: "Alignment") { menuPicker($labelAlign, [("center", "Centered"), ("left", "Left")]) }
                .disabled(!showTitle && !showYear)
            PrefRow(label: "Watched") { Toggle("Dim watched posters", isOn: $dimWatched) }
            PrefNote("Watched movies, shows and episodes are shown a little darker, so unwatched ones stand out. The ✓ shows it either way.")
        }
    }
}

// MARK: - Home

struct HomeSettings: View {
    @AppStorage("homeLayout") private var homeLayout = "row"
    @AppStorage("homeResumeLayout") private var resumeLayout = "row"
    @AppStorage("showUpNextRow") private var showUpNextRow = true
    @AppStorage("classicBannerStyle") private var bannerStyle = "cinematic"
    @AppStorage(Glass3DBannerNav.key) private var bannerNav = Glass3DBannerNav.defaultValue
    @AppStorage(BannerSource.key) private var bannerSource = BannerSource.defaultValue
    @AppStorage(BannerRefresh.key) private var bannerRefresh = BannerRefresh.defaultValue

    var body: some View {
        PrefSection(title: "Banner") {
            PrefRow(label: "Style") {
                menuPicker($bannerStyle, [("cinematic", "Cinematic"), ("panel", "Glass panel"), ("card", "Framed card")])
            }
            PrefRow(label: "Banner navigation") {
                menuPicker($bannerNav, Glass3DBannerNav.options)
            }
            PrefRow(label: "Banner shows") { menuPicker($bannerSource, BannerSource.options) }
            PrefRow(label: "Refresh banner") { menuPicker($bannerRefresh, BannerRefresh.options) }
            PrefNote("Which titles the banner at the top of Home cycles through; Home rows is the original mix. "
                     + "Refresh picks a fresh set while Cove stays open (not while it's hidden or a video plays).")
        }
        PrefSection(title: "Layout") {
            PrefRow(label: "Continue Watching") { menuPicker($resumeLayout, [("row", "Row"), ("grid", "Grid")]) }
            PrefRow(label: "Other sections") { menuPicker($homeLayout, [("row", "Rows"), ("grid", "Grid")]) }
            PrefNote("Rows scroll sideways; Grid shows every item of a section at once.")
        }
        PrefSection(title: "Rows", last: true) {
            PrefRow(label: "Watching") { Toggle("Up Next", isOn: $showUpNextRow) }
            PrefNote("The next episode of each show you're watching, under Continue Watching.")
            PrefNote("Which libraries get a row on Home, and what each row shows, is set per library in Libraries.")
        }
        NotificationsSettings()
    }
}

// MARK: - About

/// Preferences that are app state rather than settings: saved servers and sign-ins, the device id, which
/// servers are Jellyfin (they contain server addresses) and one-time migration flags. Reset keeps them, and
/// settings files never contain them.
enum InternalPrefs {
    static let keys: Set<String> = ["server", "token", "uid", "servers", "did", "importedEmbyFlix",
                                    "imageCacheTokenFree", "imageCacheNoHeaders", NewMediaStore.key]
    static let prefixes = ["jellyfin-"]
    static func contains(_ key: String) -> Bool { keys.contains(key) || prefixes.contains { key.hasPrefix($0) } }
}

/// The last section: app name, version, updates and source link, then Reset.
struct AboutSettings: View {
    @EnvironmentObject var emby: Emby
    @State private var cacheBytes = 0
    @State private var subtitleBytes = 0
    @State private var confirmReset = false
    @State private var backupMessage: String?


    /// Forgets every saved preference (colors, layout, filters, hover, subtitle and player settings, library
    /// order and window positions). The saved servers and sign-ins are kept.
    func resetAllSettings() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where !InternalPrefs.contains(key) {
            d.removeObject(forKey: key)
        }
        Task { await emby.loadLibs() }
    }

    /// The app's own preferences (not the system-wide ones UserDefaults also reports), without servers and sign-ins.
    var ownSettings: [String: Any] {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { !InternalPrefs.contains($0.key) }
    }

    /// Writes the settings to a property list file the user picks.
    func saveSettings() {
        let panel = NSSavePanel()
        panel.title = "Save Settings"
        panel.nameFieldStringValue = "Cove Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: ownSettings, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
            backupMessage = "Settings saved to \(url.lastPathComponent)."
        } catch {
            backupMessage = "Couldn't save the settings: \(error.localizedDescription)"
        }
    }

    /// Replaces the current settings with the ones in a file saved earlier. Servers and sign-ins stay as they are.
    func loadSettings() {
        let panel = NSOpenPanel()
        panel.title = "Load Settings"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let loaded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                backupMessage = "That file doesn't contain settings."; return
            }
            let d = UserDefaults.standard
            for key in ownSettings.keys { d.removeObject(forKey: key) }
            for (key, value) in loaded where !InternalPrefs.contains(key) { d.set(value, forKey: key) }
            Task { await emby.loadLibs() }
            backupMessage = "Settings loaded. Quit and reopen the app so the window and player pick up every change."
        } catch {
            backupMessage = "Couldn't load the settings: \(error.localizedDescription)"
        }
    }

    /// Sizes are read off the main thread so Settings opens at once.
    private func refreshStorage() {
        Task {
            let (img, subs) = await Task.detached(priority: .userInitiated) {
                (ImageCache.shared.diskUsage, SubtitleCache.shared.totalBytes())
            }.value
            cacheBytes = img; subtitleBytes = subs
        }
    }

    var body: some View {
        PrefSection(title: "Cove") {
            PrefRow(label: "Version") { Text("Cove " + AppVersion.label).textSelection(.enabled) }
            PrefRow(label: "Updates") { UpdateRow() }
            PrefRow(label: "Source") {
                Link("github.com/J0n4e/cove", destination: URL(string: "https://github.com/J0n4e/cove/releases")!).handCursor()
            }
        }
        PrefSection(title: "Storage") {
            PrefRow(label: "Image cache") {
                HStack(spacing: Glass3DTokens.Space.m) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                        .foregroundColor(Glass3DTokens.Grey.secondary).monospacedDigit()
                    Button("Clear") { ImageCache.shared.clear(); refreshStorage() }
                }
            }
            PrefRow(label: "Subtitles") {
                HStack(spacing: Glass3DTokens.Space.m) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(subtitleBytes), countStyle: .file))
                        .foregroundColor(Glass3DTokens.Grey.secondary).monospacedDigit()
                    Button("Clear") { SubtitleCache.shared.clear(); refreshStorage() }
                }
            }
            PrefNote("Posters and banners are saved on this Mac so they show instantly next time (up to 500 MB). Subtitle tracks too (up to 100 MB, unused ones go after 90 days).")
        }
        .onAppear { refreshStorage() }
        PrefSection(title: "Backup") {
            PrefRow(label: "Settings file") {
                HStack(spacing: Glass3DTokens.Space.m) {
                    Button("Save…") { saveSettings() }
                    Button("Load…") { loadSettings() }
                }
            }
            PrefNote("Saves every setting to a file, to load later or on another Mac. Servers and sign-ins are not included.")
        }
        .alert(backupMessage ?? "", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        PrefSection(title: "Reset", last: true) {
            PrefRow(label: "Reset") { Button("Reset All Settings…", role: .destructive) { confirmReset = true } }
            PrefNote("Puts every setting back to its default. Your servers and sign-in are kept.")
        }
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything goes back to its default. You stay signed in. Quit and reopen the app afterwards so the window starts fresh.")
        }
    }
}

// MARK: - Libraries

/// Per-library view defaults, stored in the same "lf-<id>" dictionary the library page uses.
struct LibraryDefaults {
    let id: String
    var key: String { "lf-" + id }
    func get(_ k: String, _ def: String) -> String {
        (UserDefaults.standard.dictionary(forKey: key)?[k] as? String) ?? def
    }
    func set(_ k: String, _ v: Any) {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        d[k] = v
        if k == "sort" { d["desc"] = (v as? String) != "name" }
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct LibrariesSettings: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("defaultLibraryLayout") private var defaultLayout = "grid"
    @AppStorage("showFavorites") private var showFavorites = true
    @AppStorage("showNowPlaying") private var showNowPlaying = true
    @AppStorage("favoritesLayout") private var favLayout = "row"
    @AppStorage("similarLayout") private var similarLayout = "row"
    @AppStorage("castSize") private var castSize = "normal"
    @AppStorage("moviePage") private var moviePage = "banner"
    @AppStorage(NavOrder.key) private var navOrder = ""
    @AppStorage("showEpisodeDescription") private var showEpDesc = true
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("seasonLayoutTV") private var seasonLayout = "row"
    @AppStorage("hoverZoomEnabled") private var hoverZoom = true
    @AppStorage("hoverZoomDuration") private var hoverZoomDur = 0.3
    @AppStorage("hoverZoomStyle") private var hoverZoomStyle = "spring"
    @State private var tick = 0   // redraw after writing per-library defaults

    func bind(_ lib: LibPref, _ k: String, _ def: String) -> Binding<String> {
        let d = LibraryDefaults(id: lib.id)
        return Binding(get: { _ = tick; return d.get(k, def) }, set: { d.set(k, $0); tick += 1 })
    }

    var body: some View {
        PrefSection(title: "Your libraries") {
            PrefRow(label: "Libraries") {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    libraryTable
                    Text("Drag to reorder. Click a library to change its options below.")
                        .coveFont(size: 12).foregroundColor(Glass3DTokens.Grey.secondary)
                }
            }
        }
        if selectedLib == Self.favoritesId {
            PrefSection(title: "Favorites") {
                PrefRow(label: "View") { menuPicker($favLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
            }
        } else if selectedLib == NavOrder.nowPlaying {
            PrefSection(title: ActivitySection.title) { PrefNote("Activity shows what is playing on your server right now, plus your stats and history. Move it with its ≡ handle.") }
        } else if let i = emby.libs.firstIndex(where: { $0.id == selectedLib }) ?? (emby.libs.isEmpty ? nil : 0) {
            libraryOptions(i, emby.libs[i])
        }
        PrefSection(title: "Movie and show pages") {
            PrefRow(label: "Movie pages") { menuPicker($moviePage, [("banner", "Big banner"), ("poster", "Poster and details")]) }
            PrefNote("Big banner opens a movie or collection as a show opens with Season layout → Cards: the backdrop fills the page; a collection shows its movies as cards.")
            PrefRow(label: "More Like This") { menuPicker($similarLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
            PrefNote("At the bottom of a movie or show page. You can also switch it there.")
            PrefRow(label: "Cast & Crew") { menuPicker($castSize, [("normal", "Normal"), ("large", "Large")]) }
            PrefNote("Large shows bigger actor photos and names.")
        }
        PrefSection(title: "New libraries", last: true) {
            PrefRow(label: "Open as") {
                HStack(spacing: Glass3DTokens.Space.m) {
                    menuPicker($defaultLayout, [("grid", "Grid"), ("list", "List")])
                    Button("Apply to All") {
                        for lib in emby.libs { LibraryDefaults(id: lib.id).set("layout", defaultLayout) }
                        tick += 1
                    }
                }
            }
        }
    }

    // MARK: Library table

    @State private var selectedLib: String?
    /// Table selection for the Favorites line (not a server library).
    static let favoritesId = NavOrder.favorites
    @AppStorage("accent") private var accentName = "red"
    var blue: Color { Theme.accent(accentName) }

    func kindIcon(_ lib: LibPref) -> String {
        switch lib.kind {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "boxsets": return "square.stack"
        case "music": return "music.note"
        default: return "folder"
        }
    }

    /// Library | Sidebar | Home, one line per library; drag rows to reorder.
    var libraryTable: some View {
        let sel = selectedLib ?? emby.libs.first?.id
        return VStack(spacing: 0) {
            HStack {
                Text("Library").frame(maxWidth: .infinity, alignment: .leading)
                Text("Sidebar").frame(width: 70)
                Text("Home").frame(width: 60)
            }
            .coveFont(size: 10, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
            .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s)
            Divider()
            // A plain stack, not a List: the List's table view (NSTableView) took the drag over for its own row
            // dragging and cancelled ours, so rows never moved (owner)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tableRows, id: \.self) { id in
                        Group {
                            if NavOrder.sections.contains(id) { sectionLine(id, on: sel == id) }
                            else if let i = emby.libs.firstIndex(where: { $0.id == id }) { libraryLine(i, on: sel == id) }
                        }
                        .zIndex(dragId == id ? 1 : 0)
                    }
                }
                .padding(.horizontal, Glass3DTokens.Space.xs).padding(.vertical, Glass3DTokens.Space.xs)
            }
            .scrollDisabled(tableRows.count <= 7 || dragId != nil)
            .scrollIndicators(tableRows.count > 7 ? .visible : .hidden)
            .frame(height: CGFloat(min(tableRows.count, 7)) * 32 + 8)
        }
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field).stroke(Color.white.opacity(0.1)))
    }

    /// Table order: the libraries, with Favorites and Now Playing at their saved places.
    var tableRows: [String] { NavOrder.rows(navOrder, libIds: emby.libs.map(\.id)) }

    func libraryLine(_ i: Int, on: Bool) -> some View {
        let lib = emby.libs[i]
        return HStack {
            dragHandle(lib.id, on: on)
            Image(systemName: kindIcon(lib)).foregroundColor(on ? .white : blue).frame(width: 20)
            Text(lib.title).foregroundColor(lib.visible ? .primary : .secondary).lineLimit(1)
            Spacer()
            Toggle("", isOn: $emby.libs[i].visible).labelsHidden().frame(width: 70)
            Toggle("", isOn: $emby.libs[i].onHome).labelsHidden().disabled(!lib.visible).frame(width: 60)
        }
        .padding(.horizontal, Glass3DTokens.Space.s).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb).fill(on ? blue.opacity(0.85) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedLib = lib.id }.handCursor()
    }

    /// Favorites or Now Playing: not server libraries, so the Sidebar box is the section's show switch
    /// and there is no Home row.
    func sectionLine(_ id: String, on: Bool) -> some View {
        let fav = id == NavOrder.favorites
        let shown = fav ? $showFavorites : $showNowPlaying
        return HStack {
            dragHandle(id, on: on)
            Image(systemName: fav ? "heart" : ActivitySection.icon).foregroundColor(on ? .white : blue).frame(width: 20)
            Text(fav ? "Favorites" : ActivitySection.title).foregroundColor(shown.wrappedValue ? .primary : .secondary).lineLimit(1)
            Spacer()
            Toggle("", isOn: shown).labelsHidden().frame(width: 70)
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, Glass3DTokens.Space.s).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb).fill(on ? blue.opacity(0.85) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedLib = id }.handCursor()
    }

    @State private var dragId: String?
    @State private var dragFrom = 0

    /// ≡ handle: drag it up or down and the row moves one place for every row height passed.
    /// (List's onMove and drag-and-drop never started a drag in this table on macOS.)
    func dragHandle(_ id: String, on: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .coveFont(size: 12, weight: .semibold)
            .foregroundColor(on || dragId == id ? .white : .secondary)
            .frame(width: 18, height: 28).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    let rows = tableRows
                    if dragId == nil {
                        dragId = id; selectedLib = id
                        dragFrom = rows.firstIndex(of: id) ?? 0
                    }
                    let target = min(max(dragFrom + Int((v.translation.height / 32).rounded()), 0), rows.count - 1)
                    if let d = dragId, let cur = rows.firstIndex(of: d), cur != target {
                        var r = rows
                        r.move(fromOffsets: [cur], toOffset: target > cur ? target + 1 : target)
                        withAnimation(Glass3DTokens.Motion.fast) { applyOrder(r) }
                    }
                }
                .onEnded { _ in dragId = nil })
            .tip("Drag to reorder")
    }

    /// Splits a table order back into the library order and the sections' places.
    func applyOrder(_ rows: [String]) {
        navOrder = rows.joined(separator: ",")
        let byId = Dictionary(emby.libs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        emby.libs = rows.compactMap { byId[$0] }
    }

    /// Options for the library picked in the table.
    func libraryOptions(_ i: Int, _ lib: LibPref) -> some View {
        PrefSection(title: lib.title) {
            PrefRow(label: "Name") {
                TextField(lib.name, text: $emby.libs[i].title).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            PrefRow(label: "View") { menuPicker(bind(lib, "layout", defaultLayout), [("grid", "Grid"), ("list", "List")]) }
            PrefRow(label: "Sort by") {
                menuPicker(bind(lib, "sort", "name"),
                           [("name", "Name"), ("latest", "Recently Added"), ("release", "Release Date"), ("top", "Rating")])
            }
            PrefRow(label: "Show") {
                menuPicker(bind(lib, "watch", "all"), [("all", "All"), ("unwatched", "Unwatched"), ("watched", "Watched")])
            }
            PrefRow(label: "Home row shows") {
                menuPicker($emby.libs[i].style, [("latest", "Latest"), ("top", "Top Rated"), ("random", "Random"), ("az", "A–Z")])
            }.disabled(!lib.onHome || !lib.visible)
            // Episode options apply to every TV library, so they show with any of them
            if lib.kind == "tvshows" {
                PrefRow(label: "Season layout") {
                    menuPicker($seasonLayout, [("row", "Row"), ("grid", "Grid"), ("deck", "Cards")])
                }
                PrefRow(label: "Episode layout") { menuPicker($epLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
                PrefRow { Toggle("Show episode descriptions", isOn: $showEpDesc) }
            }
        }
    }

    func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: Glass3DTokens.Space.s) { Text(t).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1).fixedSize(); c() }.fixedSize()
    }
}

// MARK: - Series & episodes

struct SeriesSettings: View {
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("episodeSubLang") private var epSubLang = ""

    static let languages = ["English", "Romanian", "Spanish", "French", "German", "Italian", "Portuguese",
                            "Dutch", "Hungarian", "Polish", "Russian", "Turkish", "Greek", "Swedish",
                            "Norwegian", "Danish", "Finnish", "Czech", "Arabic", "Hebrew", "Japanese",
                            "Korean", "Chinese"]

    var langOptions: [(String, String)] {
        let always = UserDefaults.standard.bool(forKey: "subAlways")
        var list = [("", always ? (UserDefaults.standard.string(forKey: "subLang") ?? "english").capitalized : "Off")] + (always ? [("off", "Off")] : [])
            + Self.languages.map { ($0.lowercased(), $0) }
        if !epSubLang.isEmpty, !list.contains(where: { $0.0 == epSubLang }) {
            list.append((epSubLang, epSubLang.capitalized))
        }
        return list
    }

    var body: some View {
        SettingsGroup(title: "Episodes") {
            SettingRow(label: "Episode layout") { menuPicker($epLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
            SettingRow(label: "Subtitle language") { menuPicker($epSubLang, langOptions) }
        }
        Text("The subtitle language is used for every episode you play from a series page; it's the same setting as the Subtitles menu next to the episode list.")
            .coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary)
    }
}

// MARK: - Subtitles

struct SubtitleSettings: View {
    @AppStorage("subTextSize") private var subTextSize = "normal"
    @AppStorage("subColor") private var subColor = "white"
    @AppStorage("subShadowStyle") private var subShadow = "drop"
    @AppStorage("subBg") private var subBg = "none"
    @AppStorage("subBottom") private var subBottom = 10.0
    @AppStorage("subAlways") private var subAlways = false
    @AppStorage("subLang") private var subLang = "english"

    var body: some View {
        PrefSection(title: "Language") {
            PrefRow { Toggle("Always load my subtitle language", isOn: $subAlways) }
            PrefRow(label: "Language") {
                menuPicker($subLang, SeriesSettings.languages.map { ($0.lowercased(), $0) })
            }.disabled(!subAlways)
            PrefNote("Movies and episodes start with subtitles in this language when they have them. You can still turn them off in the player.")
        }
        // Preview beside the style menus, so every change shows without scrolling (Settings is a fixed
        // 760 × 640 window, so this fits on any monitor)
        PrefSection(title: "Style", last: true) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
                    PrefRow(label: "Text size") { menuPicker($subTextSize, PlayerView.sizes.map { ($0.0, $0.1) }) }
                    PrefRow(label: "Text color") { menuPicker($subColor, PlayerView.colors.map { ($0.0, $0.1) }) }
                    PrefRow(label: "Shadow") { menuPicker($subShadow, PlayerView.shadows) }
                    PrefRow(label: "Background") { menuPicker($subBg, PlayerView.bgs.map { ($0.0, $0.1) }) }
                    PrefRow(label: "Distance from bottom") {
                        menuPicker($subBottom, [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") })
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                // As big as the space beside the menus allows, kept 16:9
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(GeometryReader { g in preview(h: g.size.height) })
                    .frame(maxWidth: .infinity).padding(.leading, Glass3DTokens.Space.xl)
            }
            PrefRow {
                Button("Restore Defaults") {
                    subTextSize = "normal"; subColor = "white"; subShadow = "drop"; subBg = "none"; subBottom = 10
                }
            }
        }
    }

    func preview(h: CGFloat) -> some View {
        let fs = h * (PlayerView.sizes.first { $0.0 == subTextSize }?.2 ?? 0.045) * 1.6
        let color = PlayerView.colors.first { $0.0 == subColor }?.2 ?? .white
        return ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.4), Color(red: 0.75, green: 0.7, blue: 0.6)],
                           startPoint: .top, endPoint: .bottom)
            Text("This is how subtitles will look.")
                .coveFont(size: fs, weight: .medium)
                .foregroundColor(color)
                .modifier(SubShadow(style: subShadow, color: subColor == "black" ? .white : .black))
                .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.xs)
                .background(Color.black.opacity(PlayerView.bgs.first { $0.0 == subBg }?.2 ?? 0))
                .cornerRadius(Glass3DTokens.Radius.tag)
                .padding(.bottom, h * subBottom / 100)
        }
        .frame(height: h).frame(maxWidth: .infinity).cornerRadius(Glass3DTokens.Radius.field)
    }
}

// MARK: - Playback

struct PlaybackSettings: View {
    @AppStorage("defaultQuality") private var quality = 0
    @AppStorage("defaultSpeed") private var speed = 1.0
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("autoSkipIntro") private var autoSkipIntro = true
    @AppStorage("skipSeconds") private var skip = 10
    @AppStorage("clickToPause") private var clickToPause = true
    @AppStorage("debugLog") private var debugLog = false
    @AppStorage(SyncPlayService.liveSocketKey) private var liveSocket = true
    @AppStorage(TvTarget.key) private var tvTarget = TvTarget.cast
    @ObservedObject private var castSession = CastSession.shared
    @ObservedObject private var tvRoute = TvRouteState.shared

    var body: some View {
        PrefSection(title: "Player") {
            PrefRow(label: "Clicking the video") { Toggle("Plays or pauses", isOn: $clickToPause) }
            PrefNote("With this off, clicking the video shows or hides the controls.")
            TvTargetRow(tvTarget: $tvTarget, casting: castSession.isCasting, airPlayActive: tvRoute.airPlayActive)
            PrefNote("Google Cast: Chromecast, Google TV and Cast TVs — the TV streams from the server. AirPlay: Apple TV and AirPlay TVs — the Mac plays and sends the picture.")
        }
        PrefSection(title: "Start with") {
            PrefRow(label: "Quality") {
                menuPicker($quality, [(0, "Original"), (8_000_000, "1080p · 8 Mbps"), (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")])
            }
            PrefRow(label: "Speed") {
                menuPicker($speed, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map { ($0, $0 == 1 ? "Normal" : String(format: "%gx", $0)) })
            }
            PrefRow(label: "Skip back / forward") {
                menuPicker($skip, [(5, "5 s"), (10, "10 s"), (15, "15 s"), (30, "30 s")])
            }
        }
        PrefSection(title: "Automatically") {
            PrefRow {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    Toggle("Play the next episode", isOn: $autoNext)
                    Toggle("Skip intros", isOn: $autoSkipIntro)
                }
            }
        }
        PrefSection(title: "Connection") {
            PrefRow { Toggle("Live connection to the server", isOn: $liveSocket) }
            PrefNote("Jellyfin servers only. Keeps a small live connection open so remote control from the Jellyfin dashboard works and updates arrive instantly. When off, Cove connects only while you use SyncPlay.")
        }
        PrefSection(title: "Troubleshooting", last: true) {
            PrefRow(label: "Debug log") { Toggle("Write a player debug log", isOn: $debugLog) }
            PrefNote("Saved to ~/Library/Logs/Cove.log (kept under about 1 MB). Leave it off unless you're chasing a playback problem.")
        }
    }
}


// MARK: - Servers

struct ServerSettings: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var trakt = Trakt.shared
    @State private var clientIdDraft = ""
    @AppStorage("traktScrobble") private var scrobble = false
    @AppStorage("traktSyncWatched") private var syncWatched = false
    let redirectURI = "urn:ietf:wg:oauth:2.0:oob"

    func saveClientId() {
        let id = clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        trakt.setClientId(id)
        clientIdDraft = ""
    }

    func step<V: View>(_ n: Int, @ViewBuilder _ text: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Glass3DTokens.Space.s) {
            Text("\(n).").bold().frame(width: 14, alignment: .trailing)
            text().fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Switching or signing out closes Settings (its own window now, no longer a sheet).
    func dismiss() { SettingsWindow.close() }
    @State private var busy: String?

    func connect(_ srv: SavedServer) {
        guard srv.token != nil else { emby.switchServer(); dismiss(); return }
        busy = srv.id
        Task {
            let result = await emby.resume(srv)
            busy = nil
            switch result {
            case .ok: dismiss()
            case .expired: emby.switchServer(); dismiss()    // the server list asks for the password again
            case .unreachable:
                // Stay on the current server instead of signing out of it
                let a = NSAlert()
                a.messageText = "Couldn't reach \(srv.name)"
                a.informativeText = "Check that the server is running and try again. You're still connected to \(emby.currentServerName)."
                a.runModal()
            }
        }
    }

    var body: some View {
        PrefSection(title: "Current server") {
            PrefRow(label: "Connected to") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(emby.currentServerName).bold()
                    Text(emby.currentServer?.user.isEmpty == false ? "\(emby.currentServer!.user) · \(emby.server)" : emby.server)
                        .coveFont(size: 12).foregroundColor(Glass3DTokens.Grey.secondary).textSelection(.enabled)
                }
            }
            PrefRow {
                HStack(spacing: Glass3DTokens.Space.m) {
                    Button("Sign Out", role: .destructive) { emby.logout(); dismiss() }
                }
            }
        }
        PrefSection(title: "Saved servers") {
            PrefRow(label: "Servers") {
                VStack(alignment: .leading, spacing: 0) {
                    if emby.servers.isEmpty { Text("No saved servers.").cvFont(13).foregroundColor(Glass3DTokens.Grey.secondary).padding(Glass3DTokens.Space.m) }
                    ForEach(Array(emby.servers.enumerated()), id: \.element.id) { i, srv in
                        let current = srv.id == emby.server.lowercased()
                        HStack(spacing: Glass3DTokens.Space.m) {
                            Image(systemName: "server.rack").foregroundColor(Glass3DTokens.Grey.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                // Click the name to rename it (helps tell servers apart)
                                TextField("Name", text: Binding(get: { srv.name }, set: { emby.renameServer(srv, $0) }))
                                    .textFieldStyle(.plain).fontWeight(.semibold).frame(maxWidth: 220)
                                HStack(spacing: Glass3DTokens.Space.xs) {
                                    ConnectionBadge(address: srv.url)
                                    Text((srv.user.isEmpty ? srv.url : "\(srv.user) · \(srv.url)") + " · " + emby.kindLabel(srv))
                                        .foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1).truncationMode(.middle)
                                }.coveFont(size: 10)
                            }
                            Spacer(minLength: 12)
                            if current {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(TintShapeStyle())
                                    .tip("Connected")
                            } else if busy == srv.id {
                                Spinner().controlSize(.small)
                            } else {
                                Button("Connect") { connect(srv) }
                                Button { emby.removeServer(srv) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plainHand).tip("Remove this server and its sign-in")
                            }
                        }
                        .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.m)
                        .background(i % 2 == 0 ? Color.white.opacity(0.04) : Color.clear)
                    }
                }
                .frame(width: 440)
                .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field).stroke(Color.white.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field))
            }
            PrefRow { Button("Add Server…") { emby.switchServer(); dismiss() } }
            PrefNote("Click a server's name to rename it. Connect switches Cove to that server. Add Server opens the sign-in screen.")
        }
        NexcrateSettingsSection()   // Delete… through nexcrate (Glass3DDeleteEverywhere.swift)
        NexviewSettingsSection()    // Cleanup's "Requested by" (Glass3DNexviewSettings.swift)
        PrefSection(title: "Trakt", last: true) {
            PrefRow(label: "Ratings") {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    if let u = trakt.user {
                        HStack(spacing: Glass3DTokens.Space.s) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(TintShapeStyle())
                            Text("Connected as ") + Text(u).bold()
                        }
                        HStack(spacing: Glass3DTokens.Space.m) {
                            Button("Refresh Ratings") { Task { await trakt.refresh(force: true) } }
                            Button("Disconnect", role: .destructive) { trakt.disconnect() }
                        }
                        if !trakt.pending.isEmpty {
                            Text("\(trakt.pending.count) rating\(trakt.pending.count == 1 ? "" : "s") waiting to be sent.")
                                .coveFont(size: 12).foregroundColor(Glass3DTokens.Grey.secondary)
                        }
                    } else if let s = trakt.signIn {
                        Text("Enter this code on \(s.url):").foregroundColor(Glass3DTokens.Grey.secondary)
                        Text(s.userCode).coveFont(size: 26, weight: .bold, design: .monospaced).textSelection(.enabled)
                        HStack(spacing: Glass3DTokens.Space.m) {
                            Spinner().controlSize(.small)
                            Text("Waiting for Trakt…").foregroundColor(Glass3DTokens.Grey.secondary)
                            Button("Cancel") { trakt.cancelSignIn() }
                        }
                    } else if trakt.isConfigured {
                        Button("Connect Trakt…") { trakt.connect() }
                    } else {
                        Text("Not set up yet. Follow the steps below.").foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                    if let e = trakt.lastError { Text(e).coveFont(size: 12).foregroundColor(Glass3DTokens.Status.warning) }
                }
            }
            if trakt.user != nil {
                PrefRow(label: "Scrobbling") {
                    VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                        Toggle("Scrobble what I watch in Cove", isOn: $scrobble)
                        Text("Trakt shows what you're watching and logs the play when you finish (past 80%).")
                            .coveFont(size: 12).foregroundColor(Glass3DTokens.Grey.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                PrefRow(label: "Watched status") {
                    VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                        Toggle("Sync watched status", isOn: $syncWatched)
                            .onChange(of: syncWatched) { _, on in if on { Task { await trakt.importWatched(emby) } } }
                        Text("Marking something watched in Cove adds a play on Trakt, and plays Trakt gets from other apps are marked watched here (from now on, every hour). Marking it unwatched only resets your progress in Cove: Trakt keeps every play, so rewatches add up.")
                            .coveFont(size: 12).foregroundColor(Glass3DTokens.Grey.secondary).fixedSize(horizontal: false, vertical: true)
                        if syncWatched {
                            HStack(spacing: Glass3DTokens.Space.m) {
                                Button("Sync Now") { Task { await trakt.importWatched(emby) } }
                                if let t = trakt.lastWatchedSync {
                                    Text("Last synced \(t.formatted(date: .abbreviated, time: .shortened))")
                                        .coveFont(size: 12).foregroundColor(Glass3DTokens.Grey.secondary)
                                }
                            }
                        }
                    }
                }
                PrefRow(label: "Emby Trakt plugin") {
                    VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                        Text("If your Emby server also has the Trakt plugin, turn these off for your user (Emby → your user's preferences → Trakt), or plays get logged twice and marking a show unwatched removes its plays from Trakt:")
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Sync Manual Playstate Changes to Trakt", systemImage: "xmark.circle").fontWeight(.semibold)
                        Label("Update Trakt watched history during Scheduled Task", systemImage: "xmark.circle").fontWeight(.semibold)
                        Text("The plugin's scrobbling always stays on, so leave Cove's Scrobble switch off when the plugin is installed. Keep \u{201C}Skip unwatched import from Trakt\u{201D} on.")
                            .foregroundColor(Glass3DTokens.Grey.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .coveFont(size: 12).frame(maxWidth: 440, alignment: .leading)
                }
            }
            if trakt.user == nil && trakt.signIn == nil {
                PrefRow(label: "Client ID") {
                    HStack(spacing: Glass3DTokens.Space.s) {
                        // Shown as dots once saved; typing a new one replaces it
                        SecureField(trakt.isConfigured ? "Saved on this Mac" : "Paste the Client ID", text: $clientIdDraft)
                            .help("Stored in Cove's preferences, scrambled with a key tied to this Mac. Not readable if the file is copied elsewhere.")
                            .textFieldStyle(.roundedBorder).frame(width: 300)
                            .onSubmit(saveClientId)
                        Button("Save", action: saveClientId).disabled(clientIdDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if trakt.isConfigured {
                            Button("Remove") { trakt.setClientId(""); clientIdDraft = "" }
                        }
                    }
                }
                PrefRow(label: "How to set up") {
                    VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                        step(1) {
                            Text("Sign in on trakt.tv, then open ") +
                            Text("[trakt.tv/oauth/applications](https://trakt.tv/oauth/applications)") +
                            Text(" and click **New Application**.")
                        }
                        step(2) { Text("Name it **Cove**. As Redirect URI enter:") }
                        HStack(spacing: Glass3DTokens.Space.s) {
                            Text(redirectURI).coveFont(size: 12, design: .monospaced).textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(redirectURI, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.plainHand).tip("Copy")
                        }.padding(.leading, Glass3DTokens.Space.xl)
                        step(3) { Text("Leave the rest empty and click **Save App**.") }
                        step(4) { Text("Copy the **Client ID** (there's no secret), paste it above and click **Save**.") }
                        step(5) { Text("Click **Connect Trakt…**, enter the code Cove shows on trakt.tv/activate and allow Cove.") }
                    }
                    .coveFont(size: 12).frame(maxWidth: 440, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { u in
                        if let u = SafeLink.url(u.absoluteString) { NSWorkspace.shared.open(u) }
                        return .handled
                    })
                }
            }
            PrefNote("Rate movies and episodes with the star button next to Play. Your ratings are saved on Trakt and show up on every Mac connected to the same Trakt account. The Client ID and sign-in are saved on this Mac, scrambled with a key tied to it.")
        }
        .keepsWindowOpen(busy != nil || !clientIdDraft.isEmpty)
    }
}

// MARK: - Trakt stats

/// Your Trakt numbers: all time, this month against last month, the last 12 months, your ratings and the latest
/// plays. Loaded when the tab opens (the last numbers show meanwhile).
struct TraktStatsSettings: View {
    @ObservedObject private var trakt = Trakt.shared
    @AppStorage("accent") private var accentName = "red"
    var accent: Color { Theme.accent(accentName) }

    var body: some View {
        if !trakt.isConnected {
            PrefSection(title: "Trakt", last: true) {
                PrefRow(label: "Stats") {
                    Text("Connect Trakt in Settings → Connect to see your numbers here.").foregroundColor(Glass3DTokens.Grey.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Glass3DTokens.Space.m) {
                    Text("Connected as ") + Text(trakt.user ?? "").bold()
                    Spacer()
                    if trakt.loadingStats { Spinner().controlSize(.small) }
                    else if let s = trakt.stats {
                        Text("Updated \(s.updated.formatted(date: .omitted, time: .shortened))").foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                    Button("Refresh") { Task { await trakt.loadStats() } }.disabled(trakt.loadingStats)
                }
                .coveFont(size: 12).padding(.top, Glass3DTokens.Space.s).padding(.horizontal, Glass3DTokens.Space.s)
                if let e = trakt.lastError { Text(e).coveFont(size: 12).foregroundColor(Glass3DTokens.Status.warning).padding(.horizontal, Glass3DTokens.Space.s) }
                if let s = trakt.stats { content(s) }
                else if trakt.loadingStats { Text("Loading your stats…").foregroundColor(Glass3DTokens.Grey.secondary).padding(Glass3DTokens.Space.xl) }
            }
            .task { await trakt.loadStats() }
        }
    }

    @ViewBuilder func content(_ s: Trakt.Stats) -> some View {
        PrefSection(title: "All time") {
            HStack(spacing: Glass3DTokens.Space.m) {
                tile("Movies", "\(s.movies.watched)", "\(s.movies.plays) plays · \(hours(s.movies.minutes))")
                tile("Shows", "\(s.shows)", "\(s.episodes.plays) episodes · \(hours(s.episodes.minutes))")
                tile("Time watched", hours(s.movies.minutes + s.episodes.minutes), days(s.movies.minutes + s.episodes.minutes))
            }.padding(.horizontal, Glass3DTokens.Space.m)
        }
        let cur = s.months.last, prev = s.months.dropLast().last
        PrefSection(title: "This month") {
            HStack(spacing: Glass3DTokens.Space.m) {
                tile("Movies", "\(cur?.movies ?? 0)", change(cur?.movies ?? 0, prev?.movies ?? 0))
                tile("Episodes", "\(cur?.episodes ?? 0)", change(cur?.episodes ?? 0, prev?.episodes ?? 0))
                tile("Time", hours(cur?.minutes ?? 0), change(cur?.minutes ?? 0, prev?.minutes ?? 0))
            }.padding(.horizontal, Glass3DTokens.Space.m)
            if let t = s.topShowThisMonth {
                (Text("Most watched: ").foregroundColor(Glass3DTokens.Grey.secondary) + Text(t).bold()
                 + Text(" · \(s.topShowEpisodes) episode\(s.topShowEpisodes == 1 ? "" : "s")").foregroundColor(Glass3DTokens.Grey.secondary))
                    .coveFont(size: 12).padding(.horizontal, Glass3DTokens.Space.l)
            }
        }
        PrefSection(title: "Last 12 months · hours watched") { monthsChart(s.months).padding(.horizontal, Glass3DTokens.Space.l) }
        PrefSection(title: "Your ratings · \(s.ratingsTotal)") { ratingsChart(s.distribution).padding(.horizontal, Glass3DTokens.Space.l) }
        PrefSection(title: "Recently watched", last: true) {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                ForEach(Array(s.recent.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: Glass3DTokens.Space.m) {
                        Image(systemName: r.isMovie ? "film" : "tv").foregroundColor(Glass3DTokens.Grey.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).fontWeight(.semibold).lineLimit(1)
                            Text(r.subtitle).coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(r.date.formatted(.relative(presentation: .named))).coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                }
            }.padding(.horizontal, Glass3DTokens.Space.l)
        }
    }

    func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
            Text(title.uppercased()).coveFont(size: 10, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
            Text(value).coveFont(size: 26, weight: .bold).foregroundColor(accent).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(Glass3DTokens.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field).fill(Color.white.opacity(0.05)))
    }

    func monthsChart(_ months: [Trakt.Stats.Month]) -> some View {
        let maxH = max(1, months.map(\.minutes).max() ?? 1)
        return HStack(alignment: .bottom, spacing: Glass3DTokens.Space.s) {
            ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                VStack(spacing: Glass3DTokens.Space.xs) {
                    Text(m.minutes > 0 ? "\(m.minutes / 60)" : "").coveFont(size: 9).foregroundColor(Glass3DTokens.Grey.secondary)
                    RoundedRectangle(cornerRadius: Glass3DTokens.Radius.tag)
                        .fill(i == months.count - 1 ? accent : accent.opacity(0.45))
                        .frame(height: max(2, CGFloat(m.minutes) / CGFloat(maxH) * 90))
                    Text(monthLetter(m.key)).coveFont(size: 10).foregroundColor(Glass3DTokens.Grey.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(monthName(m.key)): \(m.movies) movie\(m.movies == 1 ? "" : "s"), \(m.episodes) episode\(m.episodes == 1 ? "" : "s"), \(hours(m.minutes))")
            }
        }.frame(height: 125)
    }

    func ratingsChart(_ dist: [Int]) -> some View {
        let maxN = max(1, dist.max() ?? 1)
        return HStack(alignment: .bottom, spacing: Glass3DTokens.Space.s) {
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: Glass3DTokens.Space.xs) {
                    Text(dist[i] > 0 ? "\(dist[i])" : "").coveFont(size: 9).foregroundColor(Glass3DTokens.Grey.secondary)
                    RoundedRectangle(cornerRadius: Glass3DTokens.Radius.tag).fill(accent.opacity(0.35 + 0.065 * Double(i)))
                        .frame(height: max(2, CGFloat(dist[i]) / CGFloat(maxN) * 70))
                    Text("\(i + 1)").coveFont(size: 10, weight: .semibold).foregroundColor(Glass3DTokens.Grey.secondary)
                }.frame(maxWidth: .infinity)
            }
        }.frame(height: 105)
    }

    func hours(_ minutes: Int) -> String {
        let h = Double(minutes) / 60
        return h >= 100 ? "\(Int(h.rounded())) h" : String(format: "%.1f h", h)
    }
    func days(_ minutes: Int) -> String {
        let d = Double(minutes) / 1440
        return d >= 1 ? String(format: "%.1f days", d) : "less than a day"
    }
    /// "+12% vs last month", "same as last month", "new this month".
    func change(_ now: Int, _ before: Int) -> String {
        if before == 0 { return now > 0 ? "none last month" : "none last month either" }
        let p = Int((Double(now - before) / Double(before) * 100).rounded())
        return p == 0 ? "same as last month" : "\(p > 0 ? "+" : "")\(p)% vs last month"
    }
    func monthDate(_ key: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.date(from: key)
    }
    func monthLetter(_ key: String) -> String {
        guard let d = monthDate(key) else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM"; return String(f.string(from: d).prefix(3))
    }
    func monthName(_ key: String) -> String {
        guard let d = monthDate(key) else { return key }
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: d)
    }
}

/// Settings → Playback "Play on a TV with": greyed out (and changes ignored) while a cast or AirPlay runs.
private struct TvTargetRow: View {
    @Binding var tvTarget: String
    let casting: Bool
    let airPlayActive: Bool

    var body: some View {
        let reason = TvTarget.lockReason(casting: casting, airPlayActive: airPlayActive)
        let guarded = Binding<String>(get: { TvTarget.normalized(tvTarget) }, set: { new in
            tvTarget = TvTarget.apply(new, current: tvTarget, casting: casting, airPlayActive: airPlayActive)
        })
        PrefRow(label: "Play on a TV with") {
            menuPicker(guarded, TvTarget.options).disabled(reason != nil).help(reason ?? "")
        }
        if let reason { PrefNote(reason + ".") }
    }
}
