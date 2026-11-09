import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// App settings: one window with a sidebar of sections.
/// Values live in UserDefaults (the same keys the rest of the app reads).
struct SettingsView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBG) var bg
    @AppStorage("accent") private var accentName = "red"
    var accent: Color { Theme.accent(accentName) }
    var onDone: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", home = "Home", libraries = "Libraries",
             subtitles = "Subtitles", playback = "Playback", servers = "Servers", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "paintpalette"
            case .home: return "house"
            case .libraries: return "square.grid.2x2"
            case .subtitles: return "captions.bubble"
            case .playback: return "play.rectangle"
            case .servers: return "server.rack"
            case .about: return "info.circle"
            }
        }
    }
    @State private var section: Section = .general

    var body: some View {
        VStack(spacing: 0) {
            // Apple TV style: the section name on top, then a row of icon tabs
            Text(section.rawValue).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                .padding(.top, 12)
            HStack(spacing: 4) {
                ForEach(Section.allCases) { s in
                    let on = section == s
                    Button { section = s } label: {
                        VStack(spacing: 3) {
                            Image(systemName: s.icon).font(.system(size: 20))
                            Text(s.rawValue).font(.system(size: 11))
                        }
                        .foregroundColor(on ? accent : .secondary)
                        .frame(minWidth: 62).padding(.horizontal, 6).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? accent.opacity(0.15) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? accent.opacity(0.4) : Color.clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).focusEffectDisabled()
                }
            }.padding(.top, 8).padding(.bottom, 10)
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
                    case .about: AboutSettings()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.vertical, 10)
            }
            Divider()
            HStack {
                Spacer()
                // Both buttons in the accent color; Cancel is the lighter one
                Button { dismiss() } label: { Text("Cancel").frame(minWidth: 60) }
                    .buttonStyle(.bordered).tint(accent).controlSize(.large)
                Button { emby.saveLibs(); onDone(); dismiss() } label: { Text("OK").frame(minWidth: 60) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 760, height: 640)
        .tint(accent)     // switches, menus and links inside Settings too
        .background(bg)   // follows Appearance → Background, like the rest of the app
        // Esc closes Settings and keeps the changes, like OK / Done
        .background(Button("") { emby.saveLibs(); onDone(); dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0))
    }
}

// MARK: - Building blocks

/// Width of the right-aligned label column, shared by every row so all controls line up.
let prefLabelW: CGFloat = 180

/// A group of related rows: a small heading over a rounded card (System Settings style).
struct PrefSection<C: View>: View {
    var title: String? = nil
    var last = false
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    .padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.vertical, 16).padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
        }
        .padding(.vertical, 9)
    }
}

/// "Label:" right-aligned in the label column, the control beside it.
struct PrefRow<C: View>: View {
    var label: String = ""
    @ViewBuilder var control: C
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label.isEmpty ? "" : label + ":").frame(width: prefLabelW, alignment: .trailing)
                .padding(.top, 4)
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
        Text(text).font(.callout).foregroundColor(.secondary)
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
            PrefRow(label: title) { VStack(alignment: .leading, spacing: 10) { content } }
            if let note { PrefNote(note) }
        }
    }
}

struct SettingRow<C: View>: View {
    let label: String
    @ViewBuilder var control: C
    var body: some View {
        HStack(spacing: 10) { Text(label).foregroundColor(.secondary); control; Spacer(minLength: 0) }
    }
}

