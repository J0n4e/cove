import SwiftUI

// Glass3D Cast UI: the device list (detail page popover and player panel), the Cast button on detail pages, and
// the mini remote shown at the bottom of the window while casting. Kept out of the big player/detail bodies
// (type-check limit): they include these views with one line each.

/// What the Cast menu lists (pure, unit-tested in Tests/CastMenuTests.swift): this Mac first, then the devices;
/// the tick on the device being cast to, or on this Mac when nothing is.
enum CastMenu {
    enum Target: Equatable { case mac, device(CastDevice) }
    struct Row: Identifiable, Equatable {
        let target: Target
        let name: String
        let icon: String
        let checked: Bool
        /// The model, shown as a tooltip only (the AirPlay menu has no subtitle line)
        let tip: String
        var id: String { if case .device(let d) = target { return d.id }; return "this-mac" }
    }
    /// Rows shown before the list scrolls.
    static let maxVisible = 6
    static let rowHeight: CGFloat = 28
    static let width: CGFloat = 240

    static func macName(_ localized: String?) -> String {
        guard let n = localized?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "This Mac" }
        return n
    }

    /// Audio-only Cast models (speakers, Nest Audio, Chromecast Audio) get a speaker, the rest a TV.
    static func icon(model: String) -> String {
        let m = model.lowercased()
        let audio = ["audio", "speaker", "nest mini", "home mini", "google home", "nest wifi point", "soundbar", "group"]
        return audio.contains { m.contains($0) } && !m.contains("hub") ? "hifispeaker" : "tv"
    }

    static func rows(devices: [CastDevice], castingTo: String?, macName: String) -> [Row] {
        let active = castingTo.flatMap { id in devices.contains { $0.id == id } ? id : nil }
        var out = [Row(target: .mac, name: macName, icon: "laptopcomputer", checked: castingTo == nil, tip: macName)]
        out += devices.map { d in
            Row(target: .device(d), name: d.name, icon: icon(model: d.model), checked: d.id == active, tip: d.model)
        }
        return out
    }

    enum Status: Equatable { case none, searching, notFound, error(String) }
    static func status(searching: Bool, devices: Int, error: String?) -> Status {
        if let error { return .error(error) }
        if devices > 0 { return .none }
        return searching ? .searching : .notFound
    }
    static let notFoundHint = "Make sure the TV or Chromecast is on and on the same network as this Mac."
}

/// The Cast menu: a compact dark menu like macOS's AirPlay menu (icon + name rows, tick on the active target, this
/// Mac first). Shown in a popover above the button that opens it.
struct CastDeviceList: View {
    @ObservedObject private var store = CastDeviceStore.shared
    @ObservedObject private var cast = CastSession.shared
    let pick: (CastDevice) -> Void
    /// "This Mac": stop casting and play here (nothing to do when not casting).
    let pickMac: () -> Void

    var body: some View {
        let rows = CastMenu.rows(devices: store.devices, castingTo: cast.isCasting ? cast.device?.id : nil,
                                 macName: CastMenu.macName(Host.current().localizedName))
        let status = CastMenu.status(searching: store.searching, devices: store.devices.count, error: store.browseError)
        let count = rows.count + (status == .none ? 0 : 1)
        Group {
            if count > CastMenu.maxVisible {
                ScrollView { content(rows, status) }
                    .frame(height: CGFloat(CastMenu.maxVisible) * CastMenu.rowHeight + 10)
                    .classicScrollBars()
            } else {
                content(rows, status)
            }
        }
        .frame(width: CastMenu.width)
        .background(CastMenuMaterial())
        .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onAppear { store.begin() }
        .onDisappear { store.end() }
    }

