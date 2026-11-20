import SwiftUI

// Glass3D Cast UI: the device list (detail page popover and player panel), the Cast button on detail pages, and
// the mini remote shown at the bottom of the window while casting. Kept out of the big player/detail bodies
// (type-check limit): they include these views with one line each.

/// The list of Cast devices: searching spinner, "No Cast devices found" after 5 s, the current device ticked.
struct CastDeviceList: View {
    @ObservedObject private var store = CastDeviceStore.shared
    @ObservedObject private var cast = CastSession.shared
    let pick: (CastDevice) -> Void
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        let accent = Theme.accent(accentName)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Cast to").cvFont(15, weight: .semibold)
                Spacer()
                if store.searching { ProgressView().controlSize(.small) }
            }
            .padding(.bottom, 4)
            if let e = store.browseError {
                Text(e).cvFont(12).foregroundColor(Glass3DTokens.Text.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.devices.isEmpty {
                if store.searching {
                    Text("Looking for Cast devices…").cvFont(12).foregroundColor(Glass3DTokens.Text.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Cast devices found").cvFont(13, weight: .semibold)
                        Text("Make sure the TV or Chromecast is on and on the same network as this Mac.")
                            .cvFont(11).foregroundColor(Glass3DTokens.Text.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(store.devices) { d in
                let current = cast.isCasting && cast.device?.id == d.id
                Button { pick(d) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tv").cvFont(15).frame(width: 22).foregroundColor(current ? accent : .white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).cvFont(13, weight: .medium).lineLimit(1).foregroundColor(current ? accent : .white)
                            Text(d.model).cvFont(11).lineLimit(1).foregroundColor(Glass3DTokens.Text.secondary)
                        }
                        Spacer(minLength: 8)
                        if current { Image(systemName: "checkmark").cvFont(12, weight: .semibold).foregroundColor(accent) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CastRowStyle())
            }
            if cast.isCasting {
                Divider().opacity(0.4)
                Button { cast.stop() } label: {
                    Label("Stop casting", systemImage: "stop.circle").cvFont(12, weight: .medium)
                        .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(CastRowStyle())
            }
        }
        .foregroundColor(.white)
        .padding(14)
        .frame(width: 290)
        .onAppear { store.begin() }
        .onDisappear { store.end() }
    }
}

private struct CastRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(c: configuration) }

    struct Row: View {
        let c: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            c.label
                .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row, style: .continuous)
                    .fill(Color.white.opacity(c.isPressed ? 0.16 : hover ? 0.09 : 0)))
                .onHover { hover = $0 }
        }
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
        .buttonStyle(HoverButton()).helpLabel("Cast")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            CastDeviceList { d in open = false; model.cast(to: d, emby: emby) }
                .background(Color.black.opacity(0.35))
                .environment(\.colorScheme, .dark)
        }
    }
}

extension DetailModel {
    /// Casts what the Play/Resume buttons would play, with the page's track choices.
    func cast(to device: CastDevice, emby: Emby) {
        guard let target = playTarget else { return }
        let start = resumePoint
        if item.isSeries {   // the next episode: its own tracks are unknown here, the server picks the defaults
            CastSession.shared.cast(target, to: device, emby: emby, sourceId: nil, audio: nil, sub: nil, start: start)
        } else {
            CastSession.shared.cast(target, to: device, emby: emby, sourceId: src?.Id,
                                    audio: audioIdx >= 0 ? audioIdx : nil, sub: subIdx >= 0 ? subIdx : nil, start: start)
        }
    }
}

// MARK: - Player

/// Opened by the Cast button in the player's bar.
@MainActor
final class CastPickerState: ObservableObject {
    static let shared = CastPickerState()
    @Published var open = false
}

/// The player's Cast panel (bottom right, above the bar). Picking a device stops the local playback and casts
/// from the current position with the same audio and subtitle.
struct CastPlayerPicker: View {
    let player: PlayerModel
    let req: PlayRequest
    let close: () -> Void
    @EnvironmentObject var emby: Emby
    @ObservedObject private var state = CastPickerState.shared

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if state.open {
                    CastDeviceList { d in
                        let at = player.now
                        let audio = player.audio, sub = player.sub
                        state.open = false
                        DebugLog.write("cast: from the player at \(Int(at)) s")
                        close()
                        CastSession.shared.cast(req.item, to: d, emby: emby, sourceId: req.sourceId,
                                                audio: audio, sub: sub, start: at)
                    }
                    .modifier(PanelSurface(classic: true))
                    .environment(\.colorScheme, .dark)
                    .padding(.trailing, 24).padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .coveGlassPopIn(value: state.open)
        .onDisappear { state.open = false }
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
        .animation(.spring(duration: 0.35), value: cast.error)
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
                        Text(status).cvFont(11).foregroundColor(Glass3DTokens.Text.secondary).lineLimit(1)
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
                .foregroundColor(Glass3DTokens.Text.secondary).padding(.leading, 6)
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
            Menu {
                ForEach(audio) { a in
                    Button { cast.setAudio(a.Index) } label: {
                        let name = a.DisplayTitle ?? "Track \(a.Index)"
                        if cast.audio == a.Index { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: { menuIcon("speaker.wave.2") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().helpLabel("Audio")
        }
        if !subs.isEmpty {
            Menu {
                Button { cast.setSub(nil) } label: {
                    if cast.sub == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach(subs) { s in
                    Button { cast.setSub(s.Index) } label: {
                        let name = s.DisplayTitle ?? "Track \(s.Index)"
                        if cast.sub == s.Index { Label(name, systemImage: "checkmark") } else { Text(name) }
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
