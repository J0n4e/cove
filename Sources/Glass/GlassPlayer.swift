import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// "‹ Back" pill button used on detail pages and in the player.
struct BackPill: View {
    var compact = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: "chevron.left").coveFont(size: compact ? 14 : 18, weight: .bold)
                Text("Back").coveFont(size: compact ? 14 : 16, weight: .semibold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 5 : 10)
            .background(Capsule().fill(Color.black.opacity(hover ? 0.85 : 0.6)))
            .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.7 : 0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButton())
        .focusEffectDisabled()   // no blue macOS focus ring when a page opens
        .scrollHover($hover)
        .animation(.easeOut(duration: 0.12), value: hover)
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// The same look for the player's icon menus (subtitles, quality), which can't take a button style.
struct HoverBacking: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.16 : 0)))
            .padding(-4)
            .brightness(hover ? 0.12 : 0)
            .scaleEffect(hover ? 1.07 : 1)
            .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 8, y: 3)
            .scrollHover($hover)
            .handCursor()
            .animation(.easeOut(duration: 0.15), value: hover)
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
        // Weak: a theme switch mid-video must not keep the old player alive through these handlers
        c.togglePlayPauseCommand.addTarget { [weak m] _ in m?.togglePlay(); return .success }
        c.playCommand.addTarget { [weak m] _ in if let m, !m.playing { m.togglePlay() }; return .success }
        c.pauseCommand.addTarget { [weak m] _ in if let m, m.playing { m.togglePlay() }; return .success }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        c.skipForwardCommand.addTarget { [weak m] _ in m?.skip(skip); return .success }
        c.skipBackwardCommand.addTarget { [weak m] _ in m?.skip(-skip); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak m] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            m?.seek(to: e.positionTime); return .success
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

/// The player with the controls chosen in Settings → Playback → Player controls: the Glass player, the Classic
/// player, or (default) the one that belongs to the current theme. Both players only need `emby` and the request.
struct ChosenPlayerView: View {
    let req: PlayRequest
    let theme: String   // the theme this player opens in: "apple" (Glass) or "classic"
    @AppStorage("playerControls") private var controls = "theme"
    var body: some View {
        let style = controls == "theme" ? (theme == "apple" ? "glass" : "classic") : controls
        if let t = req.trailer { TrailerPlayerView(link: t) }
        else if style == "classic" { ClassicPlayerView(req: req) }
        else { PlayerView(req: req).environment(\.classicGlass, false) }   // the Glass player keeps its own look in every theme
    }
}

