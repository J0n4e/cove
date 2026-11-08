// Classic theme: the original Cove screens from v1.9.2 (main), used when Settings → General → Theme is Classic.
// Names carry a "Classic" prefix so they live next to the Apple TV screens.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// App settings: one window with a sidebar of sections.
/// Values live in UserDefaults (the same keys the rest of the app reads).
struct ClassicSettingsView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBG) var bg
    var onDone: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", libraries = "Libraries",
             subtitles = "Subtitles", playback = "Playback", servers = "Servers", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "paintpalette"
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
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button { emby.saveLibs(); onDone(); dismiss() } label: { Text("Done").classicOnAccent() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Section.allCases) { s in
                        Button { section = s } label: {
                            Label(s.rawValue, systemImage: s.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(section == s ? Color.white.opacity(0.14) : Color.clear)
                                .cornerRadius(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 190).padding(10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch section {
                        case .general: ClassicGeneralSettings()
                        case .libraries: ClassicLibrariesSettings()
                        case .subtitles: ClassicSubtitleSettings()
                        case .playback: ClassicPlaybackSettings()
                        case .servers: ClassicServerSettings()
                        case .about: ClassicAboutSettings()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
        }
        .frame(width: 860, height: 580)
        .background(bg)
        // Esc closes Settings and keeps the changes, like OK / Done
        .background(Button("") { emby.saveLibs(); onDone(); dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0))
    }
}

// MARK: - Building blocks

struct ClassicSettingsGroup<C: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06)).cornerRadius(8)
            if let note { Text(note).font(.caption).foregroundColor(.secondary) }
        }
    }
}

struct ClassicSettingRow<C: View>: View {
    let label: String
    @ViewBuilder var control: C
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            control
        }
    }
}

func classicSegmented<T: Hashable>(_ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
    Picker("", selection: sel) {
        ForEach(opts, id: \.0) { Text($0.1).tag($0.0) }
    }.pickerStyle(.segmented).labelsHidden().fixedSize()
}

func classicMenuPicker<T: Hashable>(_ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
    Picker("", selection: sel) {
        ForEach(opts, id: \.0) { Text($0.1).tag($0.0) }
    }.labelsHidden().fixedSize()
}

// MARK: - General

struct ClassicGeneralSettings: View {
    @AppStorage("theme") private var theme = "apple"
    @AppStorage("accent") private var accent = "red"
    @AppStorage("bg") private var bg = "black"
    @AppStorage("navStyle") private var navStyle = "sidebar"

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

