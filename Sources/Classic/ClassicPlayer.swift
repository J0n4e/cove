import IOKit.pwr_mgt
import SwiftUI
import AVKit

/// The subtitle appearance panel: dark glass in the Classic theme, the plain grey panel otherwise.
struct AppearanceSurface: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(PanelSurface(classic: true)) }   // padded by panelLayer, as the other panels
        else { content.background(Color(white: 0.16).opacity(0.97)) }
    }
}

/// Timeline preview picture: the glass card frame in the Classic theme, a white outline otherwise.
struct PreviewFrame: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.classicThinBorder(10).shadow(color: .black.opacity(0.5), radius: 8, y: 3) }
        else { content.overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb).stroke(Color.white.opacity(0.6), lineWidth: 1)) }
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
        .scrollHover($hover)
        .animation(.easeOut(duration: 0.12), value: hover || dragging)
    }
}

/// The playback info box: the side panel's dark glass in the Classic theme, a plain dark box otherwise.
struct InfoSurface: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(PanelSurface(classic: true)) }
        else { content.background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row).fill(Color.black.opacity(0.75))) }
    }
}

// MARK: - Player (inside the main window)

struct ClassicPlayerView: View {
    @EnvironmentObject var emby: Emby
    @StateObject private var ui = PlayerUIModel(style: .classic)
    /// The playback engine (owned by `ui`, which passes its changes on).
    private var model: PlayerModel { ui.player }
    let req: PlayRequest
    /// Classic theme: glass buttons. These controls can also be picked under the Glass theme (Settings →
    /// Playback → Player controls); there they keep their plain look.
    @Environment(\.classicGlass) private var classic
    @Environment(\.dropdownCenter) private var dropdowns

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
    // Remembered across episodes (each episode gets a fresh ClassicPlayerView), so closing the player still leaves full screen
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
    /// The separate player window has no title bar (as in the Glass player): measuring one there changed the
    /// layout during the full screen animation, and leaving full screen stalled.
    var titleBarHeight: CGFloat {
        guard !UserDefaults.standard.bool(forKey: "separatePlayer"),
              !ui.isFullScreen, let w = window, !w.styleMask.contains(.fullScreen) else { return 0 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }
    /// Color of the strip under the title bar. The system draws the bar's own gray (about 93 % opaque) over it,
    /// and the result is the same gray on both sides only when this strip is (44, 45, 45).
    /// Glass pills instead of bare accent text (always, since there is one look).
    var glass3DChrome: Bool { true }
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
        w.collectionBehavior.insert(.fullScreenPrimary)   // as in the Glass player
        ui.fsBusy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ui.fsBusy = false }   // in case no notification comes
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
        let lang = model.subStreams.first { $0.Index == model.sub }.map { ClassicDetailView.langName($0) }
        Task {
            let f = await emby.full(ep.id)
            let src = f?.MediaSources?.first
            var pick: Int?
            if let lang {
                let subs = (src?.MediaStreams ?? []).filter { $0.`Type` == "Subtitle" && ClassicDetailView.langName($0) == lang }
                pick = bestTextSub(subs)?.Index
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
                videoStateOverlay

                subtitleLayer(geo.size).animation(.easeOut(duration: 0.2), value: ui.showUI)

                if ui.showUI || ui.panel != nil || AirPlayMenu.open {   // the AirPlay menu's picker stays
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

                if ui.showInfo { classicInfoOverlay }
                classicCornerCards
                panelLayer
                if classic { CastPlayerPicker(player: model, req: req) { close() }; AirPlayDetailPlayerHook(model: model, ui: ui) }
                SyncPlayToast(group: emby.syncPlay.group, classic: classic)
                // Title bar strip, above every layer (the controls' dark gradient used to darken it)
                VStack(spacing: 0) {
                    ClassicPlayerTitleBar.stripColor(glass3D: glass3DChrome).frame(height: titleBarHeight)
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
            if classicShowUpNext, let n = nextEp { play(n); return .handled }   // next episode: no controls
            model.togglePlay()
            poke(); return .handled
        }
        .onKeyPress(.return) {
            if classicShowUpNext, let n = nextEp { play(n); return .handled }
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
        .onChange(of: classicShowUpNext) { _, on in if on { focused = true } }
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
        // Caught at the app level (AppKit sometimes swallows Esc before SwiftUI sees it, e.g. after full
        // screen), but only in the player's own window.
        .background(ClassicPlayerWindowProbe(black: glass3DChrome) { ui.playerWin.window = $0 })
        .onAppear {
            ui.listOpen = { [dropdowns] in dropdowns?.list != nil }
            ui.installKeyMonitor(toggleFullScreen: { toggleFullScreen() }, close: { close() })
        }
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
        // Closing the player window (red button or ⌘W) stops playback, like Esc (the Glass player does the same)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
            if (n.object as? NSWindow)?.title == "Player" { close() }
        }
        // Media keys / Control Center (shared with the Glass player)
        .onAppear { RemoteControls.attach(model, skip: Double(skipSecs)); attachRemote() }
        .onChange(of: model.playing) { RemoteControls.update(item, model) }
        .onChange(of: model.duration) { RemoteControls.update(item, model) }
        .onChange(of: Int(model.time / 10)) { RemoteControls.update(item, model) }
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
        if model.loadingSubs && !model.airPlayActive {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spinner(inPlayer: true).controlSize(.small)
                    Text("Loading subtitles…").cvFont(14, weight: .medium).glossyLettering()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .modifier(TimeBubble(classic: true))   // dark glass, as the time above the timeline
                .padding(.bottom, subLift(size))
            }.frame(maxWidth: .infinity).allowsHitTesting(false)
        }
        if !model.caption.isEmpty && !model.pipActive && !model.airPlayActive {   // (on AirPlay the TV shows them)
            // (not while the video is in picture in picture)
            let fs = max(14, size.height * (Self.sizes.first { $0.0 == subTextSize }?.2 ?? 0.045))
            let color = Self.colors.first { $0.0 == subColor }?.2 ?? .white
            let shade: Color = subColor == "black" ? .white : .black
            VStack {
                Spacer()
                Text(model.caption)
                    .cvFont(fs, weight: .medium)
                    .foregroundColor(color)
                    .multilineTextAlignment(.center)
                    .modifier(SubShadow(style: subShadow, color: shade))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.black.opacity(Self.bgs.first { $0.0 == subBg }?.2 ?? 0))
                    .cornerRadius(Glass3DTokens.Radius.tag)
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
            if Self.inPlayerBackPill || glass3DChrome {   // Glass3D: no traffic lights, so Back closes the player
                Group {
                    if classic {
                        Button { back() } label: { Label("Back", systemImage: "chevron.left").classicGlassPill(size: 44) }
                            .buttonStyle(HoverButton()).keyboardShortcut("[", modifiers: .command)
                    } else { BackPill { back() } }
                }.helpLabel(ui.isFullScreen ? "Exit full screen (Esc)" : "Back (Esc)")
            }
            CachedImage(url: emby.image(item.SeriesId ?? item.Id, "Logo", width: 400)) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: { EmptyView() }
            .frame(maxWidth: 160, maxHeight: 40, alignment: .leading)
            Spacer()
            Group {
                if classic { GlassSlider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), range: 0...1) }
                else { Slider(value: ui.volumeBinding, in: 0...1).tint(.white).controlSize(.small) }
            }.frame(width: 160).handCursor()
            iconButton(ui.volumeIcon, size: 18) { ui.toggleMute() }.helpLabel(model.volume == 0 ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    // MARK: Bottom bar

    /// The timeline: the glass slider in the Classic theme, the standard one otherwise.
    @ViewBuilder var timeline: some View {
        let pos = ui.timelineValue
        let edit: (Bool) -> Void = { editing in ui.timelineEditing(editing) }
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
                    if let l = episodeLine { Text(l).cvFont(16, weight: .medium).opacity(0.85) }
                    Text(item.heroTitle).cvFont(28, weight: .bold)
                }
                Spacer()
                if !classic {   // Glass3D: subtitles, audio, quality & speed are in the glass bar
                    iconButton("captions.bubble", on: ui.panel != nil) {
                        withAnimation(.easeOut(duration: 0.2)) { ui.toggleMediaPanel() }
                    }.helpLabel("Subtitles, audio, quality & speed")
                }
            }

            timeline
            .handCursor()
            .background(GeometryReader { g in
                Color.clear.onAppear { ui.sliderW = g.size.width }.onChange(of: g.size.width) { _, w in ui.sliderW = w }
            })
            .onContinuousHover { ph in ui.hover(ph) }
            .overlay(alignment: .bottomLeading) { scrubPreview }

            HStack {
                Text(fmt(ui.shownTime))
                Spacer()
                Text("\(ui.remainingText)  /  \(endClock)")
            }
            .cvFont(14) { $0.monospacedDigit() }.opacity(0.85)

            HStack(spacing: 30) {
                iconButton("backward.end.fill", size: 18) { if let p = prevEp { play(p) } else { model.seek(to: 0) } }
                    .helpLabel("Previous")
                iconButton("gobackward.\(skipSecs)", size: 22) { model.skip(-Double(skipSecs)) }.helpLabel("Back \(skipSecs) seconds")
                Button { model.togglePlay(); poke() } label: {
                    if classic {
                        Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                            .classicGlassPill(size: 60)
                    } else {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").cvFont(22, weight: .bold)
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
                if !classic {   // Glass3D: inside the glass bar (classicExtraButtons)
                    iconButton(ui.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 18) {
                        toggleFullScreen()
                    }.helpLabel(ui.isFullScreen ? "Exit full screen (F)" : "Full screen (F)")
                }
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
            Image(systemName: name).cvFont(size, weight: .medium)
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
            if classic {   // placed and faded like the other panels
                HStack { Spacer(); appearancePanel }
                    .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HStack { Spacer(); appearancePanel }.transition(.move(edge: .trailing))
            }
        case .episodes:
            HStack { Spacer(); if ui.inCollection { collectionPanel } else { classicEpisodesPanel } }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .chapters:
            HStack { Spacer(); classicChaptersPanel }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .syncPlay:
            HStack { Spacer(); ClassicSyncPlayPanel(group: emby.syncPlay.group, classic: classic) { ui.panel = nil } }
                .padding(.top, 84).padding(.bottom, 190).padding(.trailing, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case nil: EmptyView()
        }
    }

    @ViewBuilder var resetAppearanceButton: some View {
        let reset = { subTextSize = "normal"; subColor = "white"; subShadow = "drop"; subBg = "none"; subBottom = 10 }
        if classic {
            Button(action: reset) {
                Text("Reset to Default").cvFont(13, weight: .semibold).padding(.horizontal, 16).frame(minHeight: 34).classicGlassPill()
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
                Image(systemName: icon).cvFont(classic ? 14 : 18).frame(width: classic ? 20 : 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).cvFont(classic ? 13 : 16, weight: classic ? .medium : .regular).lineLimit(1)
                    if let sub { Text(sub).cvFont(classic ? 11 : 13).foregroundColor(.secondary) }
                }
                Spacer()
                if checked { Image(systemName: "checkmark").cvFont(classic ? 12 : 15, weight: .semibold) }
            }
            .foregroundColor(classic ? .white : (checked ? accent : .white))
            .padding(.horizontal, classic ? 12 : 22).padding(.vertical, classic ? 7 : 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle(glass: classic))
        .padding(.horizontal, classic ? 6 : 0)
    }

    func sectionTitle(_ t: String) -> some View {
        Text(classic ? t.uppercased() : t).cvFont(classic ? 10 : 13, weight: .semibold).foregroundColor(.secondary)
            .kerning(classic ? 0.6 : 0)
            .padding(.horizontal, classic ? 18 : 22).padding(.top, classic ? 8 : 10).padding(.bottom, 4)
    }

    func panelDivider() -> some View { Divider().padding(.horizontal, 18).padding(.vertical, 6) }

    /// One side panel with everything the old Subtitles, Speed and Settings popups had (Glass3D: Glass3DMediaPanel).
    @ViewBuilder var mediaPanel: some View {
        if classic {
            Glass3DSubtitlesPanel(ui: ui, model: model, emby: emby) { withAnimation { ui.panel = .appearance } }
        } else {
            plainMediaPanel
        }
    }

    var plainMediaPanel: some View {
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
                    Image(systemName: "timer").cvFont(18).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Subtitle Offset").cvFont(16)
                        Text("\(model.subOffset) ms").cvFont(13).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { model.subOffset -= 100 } label: { Image(systemName: "minus.circle") }.buttonStyle(.plainHand)
                        .helpLabel("Show subtitles 100 ms earlier")
                    Button { model.subOffset = 0 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plainHand)
                        .opacity(model.subOffset == 0 ? 0.3 : 1).helpLabel("Reset offset")
                    Button { model.subOffset += 100 } label: { Image(systemName: "plus.circle") }.buttonStyle(.plainHand)
                        .helpLabel("Show subtitles 100 ms later")
                }
                .cvFont(classic ? 14 : 18)
                .padding(.horizontal, classic ? 18 : 22).padding(.vertical, classic ? 6 : 9)
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
                            Text(PlayerUIModel.speedLabel(r)).cvFont(classic ? 12 : 14, weight: .semibold)
                                .frame(maxWidth: .infinity).frame(height: classic ? 28 : 36)
                                .foregroundColor(classic || !on ? .white : .black)
                                .background {
                                    if classic {
                                        // glass pills; the chosen speed lit in the accent
                                        Capsule().fill(on ? accent.opacity(0.55) : Color.white.opacity(0.06))
                                            .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.4 : 0.15), lineWidth: 0.75))
                                    } else {
                                        RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field).fill(on ? accent : Color.white.opacity(0.1))
                                    }
                                }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plainHand).helpLabel(PlayerUIModel.speedHelp(r))
                    }
                }
                .padding(.horizontal, classic ? 18 : 22).padding(.bottom, 6)
            }
            .padding(.vertical, classic ? 8 : 12)
        }
        .classicScrollBars()   // thin overlay bars, only while scrolling
        .frame(width: classic ? 290 : 340)
        .frame(maxHeight: classic ? 440 : .infinity)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}   // keep taps inside the panel
    }

    @ViewBuilder func dropdown<T: Hashable>(_ label: String, _ sel: Binding<T>, _ opts: [(T, String)]) -> some View {
        if classic {
            // Glass3D: a dropdown field (radius 8) opening the glass list
            VStack(alignment: .leading, spacing: 6) {
                Text(label).cvFont(12, weight: .medium).foregroundColor(.white.opacity(0.75))
                Glass3DFieldPicker(selection: sel, options: opts)
            }
        } else {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).cvFont(15).foregroundColor(.white.opacity(0.85))
            Menu {
                ForEach(opts, id: \.0) { o in
                    Button { sel.wrappedValue = o.0 } label: {
                        if sel.wrappedValue == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                    }
                }
            } label: {
                HStack {
                    Text(opts.first { $0.0 == sel.wrappedValue }?.1 ?? "").cvFont(16)
                    Spacer()
                    Image(systemName: "chevron.down").cvFont(13, weight: .bold)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.white.opacity(0.1)).cornerRadius(Glass3DTokens.Radius.thumb)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).handCursor()
        }
        }
    }

    @ViewBuilder var appearanceHeading: some View {
        if classic {
            Glass3DPanelHeading(title: "Subtitle Appearance", back: { withAnimation { ui.panel = .subtitles } })
        } else {
            HStack(spacing: 20) {
                Button { withAnimation { ui.panel = .subtitles } } label: { Image(systemName: "xmark").cvFont(18, weight: .semibold) }
                    .buttonStyle(.plainHand)
                Text("Subtitle Appearance").cvFont(18, weight: .bold)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
    }

    var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            appearanceHeading
            ScrollView {
                VStack(alignment: .leading, spacing: classic ? 16 : 22) {
                    dropdown("Text size", $subTextSize, Self.sizes.map { ($0.0, $0.1) })
                    dropdown("Text color", $subColor, Self.colors.map { ($0.0, $0.1) })
                    dropdown("Drop shadow", $subShadow, Self.shadows)
                    dropdown("Background color", $subBg, Self.bgs.map { ($0.0, $0.1) })
                    Text("Subtitle Position").cvFont(20, weight: .bold).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        dropdown("Bottom Edge Position", $subBottom, PlayerUIModel.bottomPositions)
                        Text("Set the vertical position of the subtitles relative to the bottom of the screen.")
                            .cvFont(13).foregroundColor(.secondary)
                    }
                    resetAppearanceButton.padding(.top, 6)
                }
                .padding(.horizontal, classic ? 20 : 28).padding(.bottom, classic ? 18 : 28)
            }
            .classicScrollBars()   // thin overlay bars, only while scrolling
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

    static let qualities = PlayerUIModel.qualities

    /// Quick dropdown: video quality.
    var classicQualityMenu: some View {
        Menu {
            ForEach(Self.qualities, id: \.0) { q in
                Button { ui.setQuality(emby, q.0) } label: {
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
        Image(systemName: name).cvFont(18, weight: .medium)
            .frame(width: 30, height: 30)
            .foregroundColor(on ? accent : .white)
            .contentShape(Rectangle())
    }

    @ViewBuilder var classicExtraButtons: some View {
        if classic {
            Glass3DControlBar(group: emby.syncPlay.group, items: glass3DBarItems) { poke() }
        } else {
            plainExtraButtons
        }
    }

    /// The Glass3D right-hand bar, in the owner's order (Glass3DBarItem.order).
    var glass3DBarItems: [Glass3DBarItem] {
        var a: [Glass3DBarItem] = []
        if ui.hasEpisodeList(item) {
            a.append(Glass3DBarItem(id: "episodes", icon: "list.and.film", on: ui.panel == .episodes, help: ui.listHelp) {
                withAnimation(.easeOut(duration: 0.2)) { ui.toggleEpisodes(item) }
            })
        }
        if !model.chapterList.isEmpty {
            a.append(Glass3DBarItem(id: "chapters", icon: "list.bullet.rectangle", on: ui.panel == .chapters, help: "Chapters (C)") {
                withAnimation(.easeOut(duration: 0.2)) { ui.toggleChapters() }
            })
        }
        // Subtitles: a glass panel (tracks, then offset and appearance)
        let subsOpen = ui.panel == .subtitles || ui.panel == .appearance
        a.append(Glass3DBarItem(id: "subtitles", icon: "captions.bubble", on: subsOpen || model.sub != nil, help: "Subtitles") {
            withAnimation(.easeOut(duration: 0.2)) { ui.panel = subsOpen ? nil : .subtitles }
        })
        if !model.audioStreams.isEmpty {
            let audio = model.audioStreams
            let pick = Glass3DBarItem.Menu(options: Glass3DTrackLabel.audioLines(audio),
                                           selected: audio.firstIndex { $0.Index == model.audio } ?? -1) { i in
                ui.setAudio(emby, audio[i].Index)
            }
            a.append(Glass3DBarItem(id: "audio", icon: "speaker.wave.2", help: "Audio", menu: pick))
        }
        a.append(Glass3DBarItem(id: "quality", icon: "dial.medium", on: model.quality != 0 || model.speed != 1,
                                help: "Quality & speed", menu: qualitySpeedMenu))
        a.append(Glass3DBarItem(id: "syncplay", icon: "person.2.fill", on: ui.panel == .syncPlay, help: "Watch together", syncPlayOnly: true) {
            withAnimation(.easeOut(duration: 0.2)) { ui.toggleSyncPlay() }
        })
        a.append(Glass3DBarItem(id: "info", icon: "info.circle", on: ui.showInfo, help: "Playback info (I)") { ui.showInfo.toggle() })
        if model.pipSupported {
            a.append(Glass3DBarItem(id: "pip", icon: model.pipActive ? "pip.exit" : "pip.enter", on: model.pipActive,
                                    help: "Picture in picture (P)") { model.togglePiP() })
        }
        a.append(Glass3DBarItem(id: "cast", icon: "tv.and.mediabox", on: CastPickerState.shared.open, help: "Cast") {
            withAnimation(.easeOut(duration: 0.2)) { CastPickerState.shared.open.toggle() }
        })
        a.append(Glass3DBarItem(id: "airplay", icon: "airplayvideo", on: model.airPlayActive, help: "AirPlay", routePlayer: model.player))
        a.append(Glass3DBarItem(id: "fullscreen", icon: ui.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                help: ui.isFullScreen ? "Exit full screen (F)" : "Full screen (F)") { toggleFullScreen() })
        return Glass3DBarItem.ordered(a)
    }

    /// Quality & speed: the qualities, then the speeds, each with its own tick.
    var qualitySpeedMenu: Glass3DBarItem.Menu {
        Glass3DBarItem.Menu(options: Glass3DBarMenus.qualitySpeedOptions(), selected: -1, pick: { i in
            switch Glass3DBarMenus.qualitySpeedPick(i) {
            case .quality(let q): ui.setQuality(emby, q)
            case .speed(let r): ui.setSpeed(r)
            case .nothing: break
            }
        }, checked: Glass3DBarMenus.qualitySpeedChecked(quality: model.quality, speed: model.speed),
           headers: Glass3DBarMenus.qualitySpeedHeaders)
    }

    var plainExtraButtons: some View {
        HStack(spacing: 22) {
            if ui.hasEpisodeList(item) {
                iconButton("list.and.film", size: 18, on: ui.panel == .episodes) {
                    withAnimation(.easeOut(duration: 0.2)) { ui.toggleEpisodes(item) }
                }.helpLabel(ui.listHelp)
            }
            classicQualityMenu   // subtitles: only the floating captions button's panel
            if !model.chapterList.isEmpty {
                iconButton("list.bullet.rectangle", size: 18, on: ui.panel == .chapters) {
                    withAnimation(.easeOut(duration: 0.2)) { ui.toggleChapters() }
                }.helpLabel("Chapters (C)")
            }
            SyncPlayPlayerButton(group: emby.syncPlay.group) {
                iconButton("person.2.fill", size: 18, on: ui.panel == .syncPlay) {
                    withAnimation(.easeOut(duration: 0.2)) { ui.toggleSyncPlay() }
                }.helpLabel("Watch together")
            }
            iconButton("info.circle", size: 18, on: ui.showInfo) { ui.showInfo.toggle() }.helpLabel("Playback info (I)")
            if model.pipSupported {
                iconButton(model.pipActive ? "pip.exit" : "pip.enter", size: 18, on: model.pipActive) { model.togglePiP() }
                    .helpLabel("Picture in picture (P)")
            }
        }
    }

    /// Over the video: picture in picture, or AirPlay ("Playing on <device>": the picture is on the TV).
    @ViewBuilder var videoStateOverlay: some View {
        if model.pipActive { classicPipPlaceholder }
        else if model.airPlayActive { AirPlayPlayingCard(item: item, device: model.airPlayDevice) }
    }

    var classicPipPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip").cvFont(44)
            Text("Playing in picture in picture").cvFont(16, weight: .medium)
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
                        .frame(width: w).cornerRadius(classic ? 10 : 6)
                        .modifier(PreviewFrame(classic: classic))
                }
                Text(fmt(t)).cvFont(13, weight: .semibold) { $0.monospacedDigit() }.lineLimit(1).fixedSize()
                    .padding(.horizontal, classic ? 10 : 6).padding(.vertical, classic ? 4 : 2)
                    .modifier(TimeBubble(classic: classic))
            }
            .frame(width: w)
            .offset(x: PlayerUIModel.previewOffset(x: x, previewWidth: w, width: ui.sliderW), y: -26)
            .allowsHitTesting(false)
        }
    }

    // MARK: Intro / up next (bottom-right corner)

    var classicShowUpNext: Bool { ui.showUpNext(item) }

    /// Whole seconds until the episode ends.
    var classicSecsLeft: Int { ui.secsLeft }

    var classicCornerCards: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()
            if model.skippedIntro {
                HStack(spacing: 12) {
                    Image(systemName: "forward.fill")
                    Text("Intro skipped").cvFont(15, weight: .semibold)
                    if glass3DChrome {
                        // A secondary glass pill, as Cancel on the Up next card (no bare accent text as a button)
                        Button { model.watchIntro() } label: {
                            Text("Watch intro").cvFont(14, weight: .semibold).foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .classicGlassPill()
                        }.buttonStyle(HoverButton())
                    } else {
                        Button("Watch intro") { model.watchIntro() }.buttonStyle(.plainHand)
                            .cvFont(15, weight: .semibold).foregroundColor(accent)
                    }
                }
                .padding(.horizontal, 18).frame(height: 44)
                .searchGlass()
                .transition(.opacity)
            } else if model.inIntro {
                Button { model.skipIntro() } label: {
                    Label("Skip Intro", systemImage: "forward.fill").cvFont(16, weight: .semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 22).frame(height: 44)
                        .searchGlass()
                }.buttonStyle(HoverButton())
            }
            if classicShowUpNext, let n = nextEp { classicUpNextCard(n).transition(.coveGlassPopIn) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 34)
        .padding(.bottom, ui.showUI ? 200 : 40)
        .animation(.easeOut(duration: 0.2), value: model.skippedIntro)
        .coveGlassPopIn(value: classicShowUpNext)   // as the bottom search pill
    }

    func classicUpNextCard(_ n: Item) -> some View {
        HStack(spacing: 14) {
            CachedImage(url: ui.upNextImage(emby, n)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.white.opacity(0.1) }
            .frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(ui.upNextHeading(n)).cvFont(12, weight: .semibold).foregroundColor(.white.opacity(0.88))
                Text(ui.upNextTitle(n))
                    .cvFont(15, weight: .semibold).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 10) {
                    Button { play(n) } label: {
                        Text("Play now").cvFont(14, weight: .semibold)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .classicGlassPill()
                    }.buttonStyle(HoverButton())
                    Button { ui.upNextCancelled = true } label: {
                        Text("Cancel").cvFont(14, weight: .semibold)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .classicGlassPill()
                    }.buttonStyle(HoverButton())
                    .helpLabel(emby.syncPlay.group.isInGroup ? GroupUpNext.cancelTip : "Cancel")
                }
                // v1.18.6: in a SyncPlay group, the group's countdown ("Next episode for everyone in 0:12")
                UpNextCountdown(group: emby.syncPlay.group, autoNext: autoNext, localSecs: classicSecsLeft, duration: ui.player.duration, film: n.`Type` == "Movie")
            }
        }
        .modifier(Glass3DReadableText())   // the top bar tabs' text treatment (owner)
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
                    Text("Playback info").cvFont(classic ? 18 : 13, weight: .bold).padding(.bottom, classic ? 4 : 0)
                    ForEach(Array(ui.infoLines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(l.0).foregroundColor(.white.opacity(0.6)).frame(width: 120, alignment: .leading)
                            Text(l.1).frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
                .cvFont(12) { $0.monospacedDigit() }
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
        let seasons = ui.seasons
        let list = ui.seasonEpisodes
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Episodes").cvFont(18, weight: .bold)
                Spacer()
                if seasons.count > 1 {
                    if classic {
                        GlassPicker(selection: $ui.pickerSeason, options: seasons.map { ($0, $0 == 0 ? "Specials" : "Season \($0)") })
                    } else {
                        Picker("", selection: $ui.pickerSeason) {
                            ForEach(seasons, id: \.self) { n in Text(PlayerUIModel.seasonName(n)).tag(n) }
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
                .classicScrollBars()   // thin overlay bars, only while scrolling
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
        return Button { if !current { ui.panel = nil; play(ep) } } label: {
            HStack(spacing: 12) {
                CachedImage(url: emby.image(ep.Id, width: 320, plain: true)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 120, height: 68).clipped().cornerRadius(Glass3DTokens.Radius.thumb)
                .overlay {
                    if current {
                        Image(systemName: "speaker.wave.2.fill").cvFont(18).foregroundColor(.white)
                            .padding(6).background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                .overlay {
                    if classic && !current {   // thin accent line on partly watched episodes
                        Glass3DEpisodeProgress(fraction: Glass3DTrackLabel.episodeFraction(
                            position: emby.resumeAt(ep), runtimeTicks: ep.RunTimeTicks, played: played))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if played && !current {
                        Image(systemName: "checkmark.circle.fill").cvFont(14)
                            .foregroundColor(.white).shadow(radius: 2).padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ep.IndexNumber ?? 0). \(ep.Name)").cvFont(14, weight: .semibold).lineLimit(2)
                    if let t = ep.RunTimeTicks, t > 0 {
                        Text(runtimeText(t)).cvFont(12).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(classic || !current ? .white : accent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background {
                // Classic: the playing one on an accent glass band, as the chosen line in the glass lists
                if classic && current { RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous).fill(accent.opacity(0.4)) }
                else if current { Color.white.opacity(0.08) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle(glass: classic)).padding(.horizontal, classic ? 6 : 0)
    }

    // MARK: Chapters panel

    var classicChaptersPanel: some View {
        let list = model.chapterList
        let cur = ui.currentChapter
        return VStack(alignment: .leading, spacing: 0) {
            if classic { Glass3DPanelHeading(title: "Chapters") }   // as the Episodes panel
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !classic { sectionTitle("Chapters") }
                    ForEach(Array(list.enumerated()), id: \.offset) { k, e in
                        classicChapterRow(e.i, e.c, current: k == cur)
                    }
                }.padding(.top, classic ? 0 : 12).padding(.bottom, classic ? 10 : 12)
            }
            .classicScrollBars()   // thin overlay bars, only while scrolling
        }
        .frame(width: classic ? 400 : 380)
        .modifier(PanelSurface(classic: classic))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}
    }

    func classicChapterRow(_ i: Int, _ c: Chapter, current: Bool) -> some View {
        Button { ui.seekToChapter(c) } label: {
            HStack(spacing: 14) {
                Group {
                    if let tag = c.ImageTag {
                        CachedImage(url: emby.chapterImage(item.Id, i, tag)) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color.white.opacity(0.08) }
                    } else { Color.white.opacity(0.08) }
                }
                .frame(width: 112, height: 63).clipped().cornerRadius(Glass3DTokens.Radius.thumb)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.Name ?? "Chapter \(i + 1)").cvFont(15).lineLimit(2)
                    Text(fmt(c.start)).cvFont(13) { $0.monospacedDigit() }.foregroundColor(.secondary)
                }
                Spacer()
            }
            .foregroundColor(classic || !current ? .white : accent)
            .padding(.horizontal, classic ? 12 : 18).padding(.vertical, 7)
            .background {
                if classic && current { RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous).fill(accent.opacity(0.4)) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(PanelRowStyle(glass: classic)).padding(.horizontal, classic ? 6 : 0)
    }
}

// MARK: Play collection: the Collection panel in place of Episodes (Glass3DCollectionPlay.swift)

extension ClassicPlayerView {
    var collectionPanel: some View { CollectionPanel(ui: ui, current: item, classic: classic) { play($0) } }
}