func menuPicker<T: Hashable>(_ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
    Picker("", selection: sel) {
        ForEach(opts, id: \.0) { Text($0.1).tag($0.0) }
    }.labelsHidden().fixedSize()
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage("theme") private var theme = "apple"
    @AppStorage("accent") private var accent = "red"
    @AppStorage("bg") private var bg = "black"
    @AppStorage("navStyle") private var navStyle = "sidebar"
    @AppStorage("topBarLabels") private var topBarLabels = "both"
    @AppStorage("homeLayout") private var homeLayout = "row"

    func swatches(_ list: [(String, Color)], selection: Binding<String>) -> some View {
        HStack(spacing: 14) {
            ForEach(list, id: \.0) { name, color in
                Button { selection.wrappedValue = name } label: {
                    Circle().fill(color).frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                        // selection ring sits outside the swatch so it also shows on the white one
                        .overlay(Circle().stroke(Color.white, lineWidth: 3).padding(-5)
                            .opacity(selection.wrappedValue == name ? 1 : 0))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }.buttonStyle(.plain).help(name.capitalized)
            }
        }
    }

    /// Background picker: labelled tiles, the selected one ringed in the accent color.
    func bgTiles(selection: Binding<String>) -> some View {
        HStack(spacing: 12) {
            ForEach(Theme.backgrounds, id: \.0) { name, color in
                let on = selection.wrappedValue == name
                Button { selection.wrappedValue = name } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 64, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(on ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(0.15)), lineWidth: on ? 3 : 1))
                        Text(name.capitalized).font(.caption).foregroundColor(on ? .primary : .secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    @AppStorage("showRecent") private var showRecent = true
    @AppStorage("posterShowTitle") private var showTitle = true
    @AppStorage("posterShowYear") private var showYear = true
    @AppStorage("posterLabelAlign") private var labelAlign = "center"

    var body: some View {
        PrefSection(title: "Appearance") {
            PrefRow(label: "Theme") { menuPicker($theme, [("apple", "Glass"), ("classic", "Classic")]) }
            PrefNote("Classic brings back the original Cove look. Settings always use this window.")
            PrefRow(label: "Accent color") { swatches(Theme.accents, selection: $accent) }
            PrefRow(label: "Background") { bgTiles(selection: $bg) }
        }
        .onChange(of: theme) { CoveApp.applyIcon() }
        PrefSection(title: "Navigation") {
            PrefRow(label: "Style") { menuPicker($navStyle, [("sidebar", "Sidebar"), ("topbar", "Top bar")]) }
            // One choice, not two switches: the bar can never end up with neither icons nor names
            PrefRow(label: "Top bar shows") {
                menuPicker($topBarLabels, [("both", "Icons and Names"), ("names", "Names"), ("icons", "Icons")])
            }.disabled(navStyle != "topbar")
            PrefNote("Top bar replaces the sidebar with a bar across the top. Settings are in the Cove menu (⌘,).")
            PrefRow(label: "Also show") { Toggle("Recently Added", isOn: $showRecent) }
            PrefNote("Home is always there. Libraries, Favorites and Now Playing are chosen in Libraries.")
        }
        PrefSection(title: "Posters", last: true) {
            PrefRow(label: "Show under poster") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Title", isOn: $showTitle)
                    Toggle("Year", isOn: $showYear)
                }
            }
            PrefRow(label: "Alignment") { menuPicker($labelAlign, [("center", "Centered"), ("left", "Left")]) }
                .disabled(!showTitle && !showYear)
        }
    }
}

// MARK: - Home

struct HomeSettings: View {
    @AppStorage("homeLayout") private var homeLayout = "row"
    @AppStorage("showUpNextRow") private var showUpNextRow = true

    var body: some View {
        PrefSection(title: "Layout") {
            PrefRow(label: "Sections show as") { menuPicker($homeLayout, [("row", "Rows"), ("grid", "Grid")]) }
            PrefNote("Rows scroll sideways; Grid shows every item of each section at once.")
        }
        PrefSection(title: "Rows", last: true) {
            PrefRow(label: "Watching") { Toggle("Up Next", isOn: $showUpNextRow) }
            PrefNote("The next episode of each show you're watching, under Continue Watching.")
            PrefNote("Which libraries get a row on Home, and what each row shows, is set per library in Libraries.")
        }
    }
}

// MARK: - About

/// Preferences that are app state rather than settings: saved servers and sign-ins, the device id, which
/// servers are Jellyfin (they contain server addresses) and one-time migration flags. Reset keeps them, and
/// settings files never contain them (both themes).
enum InternalPrefs {
    static let keys: Set<String> = ["server", "token", "uid", "servers", "did", "importedEmbyFlix",
                                    "imageCacheTokenFree", "imageCacheNoHeaders"]
    static let prefixes = ["jellyfin-"]
    static func contains(_ key: String) -> Bool { keys.contains(key) || prefixes.contains { key.hasPrefix($0) } }
}

/// The last section: app name, version, updates and source link, then Reset.
struct AboutSettings: View {
    @EnvironmentObject var emby: Emby
    @State private var cacheBytes = 0
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