    func content(_ rows: [CastMenu.Row], _ status: CastMenu.Status) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                Button {
                    switch r.target {
                    case .mac: pickMac()
                    case .device(let d): pick(d)
                    }
                } label: { CastMenuRowLabel(row: r) }
                .buttonStyle(GlassButtonStyle(.row))
                .help(r.tip)
            }
            switch status {
            case .none: EmptyView()
            case .searching:
                greyRow { HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Looking for devices…").cvFont(13) } }
            case .notFound:
                greyRow { Text("No Cast devices found").cvFont(13) }.help(CastMenu.notFoundHint)
            case .error(let e):
                greyRow { Text(e).cvFont(12).lineLimit(2) }.help(e)
            }
        }
        .foregroundColor(.white)
        .padding(5)
    }

    func greyRow<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().foregroundColor(Glass3DTokens.Grey.secondary)
            .padding(.horizontal, 8).frame(minHeight: CastMenu.rowHeight).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CastMenuRowLabel: View {
    let row: CastMenu.Row
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.icon).cvFont(14).frame(width: 22)
            Text(row.name).cvFont(13).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if row.checked {
                Image(systemName: "checkmark").cvFont(9, weight: .bold)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.22)))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CastMenu.rowHeight)
        .contentShape(Rectangle())
    }
}

/// The menu's dark see-through background (the system menu material).
private struct CastMenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Opens the Cast menu above `content` (the popover closes on an outside click, Esc, or after a pick).
struct CastMenuPopover: ViewModifier {
    @Binding var open: Bool
    let pick: (CastDevice) -> Void
    let pickMac: () -> Void
    func body(content: Content) -> some View {
        content.popover(isPresented: $open, arrowEdge: .top) {
            CastDeviceList(pick: { d in open = false; pick(d) }, pickMac: { open = false; pickMac() })
                .environment(\.colorScheme, .dark)
        }
    }
}

extension CastSession {
    /// "This Mac" in the Cast menu: stop on the TV and carry on playing here from the TV's position.
    func handBackToMac(_ emby: Emby) {
        guard isCasting, let it = item else { return }
        let t = time, r = request, q = collection
        DebugLog.write("cast: back to this Mac at \(Int(t)) s")
        stop()
        emby.playing = PlayRequest(item: it, sourceId: r?.sourceId, audio: r?.audio, sub: r?.sub,
                                   start: t > 0 ? t : nil, collection: q)
    }
}

// MARK: - Detail page

/// The Cast pill next to Play/Resume: opens the device list; picking a device casts the page's item from its
/// resume point with the chosen audio and subtitles.
struct CastButton: View {
    let model: DetailModel
    @EnvironmentObject var emby: Emby
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("Cast", systemImage: "tv.and.mediabox").classicGlassPill(size: 44).glass3DRoundOutline()
        }
        .buttonStyle(HoverButton()).helpLabel(open ? "" : "Cast")
        .modifier(CastMenuPopover(open: $open, pick: { d in model.cast(to: d, emby: emby) },
                                  pickMac: { CastSession.shared.handBackToMac(emby) }))   // above the pill
    }
}

extension DetailModel {
    /// Casts what the Play/Resume buttons would play. A movie keeps the page's track choices; a series' next-up
    /// episode and a collection (collection mode, from the film in progress) choose them as local playback does.
    func cast(to device: CastDevice, emby: Emby) {
        if item.isBox {
            let films = kids
            let i = CollectionPlay.resumeIndex(films: films, position: { emby.resumeAt($0) }, played: { emby.isPlayed($0) }) ?? 0
            guard let q = CollectionPlay.queue(collection: item, films: films, start: i), let film = q.current else { return }
            let start = emby.resumeAt(film)
            CastSession.shared.cast(film, to: device, emby: emby, sourceId: nil, audio: nil, sub: nil, start: start,
                                    collection: q, pickTracks: true)
            return
        }
        guard let target = playTarget else { return }
        let start = resumePoint
        if item.isSeries {
            CastSession.shared.cast(target, to: device, emby: emby, sourceId: nil, audio: nil, sub: nil, start: start,
                                    pickTracks: true, wantedSub: UserDefaults.standard.string(forKey: "episodeSubLang"))
        } else {
            CastSession.shared.cast(target, to: device, emby: emby, sourceId: src?.Id,
                                    audio: audioIdx >= 0 ? audioIdx : nil, sub: subIdx >= 0 ? subIdx : nil, start: start)
        }
    }
}

// MARK: - Player