    var body: some View {
        ClassicSettingsGroup(title: "Appearance") {
            SettingRow(label: "Theme") {
                Picker("", selection: $theme) {
                    Text("Glass").tag("apple")
                    Text("Classic").tag("classic")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                .onChange(of: theme) { CoveApp.applyIcon() }
            }
            Text("Accent color").foregroundColor(.secondary)
            swatches(Theme.accents, selection: $accent)
            Text("Background").foregroundColor(.secondary).padding(.top, 4)
            bgTiles(selection: $bg)
            ClassicSettingRow(label: "Navigation") {
                Picker("", selection: $navStyle) {
                    Text("Sidebar").tag("sidebar")
                    Text("Top bar").tag("topbar")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }.padding(.top, 4)
            Text("Top bar replaces the sidebar with a bar across the top (Home, Favorites, libraries, search and Settings).")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - About

/// The last section: app name, version, updates and source link, then Reset.
struct ClassicAboutSettings: View {
    @EnvironmentObject var emby: Emby
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
        ClassicSettingsGroup(title: "About") {
            ClassicSettingRow(label: "App") { Text("Cove").foregroundColor(.secondary) }
            ClassicSettingRow(label: "Version") {
                Text(AppVersion.label)
                    .foregroundColor(.secondary).textSelection(.enabled)
            }
            ClassicSettingRow(label: "Updates") { UpdateRow() }
            ClassicSettingRow(label: "Source & releases") {
                Link("github.com/J0n4e/cove", destination: URL(string: "https://github.com/J0n4e/cove/releases")!)
            }
        }
        ClassicSettingsGroup(title: "Save and load settings",
                      note: "Saves every setting to a file you choose, and loads them back later or on another Mac. Your servers and sign-in are not included.") {
            HStack(spacing: 10) {
                Button("Save settings…") { saveSettings() }
                Button("Load settings…") { loadSettings() }
            }
        }
        .alert(backupMessage ?? "", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        ClassicSettingsGroup(title: "Reset",
                      note: "Puts every setting back to its default: colors, navigation, layouts, filters, hover preview, subtitles, player and window position. Your servers and sign-in are kept.") {
            Button("Reset all settings to default…", role: .destructive) { confirmReset = true }
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
struct ClassicLibraryDefaults {
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

struct ClassicLibrariesSettings: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("favoritesLayout") private var favLayout = "row"
    @AppStorage("defaultLibraryLayout") private var defaultLayout = "grid"
    @AppStorage("posterShowTitle") private var showTitle = true
    @AppStorage("posterShowYear") private var showYear = true
    @AppStorage("posterLabelAlign") private var labelAlign = "center"
    @AppStorage("showEpisodeDescription") private var showEpDesc = true
    @AppStorage("episodeLayout") private var epLayout = "list"
    @AppStorage("hoverPreviewEnabled") private var hoverOn = true
    @AppStorage("hoverPreviewDelay") private var hoverDelay = 0.7
    @AppStorage("hoverZoomEnabled") private var hoverZoom = true
    @AppStorage("hoverZoomDuration") private var hoverZoomDur = 0.3
    @AppStorage("hoverZoomStyle") private var hoverZoomStyle = "spring"
    @State private var tick = 0   // redraw after writing per-library defaults

    func bind(_ lib: LibPref, _ k: String, _ def: String) -> Binding<String> {
        let d = ClassicLibraryDefaults(id: lib.id)
        return Binding(get: { _ = tick; return d.get(k, def) }, set: { d.set(k, $0); tick += 1 })
    }

    var body: some View {
        ClassicSettingsGroup(title: "Default view for new libraries") {
            ClassicSettingRow(label: "Layout") { classicSegmented($defaultLayout, [("grid", "Grid"), ("list", "List")]) }
        }
        ClassicSettingsGroup(title: "Poster labels") {
            Toggle("Show title under posters", isOn: $showTitle)
            Toggle("Show year under posters", isOn: $showYear)
            ClassicSettingRow(label: "Alignment") { classicSegmented($labelAlign, [("center", "Centered"), ("left", "Left")]) }
                .disabled(!showTitle && !showYear)
        }
        ClassicSettingsGroup(title: "Hover preview") {
            Toggle("Show the preview card when hovering a poster", isOn: $hoverOn)
            ClassicSettingRow(label: "Delay before it opens") {
                HStack(spacing: 10) {
                    Slider(value: $hoverDelay, in: 0.1...2.0, step: 0.1).frame(width: 200)
                    Text(String(format: "%.1f s", hoverDelay)).monospacedDigit().foregroundColor(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }.disabled(!hoverOn)
            Toggle("Zoom animation (zoom out when it opens, zoom in when it closes)", isOn: $hoverZoom).disabled(!hoverOn)
            ClassicSettingRow(label: "Animation style") {
                Picker("", selection: $hoverZoomStyle) {
                    Text("Smooth").tag("smooth")
                    Text("Spring").tag("spring")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }.disabled(!hoverOn || !hoverZoom)
            ClassicSettingRow(label: "Zoom duration") {
                HStack(spacing: 10) {
                    Slider(value: $hoverZoomDur, in: 0.1...1.0, step: 0.05).frame(width: 200)
                    Text(String(format: "%.2f s", hoverZoomDur)).monospacedDigit().foregroundColor(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }.disabled(!hoverOn || !hoverZoom)
        }
        ClassicSettingsGroup(title: "Libraries",
                      note: "Show puts a library in the sidebar; Home row adds it to the home screen. Use the arrows to reorder.") {
            // Favorites first: not a server library, so only its view can change
            HStack(spacing: 10) {
                Label("Favorites", systemImage: "heart").frame(width: 200, alignment: .leading)
                labeled("View") { classicSegmented($favLayout, [("row", "Row"), ("grid", "Grid"), ("list", "List")]) }
            }.font(.callout)
            Divider()
            if emby.libs.isEmpty { Text("No libraries loaded yet.").foregroundColor(.secondary) }
            ForEach(Array(emby.libs.enumerated()), id: \.element.id) { i, lib in
                libraryCard(i, lib)
                if i < emby.libs.count - 1 { Divider() }
            }
        }
        Button("Apply grid/list default to all libraries") {
            for lib in emby.libs { ClassicLibraryDefaults(id: lib.id).set("layout", defaultLayout) }
            tick += 1
        }
    }

    func libraryCard(_ i: Int, _ lib: LibPref) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(lib.name, text: $emby.libs[i].title).textFieldStyle(.roundedBorder).frame(width: 200)
                Toggle("Show", isOn: $emby.libs[i].visible)
                Toggle("Home row", isOn: $emby.libs[i].onHome).disabled(!lib.visible)
                Spacer()
                Button { emby.libs.swapAt(i, i - 1) } label: { Image(systemName: "arrow.up") }
                    .disabled(i == 0).buttonStyle(.borderless)
                Button { emby.libs.swapAt(i, i + 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(i == emby.libs.count - 1).buttonStyle(.borderless)
            }
            ClassicFlowLayout(hSpacing: 18, vSpacing: 8) {
                labeled("View") { classicSegmented(bind(lib, "layout", defaultLayout), [("grid", "Grid"), ("list", "List")]) }
                labeled("Sort") {
                    classicMenuPicker(bind(lib, "sort", "name"),
                               [("name", "Name"), ("latest", "Recently Added"), ("release", "Release Date"), ("top", "Rating")])
                }
                labeled("Show") {
                    classicMenuPicker(bind(lib, "watch", "all"), [("all", "All"), ("unwatched", "Unwatched"), ("watched", "Watched")])
                }
                labeled("Home row") {
                    classicMenuPicker($emby.libs[i].style, [("latest", "Latest"), ("top", "Top Rated"), ("random", "Random"), ("az", "A–Z")])
                }.disabled(!lib.onHome || !lib.visible)
                // Episode options apply to every TV library, so they show with any of them
                if lib.kind == "tvshows" {
                    labeled("Episodes") { classicSegmented($epLayout, [("grid", "Grid"), ("list", "List")]) }
                    Toggle("Episode descriptions", isOn: $showEpDesc)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 6) { Text(t).foregroundColor(.secondary).lineLimit(1).fixedSize(); c() }.fixedSize()
    }
}

// MARK: - Series & episodes

struct ClassicSeriesSettings: View {
    @AppStorage("episodeLayout") private var epLayout = "list"
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
        ClassicSettingsGroup(title: "Episodes") {
            ClassicSettingRow(label: "Episode layout") { classicSegmented($epLayout, [("grid", "Grid"), ("list", "List")]) }
            ClassicSettingRow(label: "Subtitle language") { classicMenuPicker($epSubLang, langOptions) }
        }
        Text("The subtitle language is used for every episode you play from a series page; it's the same setting as the Subtitles menu next to the episode list.")
            .font(.caption).foregroundColor(.secondary)
    }
}

// MARK: - Subtitles

struct ClassicSubtitleSettings: View {
    @AppStorage("subTextSize") private var subTextSize = "normal"
    @AppStorage("subColor") private var subColor = "white"
    @AppStorage("subShadowStyle") private var subShadow = "drop"
    @AppStorage("subBg") private var subBg = "none"
    @AppStorage("subBottom") private var subBottom = 10.0
    @AppStorage("subAlways") private var subAlways = false
    @AppStorage("subLang") private var subLang = "english"

    var body: some View {
        ClassicSettingsGroup(title: "Subtitle language",
                      note: "When on, every movie and episode starts with subtitles in this language if it has them (text subtitles such as SRT are preferred). Choosing Off for a movie, or in the player, still turns them off.") {
            Toggle("Always load preferred subtitle language", isOn: $subAlways)
            ClassicSettingRow(label: "Preferred language") {
                classicMenuPicker($subLang, ClassicSeriesSettings.languages.map { ($0.lowercased(), $0) })
            }.disabled(!subAlways)
        }
        ClassicSettingsGroup(title: "Subtitle appearance") {
            ClassicSettingRow(label: "Text size") { classicMenuPicker($subTextSize, ClassicPlayerView.sizes.map { ($0.0, $0.1) }) }
            ClassicSettingRow(label: "Text color") { classicMenuPicker($subColor, ClassicPlayerView.colors.map { ($0.0, $0.1) }) }
            ClassicSettingRow(label: "Drop shadow") { classicMenuPicker($subShadow, ClassicPlayerView.shadows) }
            ClassicSettingRow(label: "Background") { classicMenuPicker($subBg, ClassicPlayerView.bgs.map { ($0.0, $0.1) }) }
            ClassicSettingRow(label: "Bottom edge position") {
                classicMenuPicker($subBottom, [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") })
            }
        }
        preview
        Button("Reset to Default") {
            subTextSize = "normal"; subColor = "white"; subShadow = "drop"; subBg = "none"; subBottom = 10
        }
    }

    var preview: some View {
        let h: CGFloat = 220
        let fs = h * (ClassicPlayerView.sizes.first { $0.0 == subTextSize }?.2 ?? 0.045) * 1.6
        let color = ClassicPlayerView.colors.first { $0.0 == subColor }?.2 ?? .white
        return ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.4), Color(red: 0.75, green: 0.7, blue: 0.6)],
                           startPoint: .top, endPoint: .bottom)
            Text("This is how subtitles will look.")
                .font(.system(size: fs, weight: .medium))
                .foregroundColor(color)
                .modifier(ClassicSubShadow(style: subShadow, color: subColor == "black" ? .white : .black))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color.black.opacity(ClassicPlayerView.bgs.first { $0.0 == subBg }?.2 ?? 0))
                .cornerRadius(4)
                .padding(.bottom, h * subBottom / 100)
        }
        .frame(height: h).frame(maxWidth: .infinity).cornerRadius(8)
    }
}

// MARK: - Playback

struct ClassicPlaybackSettings: View {
    @AppStorage("defaultQuality") private var quality = 0
    @AppStorage("defaultSpeed") private var speed = 1.0
    @AppStorage("autoNext") private var autoNext = true
    @AppStorage("autoSkipIntro") private var autoSkipIntro = true
    @AppStorage("skipSeconds") private var skip = 10
    @AppStorage("clickToPause") private var clickToPause = true
    @AppStorage("debugLog") private var debugLog = false

    var body: some View {
        ClassicSettingsGroup(title: "Playback") {
            ClassicSettingRow(label: "Default quality") {
                classicMenuPicker($quality, [(0, "Original"), (8_000_000, "1080p · 8 Mbps"), (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")])
            }
            ClassicSettingRow(label: "Default speed") {
                classicMenuPicker($speed, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map { ($0, $0 == 1 ? "Normal" : String(format: "%gx", $0)) })
            }
            ClassicSettingRow(label: "Skip back / forward") {
                classicSegmented($skip, [(5, "5 s"), (10, "10 s"), (15, "15 s"), (30, "30 s")])
            }
            Toggle("Play next episode automatically", isOn: $autoNext)
            Toggle("Skip intros automatically", isOn: $autoSkipIntro)
            Toggle("Click on the video to play / pause", isOn: $clickToPause)
            Text("When off, clicking the video shows or hides the controls.").font(.caption).foregroundColor(.secondary)
            Toggle("Write a player debug log", isOn: $debugLog)
            Text("Saved to ~/Library/Logs/Cove.log (kept under about 1 MB). Leave it off unless you're chasing a playback problem.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Servers

struct ClassicServerSettings: View {
    @EnvironmentObject var emby: Emby

    var body: some View {
        ClassicSettingsGroup(title: "Account") {
            if let user = emby.currentServer?.user, !user.isEmpty {
                ClassicSettingRow(label: "User") { Text(user).foregroundColor(.secondary).textSelection(.enabled) }
            }
            ClassicSettingRow(label: "Signed in to \(emby.currentServerName)") {
                Button("Sign Out", role: .destructive) { emby.logout() }
            }
        }
        ClassicSettingsGroup(title: "Saved servers",
                      note: "Removing a server forgets its saved sign-in. You can add servers from the sign-in screen (Switch Server).") {
            if emby.servers.isEmpty { Text("No saved servers.").foregroundColor(.secondary) }
            ForEach(emby.servers) { s in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            ConnectionBadge(address: s.url).font(.caption)
                            Text(s.name).bold()
                            if s.id == emby.server.lowercased() {
                                Text("Current").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.6)))
                            }
                        }
                        Text(s.user.isEmpty ? s.url : "\(s.user) · \(s.url)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(s.token != nil ? "Signed in" : "Signed out").font(.caption).foregroundColor(.secondary)
                    Button("Remove", role: .destructive) { emby.removeServer(s) }
                        .disabled(s.id == emby.server.lowercased())
                        .help(s.id == emby.server.lowercased() ? "Switch to another server first" : "")
                }
            }
        }
    }
}