    var body: some View {
        PrefSection(title: "Cove") {
            PrefRow(label: "Version") { Text("Cove " + AppVersion.label).textSelection(.enabled) }
            PrefRow(label: "Updates") { UpdateRow() }
            PrefRow(label: "Source") {
                Link("github.com/J0n4e/cove", destination: URL(string: "https://github.com/J0n4e/cove/releases")!)
            }
        }
        PrefSection(title: "Storage") {
            PrefRow(label: "Image cache") {
                HStack(spacing: 10) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                        .foregroundColor(.secondary).monospacedDigit()
                    Button("Clear") { ImageCache.shared.clear(); cacheBytes = ImageCache.shared.diskUsage }
                }
            }
            PrefNote("Posters and banners are saved on this Mac so they show instantly next time (up to 500 MB).")
        }
        .onAppear { cacheBytes = ImageCache.shared.diskUsage }
        PrefSection(title: "Backup") {
            PrefRow(label: "Settings file") {
                HStack(spacing: 10) {
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
    @AppStorage("showIncludedIn") private var showIncludedIn = true
    @AppStorage(NavOrder.key) private var navOrder = ""
    @AppStorage("showEpisodeDescription") private var showEpDesc = true
    @AppStorage("episodeLayoutTV") private var epLayout = "row"
    @AppStorage("seasonLayoutTV") private var seasonLayout = "row"
    @AppStorage("hoverPreviewEnabled") private var hoverOn = true
    @AppStorage("hoverPreviewDelay") private var hoverDelay = 0.7
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
                VStack(alignment: .leading, spacing: 6) {
                    libraryTable
                    Text("Drag to reorder. Click a library to change its options below.")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
        }
        if selectedLib == Self.favoritesId {
            PrefSection(title: "Favorites") {
                PrefRow(label: "View") { menuPicker($favLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
            }
        } else if selectedLib == NavOrder.nowPlaying {
            PrefSection(title: "Now Playing") { PrefNote("Now Playing shows what is playing on your server right now. Move it with its ≡ handle.") }
        } else if let i = emby.libs.firstIndex(where: { $0.id == selectedLib }) ?? (emby.libs.isEmpty ? nil : 0) {
            libraryOptions(i, emby.libs[i])
        }
        PrefSection(title: "Movie and show pages") {
            PrefRow(label: "More Like This") { menuPicker($similarLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
            PrefNote("At the bottom of a movie or show page. You can also switch it there.")
            PrefRow(label: "Included In") { Toggle("Show the collections a movie or show belongs to", isOn: $showIncludedIn) }
            PrefNote("Above More Like This. Click a collection to open it.")
        }
        PrefSection(title: "New libraries", last: true) {
            PrefRow(label: "Open as") {
                HStack(spacing: 10) {
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
            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            List {
                ForEach(tableRows, id: \.self) { id in
                    Group {
                        if NavOrder.sections.contains(id) { sectionLine(id, on: sel == id) }
                        else if let i = emby.libs.firstIndex(where: { $0.id == id }) { libraryLine(i, on: sel == id) }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Up to 7 rows show at once; more scroll inside the table, with a scrollbar
            .scrollDisabled(tableRows.count <= 7)
            .scrollIndicators(tableRows.count > 7 ? .visible : .hidden)
            .frame(height: CGFloat(min(tableRows.count, 7)) * 32 + 8)
        }
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
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
        .padding(.horizontal, 6).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? blue.opacity(0.85) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedLib = lib.id }
    }

    /// Favorites or Now Playing: not server libraries, so the Sidebar box is the section's show switch
    /// and there is no Home row.
    func sectionLine(_ id: String, on: Bool) -> some View {
        let fav = id == NavOrder.favorites
        let shown = fav ? $showFavorites : $showNowPlaying
        return HStack {
            dragHandle(id, on: on)
            Image(systemName: fav ? "heart" : "dot.radiowaves.left.and.right").foregroundColor(on ? .white : blue).frame(width: 20)
            Text(fav ? "Favorites" : "Now Playing").foregroundColor(shown.wrappedValue ? .primary : .secondary).lineLimit(1)
            Spacer()
            Toggle("", isOn: shown).labelsHidden().frame(width: 70)
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? blue.opacity(0.85) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedLib = id }
    }

    @State private var dragId: String?
    @State private var dragFrom = 0

    /// ≡ handle: drag it up or down and the row moves one place for every row height passed.
    /// (List's onMove and drag-and-drop never started a drag in this table on macOS.)
    func dragHandle(_ id: String, on: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(on || dragId == id ? .white : .secondary)
            .frame(width: 18, height: 28).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
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
                        withAnimation(.easeOut(duration: 0.15)) { applyOrder(r) }
                    }
                }
                .onEnded { _ in dragId = nil })
            .help("Drag to reorder")
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
                PrefRow(label: "Season layout") { menuPicker($seasonLayout, [("row", "Row"), ("grid", "Grid")]) }
                PrefRow(label: "Episode layout") { menuPicker($epLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
                PrefRow { Toggle("Show episode descriptions", isOn: $showEpDesc) }
            }
        }
    }

    func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 6) { Text(t).foregroundColor(.secondary).lineLimit(1).fixedSize(); c() }.fixedSize()
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
            .font(.caption).foregroundColor(.secondary)
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
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    PrefRow(label: "Text size") { menuPicker($subTextSize, PlayerView.sizes.map { ($0.0, $0.1) }) }
                    PrefRow(label: "Text color") { menuPicker($subColor, PlayerView.colors.map { ($0.0, $0.1) }) }
                    PrefRow(label: "Shadow") { menuPicker($subShadow, PlayerView.shadows) }
                    PrefRow(label: "Background") { menuPicker($subBg, PlayerView.bgs.map { ($0.0, $0.1) }) }
                    PrefRow(label: "Distance from bottom") {
                        menuPicker($subBottom, [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") })
                    }
                    PrefRow {
                        Button("Restore Defaults") {
                            subTextSize = "normal"; subColor = "white"; subShadow = "drop"; subBg = "none"; subBottom = 10
                        }
                    }
                }
                preview.frame(width: 240)
            }
        }
    }

    var preview: some View {
        let h: CGFloat = 135   // 16:9 with the 240 pt width, like a small video
        let fs = h * (PlayerView.sizes.first { $0.0 == subTextSize }?.2 ?? 0.045) * 1.6
        let color = PlayerView.colors.first { $0.0 == subColor }?.2 ?? .white
        return ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.4), Color(red: 0.75, green: 0.7, blue: 0.6)],
                           startPoint: .top, endPoint: .bottom)
            Text("This is how subtitles will look.")
                .font(.system(size: fs, weight: .medium))
                .foregroundColor(color)
                .modifier(SubShadow(style: subShadow, color: subColor == "black" ? .white : .black))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color.black.opacity(PlayerView.bgs.first { $0.0 == subBg }?.2 ?? 0))
                .cornerRadius(4)
                .padding(.bottom, h * subBottom / 100)
        }
        .frame(height: h).frame(maxWidth: .infinity).cornerRadius(8)
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
    @AppStorage("separatePlayer") private var separatePlayer = false
    @AppStorage("debugLog") private var debugLog = false
    @AppStorage("playerControls") private var controls = "theme"

