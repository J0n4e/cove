import IOKit.pwr_mgt
import SwiftUI
import AVKit

/// The subtitle appearance panel: dark glass in the Classic theme, the plain grey panel otherwise.
struct AppearanceSurface: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.modifier(PanelSurface(classic: true)).padding(.vertical, 24).padding(.trailing, 24) }
        else { content.background(Color(white: 0.16).opacity(0.97)) }
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
        .scrollHover($hover)
        .animation(.easeOut(duration: 0.12), value: hover || dragging)
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

// MARK: - Player (inside the main window)

struct ClassicPlayerView: View {
    @EnvironmentObject var emby: Emby
    @StateObject private var model = PlayerModel()
    let req: PlayRequest
    /// Classic theme: glass buttons. These controls can also be picked under the Glass theme (Settings →
    /// Playback → Player controls); there they keep their plain look.
    @Environment(\.classicGlass) private var classic
    @Environment(\.dropdownCenter) private var dropdowns

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
            guard !Task.isCancelled else { return }
            // A glass list (subtitles, quality) is open: keep the controls until it closes
            if dropdowns?.list != nil { poke(); return }
            if model.playing && panel == nil {
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
                    Text("Loading subtitles…").cvFont(14, weight: .medium).glossyLettering()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .modifier(TimeBubble(classic: true))   // dark glass, as the time above the timeline
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
                    .cvFont(fs, weight: .medium)
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
                    if let l = episodeLine { Text(l).cvFont(16, weight: .medium).opacity(0.85) }
                    Text(item.heroTitle).cvFont(28, weight: .bold)
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
            Image(systemName: name).cvFont(size, weight: .medium)
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
                            Text(r == 1 ? "1×" : String(format: "%g×", r)).cvFont(classic ? 12 : 14, weight: .semibold)
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
                Text(label).cvFont(12, weight: .medium).foregroundColor(.white.opacity(0.75))
                GlassPicker(selection: sel, options: opts, maxWidth: 300)
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
                Button { withAnimation { panel = .subtitles } } label: { Image(systemName: "xmark").cvFont(18, weight: .semibold) }
                    .buttonStyle(.plainHand)
                Text("Subtitle Appearance").cvFont(18, weight: .bold)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dropdown("Text size", $subTextSize, Self.sizes.map { ($0.0, $0.1) })
                    dropdown("Text color", $subColor, Self.colors.map { ($0.0, $0.1) })
                    dropdown("Drop shadow", $subShadow, Self.shadows)
                    dropdown("Background color", $subBg, Self.bgs.map { ($0.0, $0.1) })
                    Text("Subtitle Position").cvFont(20, weight: .bold).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        dropdown("Bottom Edge Position", $subBottom, [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") })
                        Text("Set the vertical position of the subtitles relative to the bottom of the screen.")
                            .cvFont(13).foregroundColor(.secondary)
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
        Image(systemName: name).cvFont(18, weight: .medium)
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
            Image(systemName: "pip").cvFont(44)
            Text("Playing in picture in picture").cvFont(16, weight: .medium)
        }.opacity(0.6).allowsHitTesting(false)
    }

    // MARK: Scrub preview

    @ViewBuilder var scrubPreview: some View {
        let x: CGFloat? = scrubbing ? CGFloat(scrub / max(model.duration, 1)) * sliderW : hoverX
        if let x, model.duration > 0 {
            let t = Double(max(0, min(x, sliderW)) / max(sliderW, 1)) * model.duration
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
                    Text("Intro skipped").cvFont(15, weight: .semibold)
                    Button("Watch intro") { model.watchIntro() }.buttonStyle(.plainHand)
                        .cvFont(15, weight: .semibold).foregroundColor(accent)
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
                Text("Up next").cvFont(12, weight: .semibold).foregroundColor(.secondary)
                Text("S\(n.ParentIndexNumber ?? 0):E\(n.IndexNumber ?? 0) · \(n.Name)")
                    .cvFont(15, weight: .semibold).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 10) {
                    Button { play(n) } label: {
                        Text("Play now").cvFont(14, weight: .semibold)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .classicGlassPill()
                    }.buttonStyle(HoverButton())
                    Button { upNextCancelled = true } label: {
                        Text("Cancel").cvFont(14, weight: .semibold)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .classicGlassPill()
                    }.buttonStyle(HoverButton())
                }
                if autoNext {
                    Text("Next starts in \(classicSecsLeft)s")
                        .cvFont(11).foregroundColor(.secondary)
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
                    Text("Playback info").cvFont(13, weight: .bold)
                    ForEach(Array(infoLines.enumerated()), id: \.offset) { _, l in
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
        let seasons = Array(Set(episodes.map { $0.ParentIndexNumber ?? 0 })).sorted()
        let list = episodes.filter { ($0.ParentIndexNumber ?? 0) == pickerSeason }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Episodes").cvFont(18, weight: .bold)
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
                        Image(systemName: "speaker.wave.2.fill").cvFont(18).foregroundColor(.white)
                            .padding(6).background(Circle().fill(Color.black.opacity(0.6)))
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
                    Text(c.Name ?? "Chapter \(i + 1)").cvFont(15).lineLimit(2)
                    Text(fmt(c.start)).cvFont(13) { $0.monospacedDigit() }.foregroundColor(.secondary)
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