/// Contents of the separate player window. Closing the window (red button) stops playback.
struct PlayerWindow: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let req = emby.playing { ChosenPlayerView(req: req, theme: "apple").id(req.id) }
        }
        .ignoresSafeArea()
        .overlay { RemoteMessageToast() }   // SyncPlay phase 4: Dashboard → Send message (separate player window)
        .tipLayer()
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
    @StateObject private var ui = PlayerUIModel(style: .glass)
    /// The playback engine (owned by `ui`, which passes its changes on).
    private var model: PlayerModel { ui.player }
    let req: PlayRequest

    typealias Panel = PlayerUIModel.Panel
    @FocusState private var focused: Bool

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
    // Remembered across episodes (each episode gets a fresh PlayerView), so closing the player still leaves full screen
    var enteredFullScreen: Bool {
        get { PlaybackFlag.shared.enteredFullScreen }
        nonmutating set { PlaybackFlag.shared.enteredFullScreen = newValue }
    }

    // Subtitle appearance choices (shared; Settings reads them from here too)
    static let sizes = PlayerUIModel.sizes
    static let colors = PlayerUIModel.colors
    static let shadows = PlayerUIModel.shadows
    static let bgs = PlayerUIModel.bgs

    var item: Item { req.item }
    var prevEp: Item? { ui.prevEp(item) }
    var nextEp: Item? { ui.nextEp(item) }

    /// The window this player is in (the separate player window is not always the key or main window)
    var window: NSWindow? { ui.playerWin.window ?? NSApp.keyWindow ?? NSApp.mainWindow }

    /// Height of the window's title bar while windowed (0 in full screen, where there is none).
    /// The player has its own window with no title bar, so the video fills it all (the window buttons float on top).
    var titleBarHeight: CGFloat {
        guard !separate, !ui.isFullScreen, let w = window, !w.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }
    var separate: Bool { UserDefaults.standard.bool(forKey: "separatePlayer") }
    /// Room for the floating window buttons above the top controls (separate window only, none in full screen).
    var windowButtonsGap: CGFloat { separate && !ui.isFullScreen ? 22 : 0 }
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
        let visible = h > 0 && (ui.showUI || ui.panel != nil)
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
        .animation(.easeOut(duration: 0.2), value: ui.showUI)
    }

    /// Full screen for the video; leaving the player restores the window if the player made it full screen.
    func toggleFullScreen() {
        // One toggle at a time: a second one during macOS's animation (a held or double-pressed F) left the
        // window stuck, ignoring every later toggle
        guard !ui.fsBusy else { return }
        guard let w = window else { return }
        ui.fsBusy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ui.fsBusy = false }   // in case no notification comes
        w.collectionBehavior.insert(.fullScreenPrimary)   // the separate player window isn't full-screen capable by default
        let on = w.styleMask.contains(.fullScreen)
        if !on { enteredFullScreen = true }
        // After the key press has been handled: called from inside the key event, leaving full screen often
        // didn't start at all
        DispatchQueue.main.async { w.toggleFullScreen(nil) }
        ui.isFullScreen = !on
    }

    /// Back button: in full screen the first click leaves full screen (the video keeps playing),
    /// the next click stops playback and returns to the app.
    func back() {
        if ui.isFullScreen { toggleFullScreen() } else { close() }
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
        PlayerUIModel.quietNextStart = true   // the next episode opens without the controls
        if emby.syncPlay.group.pick(ep.Id) { return }   // SyncPlay phase 4: in a group, everyone switches
        guard !ui.switching else { return }
        ui.switching = true
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
            model.stop()       // marks a finished episode watched (see close())
            let q = UserDefaults.standard.integer(forKey: "defaultQuality")
            emby.playing = PlayRequest(item: ep, sourceId: src?.Id, sub: pick, maxBitrate: q > 0 ? q : nil,
                                       start: emby.resumeAt(ep), collection: ui.queue(for: ep))
        }
    }

    /// SyncPlay phase 4: Jellyfin Dashboard remote control acts on this player (RemoteControl.swift).
    func attachRemote() {
        PlayerRemoteHandle.attach(model, emby: emby, close: { close() }, next: { if let n = nextEp { play(n) } },
                                  previous: { if let p = prevEp { play(p) } else { model.seek(to: 0) } },
                                  fullScreen: { toggleFullScreen() })
    }

    /// Shows the controls; they hide again after a while (see PlayerUIModel.poke).
    func poke() { ui.poke() }

    func fmt(_ t: Double) -> String { PlayerUIModel.fmt(t) }

    var endClock: String { ui.endClock }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let p = model.player {
                    AVPlayerViewRep(player: p, onLayer: model.attach).ignoresSafeArea().padding(.top, titleBarHeight)
                }
                else if model.error.isEmpty { Spinner(inPlayer: true).controlSize(.large) }
                if model.pipActive { pipPlaceholder }

                subtitleLayer(geo.size).animation(.easeOut(duration: 0.2), value: ui.showUI)

                if ui.showUI || ui.panel != nil {
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

                if model.player != nil, !model.isReady, model.error.isEmpty { Spinner() }

                if !model.error.isEmpty {
                    VStack(spacing: 12) {
                        Text(model.error).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button("Retry with transcoding") { Task { await model.retryTranscoded(emby) } }
                    }
                }

                if ui.showInfo { infoOverlay }
                cornerCards
                panelLayer
                SyncPlayToast(group: emby.syncPlay.group, classic: false)
                // Title bar strip, above every layer (the controls' dark gradient used to darken it)
                VStack(spacing: 0) {
                    PlayerView.titleBarGray.frame(height: titleBarHeight)
                    Spacer(minLength: 0)
                }.ignoresSafeArea().allowsHitTesting(false)
                if Self.titleBarBackPill { titleBarBack }
            }
            .contentShape(Rectangle())
            .onTapGesture { ui.tap(clickToPause: clickToPause) }
        }
        .foregroundColor(.white)
        .onContinuousHover { ui.pointer($0) }   // real mouse moves only (not a card appearing)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) {
            if showUpNext, let n = nextEp { play(n); return .handled }   // next episode: no controls
            model.togglePlay()
            poke(); return .handled
        }
        .onKeyPress(.return) {
            if showUpNext, let n = nextEp { play(n); return .handled }
            return .ignored
        }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress("i") { ui.showInfo.toggle(); return .handled }
        // No screen saver / display sleep while a video is playing (windowed or full screen)
        .onChange(of: model.playing) { _, on in KeepAwake.set(on, owner: model) }
        .onDisappear { KeepAwake.set(false, owner: model) }
        .onKeyPress("p") { model.togglePiP(); return .handled }
        .onKeyPress("e") {
            guard ui.hasEpisodeList(item) else { return .ignored }
            ui.toggleEpisodes(item)
            return .handled
        }
        // Keep keyboard focus on the player (Space must always reach it, e.g. for "Play now")
        .onChange(of: showUpNext) { _, on in if on { focused = true } }
        .onChange(of: ui.panel) { _, p in if p == nil { focused = true } }
        .onChange(of: focused) { _, f in if !f && ui.panel == nil { DispatchQueue.main.async { focused = true } } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
        .onKeyPress("c") { if !model.chapterList.isEmpty { ui.toggleChapters() }; return .handled }
        .task(id: ui.showInfo) {
            while ui.showInfo && !Task.isCancelled {
                ui.infoLines = await model.playbackInfo()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if ui.playerWin.owns(n.object) { ui.fsBusy = false }
            guard ui.playerWin.owns(n.object) else { return }
            ui.isFullScreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            if ui.playerWin.owns(n.object) { ui.fsBusy = false }
            guard ui.playerWin.owns(n.object) else { return }
            ui.isFullScreen = false
            // Take the keyboard back after leaving full screen, so Esc / Space / F keep working
            (n.object as? NSWindow)?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onKeyPress(.leftArrow) { model.skip(PlayerUIModel.seekDelta(.left, skipSeconds: skipSecs)); poke(); return .handled }
        .onKeyPress(.rightArrow) { model.skip(PlayerUIModel.seekDelta(.right, skipSeconds: skipSecs)); poke(); return .handled }
        // Esc: close a panel, else leave full screen (video keeps playing), else close the player.
        // Caught at the app level: AppKit sometimes swallows Esc before SwiftUI's key handlers see it
        // (after full screen, and in the separate player window). Only in the player's own window: Esc in the
        // main window must not stop a video playing in the separate one.
        .background(WindowReader { ui.playerWin.window = $0 })
        .onAppear { ui.installKeyMonitor(toggleFullScreen: { toggleFullScreen() }, close: { close() }) }
        .onDisappear { ui.removeKeyMonitor() }
        .task {
            focused = true
            ui.isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
            ui.adopt(req)   // Play collection: collection mode (CollectionPlay.swift)
            if PlayerUIModel.takeQuietStart() { ui.startQuiet() } else { poke() }   // next episode: no controls
            await ui.loadEpisodes(emby, item)
        }
        .task { await model.start(emby, req) }
        .onDisappear { model.stop(); if emby.playing == nil { RemoteControls.detach() } }   // keep keys when switching episodes
        // Media keys / Control Center
        .onAppear { RemoteControls.attach(model, skip: Double(skipSecs)); attachRemote() }
        .onChange(of: model.playing) { RemoteControls.update(item, model) }
        .onChange(of: model.duration) { RemoteControls.update(item, model) }
        .onChange(of: Int(model.time / 10)) { RemoteControls.update(item, model) }
        // Closing the player window (red button or ⌘W) stops playback, like Esc
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
            if (n.object as? NSWindow)?.title == "Player" { close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            if emby.syncPlay.group.itemEnded() { return }   // SyncPlay phase 4: the group's next item
            if let n = ui.shouldAutoPlayNext(autoNext: autoNext, item) { play(n) } else { close() }
        }
    }

    // MARK: Subtitles drawn by the app

    /// Subtitle distance from the bottom: the user's setting, but above the controls while they're showing.
    func subLift(_ size: CGSize) -> CGFloat {
        PlayerUIModel.subLift(height: size.height, bottomPercent: subBottom, controlsVisible: ui.controlsVisible)
    }

    @ViewBuilder func subtitleLayer(_ size: CGSize) -> some View {
        if model.loadingSubs {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spinner(inPlayer: true).controlSize(.small)
                    Text("Loading subtitles…").coveFont(size: 14, weight: .medium)
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
                    .coveFont(size: fs, weight: .medium)
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
            if Self.inPlayerBackPill { BackPill { back() }.helpLabel(ui.isFullScreen ? "Exit full screen (Esc)" : "Back (Esc)") }
            // Left glass group: picture in picture, full screen, info (Apple TV style)
            HStack(spacing: 6) {
                if model.pipSupported {
                    glassIcon(model.pipActive ? "pip.exit" : "pip.enter", on: model.pipActive) { model.togglePiP() }
                        .helpLabel("Picture in picture (P)")
                }
                glassIcon(ui.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    toggleFullScreen()
                }.helpLabel(ui.isFullScreen ? "Exit full screen (F)" : "Full screen (F)")
                glassIcon("info.circle", on: ui.showInfo) { ui.showInfo.toggle() }.helpLabel("Playback info (I)")
            }
            .padding(.horizontal, 8).frame(height: 50).background(.ultraThinMaterial, in: Capsule())
            Spacer()
            // Right glass group: volume
            HStack(spacing: 12) {
                Slider(value: ui.volumeBinding, in: 0...1).frame(width: 170).tint(.white).controlSize(.small).handCursor()
                Button { ui.toggleMute() } label: {
                    Image(systemName: ui.volumeIcon).coveFont(size: 17)
                        .frame(width: 26)
                }.buttonStyle(HoverButton(backing: true))
            }
            .padding(.horizontal, 18).frame(height: 50).background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 20).padding(.top, 16 + windowButtonsGap)
        .environment(\.colorScheme, .dark)
    }

    /// Small icon button inside a glass capsule.
    func glassIcon(_ name: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).coveFont(size: 18, weight: .medium)
                .frame(width: 40, height: 40)
                .foregroundColor(on ? accent : .white)
                .contentShape(Rectangle())
        }.buttonStyle(HoverButton(backing: true))
    }

    /// Apple TV style: back 10, play / pause and forward 10 as big glass circles in the middle of the picture.
    var centerControls: some View {
        HStack(spacing: 44) {
            centerCircle("gobackward.\(skipSecs)", size: 30, box: 92) { model.skip(-Double(skipSecs)) }
                .helpLabel("Back \(skipSecs) seconds")
            centerCircle(model.playing ? "pause.fill" : "play.fill", size: 50, box: 140) { model.togglePlay() }
                .helpLabel(model.playing ? "Pause (Space)" : "Play (Space)")
            centerCircle("goforward.\(skipSecs)", size: 30, box: 92) { model.skip(Double(skipSecs)) }
                .helpLabel("Forward \(skipSecs) seconds")
        }
        .environment(\.colorScheme, .dark)
    }

    func centerCircle(_ name: String, size: CGFloat, box: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).coveFont(size: size, weight: .semibold)
                .frame(width: box, height: box)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(HoverButton())
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
                            .coveFont(size: 17, weight: .semibold).opacity(0.85)
                    }
                    Text(item.heroTitle).coveFont(size: 34, weight: .bold).lineLimit(1)
                }
                Spacer()
                // Right glass group: previous / next episode, episodes, subtitles, quality, chapters, all options
                HStack(spacing: 6) {
                    if ui.hasEpisodeList(item) {
                        glassIcon("backward.end.fill") { if let p = prevEp { play(p) } else { model.seek(to: 0) } }
                            .helpLabel("Previous")
                        glassIcon("forward.end.fill") { if let n = nextEp { play(n) } }
                            .opacity(nextEp == nil ? 0.35 : 1).disabled(nextEp == nil).helpLabel("Next")
                        glassIcon("rectangle.stack", on: ui.panel == .episodes) {
                            withAnimation(.easeOut(duration: 0.2)) { ui.toggleEpisodes(item) }
                        }.helpLabel(ui.listHelp)
                    }
                    if !model.subStreams.isEmpty { subtitleMenu.padding(.horizontal, 5) }
                    qualityMenu.padding(.horizontal, 5)
                    if !model.chapterList.isEmpty {
                        glassIcon("list.bullet.rectangle", on: ui.panel == .chapters) {
                            withAnimation(.easeOut(duration: 0.2)) { ui.toggleChapters() }
                        }.helpLabel("Chapters (C)")
                    }
                    SyncPlayPlayerButton(group: emby.syncPlay.group) {
                        glassIcon("person.2.fill", on: ui.panel == .syncPlay) {
                            withAnimation(.easeOut(duration: 0.2)) { ui.toggleSyncPlay() }
                        }.helpLabel("Watch together")
                    }
                    glassIcon("waveform", on: ui.panel != nil && ui.panel != .episodes && ui.panel != .chapters
                              && ui.panel != .syncPlay) {
                        withAnimation(.easeOut(duration: 0.2)) { ui.toggleMediaPanel() }
                    }.helpLabel("Subtitles, audio, quality & speed")
                }
                .padding(.horizontal, 8).frame(height: 50).background(.ultraThinMaterial, in: Capsule())
            }

            // Scrubber in a glass capsule: elapsed time, bar, time left
            HStack(spacing: 14) {
                Text(fmt(ui.shownTime)).frame(minWidth: 52, alignment: .leading)
                Slider(value: ui.timelineValue, in: 0...max(model.duration, 1)) { editing in ui.timelineEditing(editing) }
                .tint(.white).controlSize(.small).handCursor()
                .background(GeometryReader { g in
                    Color.clear.onAppear { ui.sliderW = g.size.width }.onChange(of: g.size.width) { _, w in ui.sliderW = w }
                })
                .onContinuousHover { ph in ui.hover(ph) }
                .overlay(alignment: .bottomLeading) { scrubPreview }
                Text(ui.remainingText)
                    .frame(minWidth: 60, alignment: .trailing)
                    .helpLabel("Ends at \(endClock)")
            }
            .coveFont(size: 14, weight: .medium) { $0.monospacedDigit() }.foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 22).frame(height: 50)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .environment(\.colorScheme, .dark)
    }

    func iconButton(_ name: String, size: CGFloat = 22, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: name).coveFont(size: size, weight: .medium)
                .frame(width: size + 12, height: size + 12)
                .foregroundColor(on ? accent : .white)
                .background(Circle().fill(Color.white.opacity(on ? 0.12 : 0)))
                .contentShape(Rectangle())
        }.buttonStyle(HoverButton(backing: true))
    }

    // MARK: Panels

    @ViewBuilder var panelLayer: some View {
        switch ui.panel {
        case .subtitles:
            HStack { Spacer(); mediaPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .appearance:
            HStack { Spacer(); appearancePanel }.transition(.move(edge: .trailing))
        case .episodes:
            HStack { Spacer(); if ui.inCollection { collectionPanel } else { episodesPanel } }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .chapters:
            HStack { Spacer(); chaptersPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .syncPlay:
            HStack { Spacer(); GlassSyncPlayPanel(group: emby.syncPlay.group) { ui.panel = nil } }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case nil: EmptyView()
        }
    }

    func row(_ icon: String, _ title: String, sub: String? = nil, checked: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon).coveFont(size: 18).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).coveFont(size: 16)
                    if let sub { Text(sub).coveFont(size: 13).foregroundColor(.secondary) }
                }
                Spacer()
                if checked { Image(systemName: "checkmark").coveFont(size: 15, weight: .semibold) }
            }
            .foregroundColor(checked ? accent : .white)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle())
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).coveFont(size: 13, weight: .semibold).foregroundColor(.secondary)
            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 4)
    }

    func panelDivider() -> some View { Divider().padding(.horizontal, 18).padding(.vertical, 6) }

    /// One side panel with everything the old Subtitles, Speed and Settings popups had.
    var mediaPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Subtitles")
                row("captions.bubble", "Off", checked: model.sub == nil) { ui.setSub(emby, nil) }
                ForEach(model.subStreams) { st in
                    row("captions.bubble", PlayerUIModel.trackTitle(st), checked: model.sub == st.Index) {
                        ui.setSub(emby, st.Index)
                    }
                }
                HStack(spacing: 18) {
                    Image(systemName: "timer").coveFont(size: 18).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Subtitle Offset").coveFont(size: 16)
                        Text("\(model.subOffset) ms").coveFont(size: 13).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { model.subOffset -= 100 } label: { Image(systemName: "minus.circle") }.buttonStyle(.plainHand)
                        .helpLabel("Show subtitles 100 ms earlier")
                    Button { model.subOffset = 0 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plainHand)
                        .opacity(model.subOffset == 0 ? 0.3 : 1).helpLabel("Reset offset")
                    Button { model.subOffset += 100 } label: { Image(systemName: "plus.circle") }.buttonStyle(.plainHand)
                        .helpLabel("Show subtitles 100 ms later")
                }
                .coveFont(size: 18)
                .padding(.horizontal, 22).padding(.vertical, 9)
                row("textformat.size", "Subtitle Appearance") { withAnimation { ui.panel = .appearance } }

                if model.audioStreams.count > 0 {
                    panelDivider()
                    sectionTitle("Audio")
                    ForEach(model.audioStreams) { st in
                        row("waveform", PlayerUIModel.trackTitle(st), checked: model.audio == st.Index) {
                            ui.setAudio(emby, st.Index)
                        }
                    }
                }

                panelDivider()
                sectionTitle("Quality")
                ForEach(PlayerUIModel.qualities, id: \.0) { q in
                    row("dial.medium", q.1, checked: model.quality == q.0) { ui.setQuality(emby, q.0) }
                }

                panelDivider()
                sectionTitle("Speed")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(PlayerUIModel.speeds, id: \.self) { r in
                        let on = model.speed == r
                        Button { ui.setSpeed(r) } label: {
                            Text(PlayerUIModel.speedLabel(r)).coveFont(size: 14, weight: .semibold)
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .foregroundColor(on ? .black : .white)
                                .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent : Color.white.opacity(0.1)))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plainHand).helpLabel(PlayerUIModel.speedHelp(r))
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
            Text(label).coveFont(size: 15).foregroundColor(.white.opacity(0.85))
            Menu {
                ForEach(opts, id: \.0) { o in
                    Button { sel.wrappedValue = o.0 } label: {
                        if sel.wrappedValue == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                    }
                }
            } label: {
                HStack {
                    Text(opts.first { $0.0 == sel.wrappedValue }?.1 ?? "").coveFont(size: 16)
                    Spacer()
                    Image(systemName: "chevron.down").coveFont(size: 13, weight: .bold)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.white.opacity(0.1)).cornerRadius(6)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).handCursor()
        }
    }

    var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                Button { withAnimation { ui.panel = .subtitles } } label: { Image(systemName: "xmark").coveFont(size: 18, weight: .semibold) }
                    .buttonStyle(.plainHand)
                Text("Subtitle Appearance").coveFont(size: 18, weight: .bold)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dropdown("Text size", $subTextSize, Self.sizes.map { ($0.0, $0.1) })
                    dropdown("Text color", $subColor, Self.colors.map { ($0.0, $0.1) })
                    dropdown("Drop shadow", $subShadow, Self.shadows)
                    dropdown("Background color", $subBg, Self.bgs.map { ($0.0, $0.1) })
                    Text("Subtitle Position").coveFont(size: 20, weight: .bold).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        dropdown("Bottom Edge Position", $subBottom, PlayerUIModel.bottomPositions)
                        Text("Set the vertical position of the subtitles relative to the bottom of the screen.")
                            .coveFont(size: 13).foregroundColor(.secondary)
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

    static let qualities = PlayerUIModel.qualities

    /// Quick dropdown: subtitle language.
    var subtitleMenu: some View {
        Menu {
            Button { ui.setSub(emby, nil) } label: {
                if model.sub == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            ForEach(model.subStreams) { st in
                let name = PlayerUIModel.trackTitle(st)
                Button { ui.setSub(emby, st.Index) } label: {
                    if model.sub == st.Index { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            menuIcon("captions.bubble", on: model.sub != nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().modifier(HoverBacking())
        .helpLabel("Subtitles")
    }

    /// Quick dropdown: video quality.
    var qualityMenu: some View {
        Menu {
            ForEach(Self.qualities, id: \.0) { q in
                Button { ui.setQuality(emby, q.0) } label: {
                    if model.quality == q.0 { Label(q.1, systemImage: "checkmark") } else { Text(q.1) }
                }
            }
        } label: {
            menuIcon("dial.medium", on: model.quality != 0)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().modifier(HoverBacking())
        .helpLabel("Video quality")
    }

    func menuIcon(_ name: String, on: Bool) -> some View {
        Image(systemName: name).coveFont(size: 18, weight: .medium)
            .frame(width: 30, height: 30)
            .foregroundColor(on ? accent : .white)
            .contentShape(Rectangle())
    }

    var extraButtons: some View {
        HStack(spacing: 22) {
            if ui.hasEpisodeList(item) {
                iconButton("rectangle.stack", size: 18, on: ui.panel == .episodes) {
                    withAnimation(.easeOut(duration: 0.2)) { ui.toggleEpisodes(item) }
                }.helpLabel(ui.listHelp)
            }
            if !model.subStreams.isEmpty { subtitleMenu }
            qualityMenu
            if !model.chapterList.isEmpty {
                iconButton("list.bullet.rectangle", size: 18, on: ui.panel == .chapters) {
                    withAnimation(.easeOut(duration: 0.2)) { ui.toggleChapters() }
                }.helpLabel("Chapters (C)")
            }
            iconButton("info.circle", size: 18, on: ui.showInfo) { ui.showInfo.toggle() }.helpLabel("Playback info (I)")
            if model.pipSupported {
                iconButton(model.pipActive ? "pip.exit" : "pip.enter", size: 18, on: model.pipActive) { model.togglePiP() }
                    .helpLabel("Picture in picture (P)")
            }
        }
    }

    var pipPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip").coveFont(size: 44)
            Text("Playing in picture in picture").coveFont(size: 16, weight: .medium)
        }.opacity(0.6).allowsHitTesting(false)
    }

    // MARK: Scrub preview

    @ViewBuilder var scrubPreview: some View {
        if let x = ui.previewX, model.duration > 0 {
            let t = PlayerUIModel.previewTime(x: x, width: ui.sliderW, duration: model.duration)
            let img = model.hasThumbs ? model.thumb(at: t) : nil
            let w: CGFloat = img == nil ? 96 : 220   // (room for "1:30:00" in the glass bubble)
            VStack(spacing: 4) {
                if let img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: w).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6), lineWidth: 1))
                }
                Text(fmt(t)).coveFont(size: 13, weight: .semibold) { $0.monospacedDigit() }.lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
            }
            .frame(width: w)
            .offset(x: PlayerUIModel.previewOffset(x: x, previewWidth: w, width: ui.sliderW), y: -26)
            .allowsHitTesting(false)
        }
    }

    // MARK: Intro / up next (bottom-right corner)

    var showUpNext: Bool { ui.showUpNext(item) }

    /// Whole seconds until the episode ends.
    var secsLeft: Int { ui.secsLeft }

    var cornerCards: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()
            if model.skippedIntro {
                HStack(spacing: 12) {
                    Image(systemName: "forward.fill")
                    Text("Intro skipped").coveFont(size: 15, weight: .semibold)
                    Button("Watch intro") { model.watchIntro() }.buttonStyle(.plainHand)
                        .coveFont(size: 15, weight: .semibold).foregroundColor(accent)
                }
                .padding(.horizontal, 18).frame(height: 44)
                .searchGlass()
                .transition(.opacity)
            } else if model.inIntro {
                Button { model.skipIntro() } label: {
                    Label("Skip Intro", systemImage: "forward.fill").coveFont(size: 16, weight: .semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 22).frame(height: 44)
                        .searchGlass()
                }.buttonStyle(HoverButton())
            }
            if showUpNext, let n = nextEp { upNextCard(n).transition(.coveGlassPopIn) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 34)
        .padding(.bottom, ui.showUI ? 200 : 40)
        .animation(.easeOut(duration: 0.2), value: model.skippedIntro)
        .coveGlassPopIn(value: showUpNext)   // as the bottom search pill
    }

    func upNextCard(_ n: Item) -> some View {
        HStack(spacing: 14) {
            CachedImage(url: ui.upNextImage(emby, n)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.white.opacity(0.1) }
            .frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(ui.upNextHeading(n)).coveFont(size: 12, weight: .semibold).foregroundColor(.secondary)
                Text(ui.upNextTitle(n))
                    .coveFont(size: 15, weight: .semibold).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 10) {
                    Button { play(n) } label: {
                        Text("Play now").coveFont(size: 14, weight: .bold)
                            .foregroundColor(.black).padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white))
                    }.buttonStyle(HoverButton())
                    Button { ui.upNextCancelled = true } label: {
                        Text("Cancel").coveFont(size: 14, weight: .semibold)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }.buttonStyle(HoverButton())
                    .helpLabel(emby.syncPlay.group.isInGroup ? GroupUpNext.cancelTip : "Cancel")
                }
                // v1.18.8: in a SyncPlay group, the group's countdown (as Glass3D)
                UpNextCountdown(group: emby.syncPlay.group, autoNext: autoNext, localSecs: secsLeft, duration: ui.player.duration, glass: true)
            }
        }
        .padding(12)
        .glassPanel()
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    // MARK: Playback info

    var infoOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Playback info").coveFont(size: 13, weight: .bold)
                    ForEach(Array(ui.infoLines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(l.0).foregroundColor(.white.opacity(0.6)).frame(width: 120, alignment: .leading)
                            Text(l.1).frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
                .coveFont(size: 12) { $0.monospacedDigit() }
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
        let seasons = ui.seasons
        let list = ui.seasonEpisodes
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Episodes").coveFont(size: 18, weight: .bold)
                Spacer()
                if seasons.count > 1 {
                    Picker("", selection: $ui.pickerSeason) {
                        ForEach(seasons, id: \.self) { n in Text(PlayerUIModel.seasonName(n)).tag(n) }
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
        return Button { if !current { ui.panel = nil; play(ep) } } label: {
            HStack(spacing: 12) {
                CachedImage(url: emby.image(ep.Id, width: 320, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 120, height: 68).clipped().cornerRadius(5)
                .overlay {
                    if current {
                        Image(systemName: "speaker.wave.2.fill").coveFont(size: 18).foregroundColor(.white)
                            .padding(6).background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if played && !current {
                        Image(systemName: "checkmark.circle.fill").coveFont(size: 14)
                            .foregroundColor(.white).shadow(radius: 2).padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ep.IndexNumber ?? 0). \(ep.Name)").coveFont(size: 14, weight: .semibold).lineLimit(2)
                    if let t = ep.RunTimeTicks, t > 0 {
                        Text(runtimeText(t)).coveFont(size: 12).foregroundColor(.secondary)
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
        let cur = ui.currentChapter
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
        Button { ui.seekToChapter(c) } label: {
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
                    Text(c.Name ?? "Chapter \(i + 1)").coveFont(size: 15).lineLimit(2)
                    Text(fmt(c.start)).coveFont(size: 13) { $0.monospacedDigit() }.foregroundColor(.secondary)
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
    /// Classic theme: the line under the pointer lights up in the accent, as in the glass lists
    var glass = false
    func makeBody(configuration: Configuration) -> some View {
        if glass { GlassRow(c: configuration) }
        else { configuration.label.background(Color.white.opacity(configuration.isPressed ? 0.15 : 0)) }
    }
    struct GlassRow: View {
        let c: ButtonStyleConfiguration
        @AppStorage("accent") private var accentName = "red"
        @State private var hover = false
        var body: some View {
            c.label
                .background { if hover || c.isPressed { Capsule().fill(Theme.accent(accentName).opacity(c.isPressed ? 0.7 : 0.55)) } }
                .scrollHover($hover)
        }
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

// MARK: Play collection: the Collection panel in place of Episodes (Glass3DCollectionPlay.swift)

extension PlayerView {
    var collectionPanel: some View { CollectionPanel(ui: ui, current: item, classic: false) { play($0) } }
}