    var body: some View {
        PrefSection(title: "Player") {
            PrefRow(label: "Controls look") {
                menuPicker($controls, [("theme", "Match theme"), ("glass", "Glass"), ("classic", "Classic")])
            }
            PrefRow(label: "Window") { Toggle("Open videos in a separate window", isOn: $separatePlayer) }
            PrefRow(label: "Clicking the video") { Toggle("Plays or pauses", isOn: $clickToPause) }
            PrefNote("With this off, clicking the video shows or hides the controls.")
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
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Play the next episode", isOn: $autoNext)
                    Toggle("Skip intros", isOn: $autoSkipIntro)
                }
            }
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
    @Environment(\.dismiss) var dismiss
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
                        .font(.callout).foregroundColor(.secondary).textSelection(.enabled)
                }
            }
            PrefRow {
                HStack(spacing: 10) {
                    Button("Sign Out", role: .destructive) { emby.logout(); dismiss() }
                }
            }
        }
        PrefSection(title: "Saved servers", last: true) {
            PrefRow(label: "Servers") {
                VStack(alignment: .leading, spacing: 0) {
                    if emby.servers.isEmpty { Text("No saved servers.").foregroundColor(.secondary).padding(12) }
                    ForEach(Array(emby.servers.enumerated()), id: \.element.id) { i, srv in
                        let current = srv.id == emby.server.lowercased()
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack").foregroundColor(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                // Click the name to rename it (helps tell servers apart)
                                TextField("Name", text: Binding(get: { srv.name }, set: { emby.renameServer(srv, $0) }))
                                    .textFieldStyle(.plain).fontWeight(.semibold).frame(maxWidth: 220)
                                HStack(spacing: 4) {
                                    ConnectionBadge(address: srv.url)
                                    Text((srv.user.isEmpty ? srv.url : "\(srv.user) · \(srv.url)") + " · " + emby.kindLabel(srv))
                                        .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                                }.font(.caption)
                            }
                            Spacer(minLength: 12)
                            if current {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(TintShapeStyle())
                                    .help("Connected")
                            } else if busy == srv.id {
                                Spinner().controlSize(.small)
                            } else {
                                Button("Connect") { connect(srv) }
                                Button { emby.removeServer(srv) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove this server and its sign-in")
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(i % 2 == 0 ? Color.white.opacity(0.04) : Color.clear)
                    }
                }
                .frame(width: 440)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            PrefRow { Button("Add Server…") { emby.switchServer(); dismiss() } }
            PrefNote("Click a server's name to rename it. Connect switches Cove to that server. Add Server opens the sign-in screen.")
        }
    }
}