/// Opened by the Cast button in the player's bar; `pick` is set by the open player (CastPlayerPicker).
@MainActor
final class CastPickerState: ObservableObject {
    static let shared = CastPickerState()
    @Published var open = false
    var pick: ((CastDevice) -> Void)?
}

/// Gives the bar's Cast menu its action: picking a device stops the local playback and casts from the current
/// position with the same audio and subtitle. Draws nothing (the menu is a popover on the bar button).
struct CastPlayerPicker: View {
    let player: PlayerModel
    let req: PlayRequest
    let close: () -> Void
    @EnvironmentObject var emby: Emby

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .onAppear {
                CastPickerState.shared.pick = { d in
                    let at = player.now
                    let audio = player.audio, sub = player.sub, off = player.subOffset
                    DebugLog.write("cast: from the player at \(Int(at)) s (subtitle offset \(off) ms)")
                    close()
                    CastSession.shared.cast(req.item, to: d, emby: emby, sourceId: req.sourceId,
                                            audio: audio, sub: sub, start: at, collection: req.collection,
                                            subOffset: off)
                }
            }
            .onDisappear { CastPickerState.shared.open = false; CastPickerState.shared.pick = nil }
    }
}

/// The bar's Cast button with its menu above it (no tooltip while the menu is open).
struct Glass3DCastBarButton<L: View>: View {
    @ObservedObject private var state = CastPickerState.shared
    @EnvironmentObject var emby: Emby
    @ViewBuilder let label: (_ menuOpen: Bool) -> L
    var body: some View {
        label(state.open)
            .modifier(CastMenuPopover(open: $state.open, pick: { d in state.pick?(d) },
                                      pickMac: { CastSession.shared.handBackToMac(emby) }))
    }
}

// MARK: - Remote

/// "Casting to <device>": the mini remote at the bottom of the window while a cast runs, or the last error.
struct CastRemoteBar: View {
    @ObservedObject private var cast = CastSession.shared
    @EnvironmentObject var emby: Emby

    var body: some View {
        VStack {
            Spacer()
            if cast.isCasting, let item = cast.item {
                CastUpNextCard(cast: cast)   // Glass3DCastUpNext.swift
                CastRemoteContent(cast: cast, item: item)
                    .padding(.horizontal, 24).padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let e = cast.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text(e).cvFont(13, weight: .medium).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Button { cast.error = nil } label: { Image(systemName: "xmark").cvFont(12, weight: .bold) }
                        .buttonStyle(.plain).helpLabel("Dismiss")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: 560)
                .modifier(PanelSurface(classic: true))
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: e) {
                    try? await Task.sleep(for: .seconds(10))
                    if cast.error == e { cast.error = nil }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .coveGlassPopIn(value: cast.isCasting)
        .coveGlassPopIn(value: cast.upNext?.Id)
        .animation(.spring(duration: 0.35), value: cast.error)
        .task { cast.restoreIfNeeded(emby) }   // a cast still running after a relaunch
    }
}

private struct CastRemoteContent: View {
    @ObservedObject var cast: CastSession
    let item: Item
    @EnvironmentObject var emby: Emby
    @State private var dragging: Double?
    @State private var volume: Double = 1

    var body: some View {
        let t = dragging ?? cast.time
        let d = max(cast.duration, 1)
        HStack(spacing: 14) {
            poster
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).cvFont(14, weight: .semibold).lineLimit(1)
                        Text(status).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    controls
                }
                HStack(spacing: 8) {
                    Text(PlayerUIModel.fmt(t)).cvFont(11).monospacedDigit().frame(width: 52, alignment: .trailing)
                    GlassSlider(value: Binding(get: { dragging ?? cast.time }, set: { dragging = $0 }), range: 0...d) { editing in
                        if !editing, let v = dragging { cast.seek(to: v); dragging = nil }
                    }
                    Text(PlayerUIModel.fmt(cast.duration)).cvFont(11).monospacedDigit().frame(width: 52, alignment: .leading)
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 820)
        .modifier(PanelSurface(classic: true))
        .environment(\.colorScheme, .dark)
        .onAppear { volume = cast.volume }
        .onChange(of: cast.volume) { _, v in volume = v }
    }

    var title: String {
        if item.isEpisode, let s = item.SeriesName {
            return "\(s) · S\(item.ParentIndexNumber ?? 0):E\(item.IndexNumber ?? 0) \(item.Name)"
        }
        return item.Name
    }

    var status: String {
        let name = cast.device?.name ?? "TV"
        if cast.reconnecting { return "Reconnecting to \(name)…" }
        if let n = cast.notice { return n }
        let s = phaseStatus(name)
        return cast.collection != nil ? cast.position.map { "\(s) · \($0)" } ?? s : s
    }

    func phaseStatus(_ name: String) -> String {
        switch cast.phase {
        case .connecting: return "Connecting to \(name)…"
        case .loading: return "Starting on \(name)…"
        default: return cast.playerState == "BUFFERING" ? "Casting to \(name) · Loading…" : "Casting to \(name)"
        }
    }

    var poster: some View {
        AsyncImage(url: CastStream.imageURL(server: emby.server, token: emby.token, keyName: emby.keyName,
                                            id: item.posterId, kind: "Primary", width: 120)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color.white.opacity(0.08) }
        .frame(width: 40, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb, style: .continuous))
    }

    @ViewBuilder var controls: some View {
        HStack(spacing: 4) {
            icon("gobackward.10", "Back 10 seconds") { cast.skip(-10) }
            icon(cast.isPlaying ? "pause.fill" : "play.fill", cast.isPlaying ? "Pause" : "Play", size: 18) { cast.togglePlay() }
            icon("goforward.10", "Forward 10 seconds") { cast.skip(10) }
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").cvFont(12)
                .foregroundColor(Glass3DTokens.Grey.secondary).padding(.leading, 6)
            GlassSlider(value: $volume, range: 0...1) { editing in if !editing { cast.setVolume(volume) } }
                .frame(width: 80)
                .helpLabel("TV volume")
            trackMenus
            icon("xmark", "Stop casting") { cast.stop() }
        }
    }

    @ViewBuilder var trackMenus: some View {
        let audio = cast.streams.filter { $0.`Type` == "Audio" }
        let subs = cast.streams.filter { $0.`Type` == "Subtitle" }
        if audio.count > 1 {
            // Toggles: macOS menus show a real ✓ for the current track (a Label's icon wasn't shown, owner)
            Menu {
                ForEach(audio) { a in
                    Toggle(a.DisplayTitle ?? "Track \(a.Index)", isOn: Binding(get: { cast.audio == a.Index },
                                                                            set: { if $0 { cast.setAudio(a.Index) } }))
                }
            } label: { menuIcon("speaker.wave.2") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().helpLabel("Audio")
        }
        if !subs.isEmpty {
            Menu {
                Toggle("Off", isOn: Binding(get: { cast.sub == nil }, set: { if $0 { cast.setSub(nil) } }))
                ForEach(subs) { s in
                    Toggle(s.DisplayTitle ?? "Track \(s.Index)", isOn: Binding(get: { cast.sub == s.Index },
                                                                             set: { if $0 { cast.setSub(s.Index) } }))
                }
                if cast.sub != nil {
                    Divider()
                    if cast.subIsBurnedIn {
                        Text(CastSubOffset.burnedInHint)
                    } else {
                        Text("Offset: \(CastSubOffset.label(cast.subOffset))")
                        Button("Show 100 ms earlier") { cast.setSubOffset(cast.subOffset - CastSubOffset.step) }
                        Button("Show 100 ms later") { cast.setSubOffset(cast.subOffset + CastSubOffset.step) }
                        if cast.subOffset != 0 { Button("Reset offset") { cast.setSubOffset(0) } }
                    }
                }
            } label: { menuIcon("captions.bubble") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().helpLabel("Subtitles")
        }
    }

    func menuIcon(_ name: String) -> some View {
        Image(systemName: name).cvFont(15, weight: .medium).frame(width: 30, height: 30).contentShape(Rectangle())
    }

    func icon(_ name: String, _ help: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).cvFont(size, weight: .medium).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(HoverButton()).helpLabel(help)
    }
}
