import AppKit
import Combine
import SwiftUI

/// The player screen's state and decisions, shared by the Glass and Classic players (the views keep only
/// layout, styling and animation). One per player view (`@StateObject`); it owns that view's `PlayerModel`,
/// the playback engine, and passes its changes on, so the view redraws exactly as when it observed it directly.
@MainActor
final class PlayerUIModel: ObservableObject {
    /// The few places where the two players behave differently (not just look different).
    enum Style {
        /// PlayerView: plain auto-hide.
        case glass
        /// ClassicPlayerView: the controls stay while one of its glass lists (subtitles, quality) is open.
        case classic
    }

    enum Panel { case subtitles, appearance, chapters, episodes, syncPlay }

    let style: Style
    let player: PlayerModel
    private var forward: AnyCancellable?

    // Controls and panels
    @Published var panel: Panel?
    @Published var showUI = true
    private var hideTask: Task<Void, Never>?
    /// Classic: whether one of its glass lists is open (set by the view; it lives in the view's environment).
    var listOpen: @MainActor () -> Bool = { false }
    @Published var showInfo = false
    @Published var infoLines: [(String, String)] = []

    // Full screen (the window work itself stays in the views)
    @Published var isFullScreen = false
    @Published var fsBusy = false   // a full screen animation is running

    // Timeline scrubbing and hover preview
    @Published var scrubbing = false
    @Published var scrub: Double = 0
    @Published var hoverX: CGFloat?
    @Published var sliderW: CGFloat = 1

    // Episodes, up next
    @Published var episodes: [Item] = []
    @Published var pickerSeason = 1
    @Published var upNextCancelled = false
    var switching = false
    /// Collection mode (Play collection): the films replace the episode list (CollectionPlay.swift)
    @Published var collection: CollectionQueue?
    /// Jellyfin's credits marker for a film in collection mode (Emby's is in the chapters)
    @Published var creditsMarker: Double?

    // Esc / F key monitor
    private var keyMonitor: Any?
    let playerWin = WeakWindow()   // the window this player is in

    init(style: Style, player: PlayerModel? = nil) {
        self.style = style
        self.player = player ?? PlayerModel()
        // The views read the engine through this model: pass its changes on
        forward = self.player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Auto-hide

    /// Seconds without a mouse move or key before the controls hide.
    nonisolated static let hideDelay: Double = 3

    enum HideDecision: Equatable { case hide, keep, waitAgain }

    /// What happens when the hide delay ends: a list still open waits another round (Classic), a panel open or a
    /// paused video keeps the controls, otherwise they hide.
    nonisolated static func hideDecision(playing: Bool, panelOpen: Bool, listOpen: Bool) -> HideDecision {
        if listOpen { return .waitAgain }
        return playing && !panelOpen ? .hide : .keep
    }

    /// The next episode is starting in the same player (autoplay, Space/Return on Up next, Up next's Play, the
    /// Episodes panel, a group advancing): the new player opens without bringing up the controls (owner).
    /// Read and cleared once by the new player view.
    static var quietNextStart = false
    /// Opened by the detail page's AirPlay pill: controls up, the AirPlay menu opens, paused until it's handled
    @Published var openAirPlayMenu = false
    static func takeQuietStart() -> Bool { defer { quietNextStart = false }; return quietNextStart }

    /// The new player for the next episode: controls hidden (a fresh model starts with them shown), and the first
    /// hover event, which SwiftUI sends when the view appears under a still pointer, doesn't wake them.
    func startQuiet() {
        hideTask?.cancel()
        showUI = false
        swallowFirstHover = true
    }
    private var swallowFirstHover = false

    /// Shows the controls and starts the hide countdown again.
    func poke() {
        showUI = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hideDelay))
            guard let self, !Task.isCancelled else { return }
            switch Self.hideDecision(playing: self.player.playing, panelOpen: self.panel != nil,
                                     listOpen: self.style == .classic && (self.listOpen() || CastPickerState.shared.open)) {
            case .waitAgain: self.poke()
            case .keep: break
            case .hide:
                withAnimation { self.showUI = false }
                // Full screen: hide the pointer with the controls; it comes back when the mouse moves
                if self.isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    /// Where the pointer was at the last hover event (view coordinates).
    private var lastPointer: CGPoint?

    /// Whether a hover event is a real mouse move. SwiftUI also sends hover events when the pointer stands
    /// still and the views under it change (the Up next card or a toast appearing): those must not wake the controls.
    nonisolated static func isPointerMove(from last: CGPoint?, to p: CGPoint) -> Bool {
        guard let last else { return true }
        return abs(p.x - last.x) > 0.5 || abs(p.y - last.y) > 0.5
    }

    /// The player's hover handler: shows the controls only when the mouse really moved.
    func pointer(_ phase: HoverPhase) {
        guard case .active(let p) = phase else { return }
        if swallowFirstHover { swallowFirstHover = false; lastPointer = p; return }
        let moved = Self.isPointerMove(from: lastPointer, to: p)
        lastPointer = p
        if moved { poke() }
    }

    /// A click on the picture: close a panel, else play/pause (or show/hide the controls).
    func tap(clickToPause: Bool) {
        if panel != nil { panel = nil }
        else if clickToPause { player.togglePlay(); poke() }
        else { withAnimation { showUI.toggle() } }
    }

    /// Controls or a panel on screen (subtitles move up above them).
    var controlsVisible: Bool { showUI || panel != nil }

    // MARK: Panels

    func toggleEpisodes(_ item: Item) {
        if panel != .episodes { pickerSeason = item.ParentIndexNumber ?? 1 }
        panel = panel == .episodes ? nil : .episodes
    }

    func toggleChapters() { panel = panel == .chapters ? nil : .chapters }

    /// The SyncPlay (watch together) panel.
    func toggleSyncPlay() { panel = panel == .syncPlay ? nil : .syncPlay }

    /// The subtitles / audio / quality / speed panel.
    func toggleMediaPanel() { panel = panel == nil ? .subtitles : nil }

    // MARK: Keys

    enum SeekKey { case left, right }

    /// Seconds the arrow keys seek (the Skip setting, back or forward).
    nonisolated static func seekDelta(_ key: SeekKey, skipSeconds: Int) -> Double {
        key == .left ? -Double(skipSeconds) : Double(skipSeconds)
    }

    enum EscAction: Equatable { case closePanel, exitFullScreen, closePlayer }

    /// Esc: close a panel, else leave full screen (the video keeps playing), else close the player.
    nonisolated static func escAction(panelOpen: Bool, fullScreen: Bool) -> EscAction {
        panelOpen ? .closePanel : fullScreen ? .exitFullScreen : .closePlayer
    }

    /// Esc and F caught at the app level: AppKit sometimes swallows Esc before SwiftUI's key handlers see it
    /// (after full screen, and in the separate player window). Only in the player's own window: Esc in the main
    /// window must not stop a video playing in the separate one. Removed again by `removeKeyMonitor()`.
    func installKeyMonitor(toggleFullScreen: @escaping () -> Void, close: @escaping () -> Void) {
        removeKeyMonitor()
        let win = playerWin
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let w = win.window, ev.window === w,
                  w.attachedSheet == nil, w.sheetParent == nil else { return ev }
            // F also here: in the separate player window the SwiftUI key handler doesn't always get it
            if ev.keyCode == 3, ev.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               !(w.firstResponder is NSText) {
                if !ev.isARepeat { toggleFullScreen() }   // holding F must not toggle again and again
                return nil
            }
            guard ev.keyCode == 53 else { return ev }
            switch Self.escAction(panelOpen: self?.panel != nil, fullScreen: w.styleMask.contains(.fullScreen)) {
            case .closePanel: self?.panel = nil
            case .exitFullScreen: toggleFullScreen()
            case .closePlayer: close()
            }
            return nil
        }
    }

    func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    var hasKeyMonitor: Bool { keyMonitor != nil }

    // MARK: Time

    /// "1:02:03" / "2:03" for the timeline, the hover preview and chapters.
    nonisolated static func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    /// The clock time the video ends at, at the current speed.
    var endClock: String {
        let left = max(0, player.duration - player.time) / Double(max(player.speed, 0.1))
        return Self.clockFormat.string(from: Date().addingTimeInterval(left))
    }

    /// The timeline position: the dragged one while scrubbing.
    var shownTime: Double { scrubbing ? scrub : player.time }

    /// Time left, as shown after the timeline ("-12:34").
    var remainingText: String { "-" + Self.fmt(max(0, player.duration - shownTime)) }

    /// The timeline slider's binding and drag start/end.
    var timelineValue: Binding<Double> { Binding(get: { self.shownTime }, set: { self.scrub = $0 }) }

    func timelineEditing(_ editing: Bool) {
        if editing { scrub = player.time; scrubbing = true }
        else { player.seek(to: scrub); scrubbing = false }
    }

    func hover(_ ph: HoverPhase) {
        if case .active(let p) = ph { hoverX = p.x } else { hoverX = nil }
    }

    /// Where the preview points along the timeline (the drag while scrubbing, else the pointer), nil if nowhere.
    var previewX: CGFloat? { scrubbing ? CGFloat(scrub / max(player.duration, 1)) * sliderW : hoverX }

    /// The video time under a point of the timeline.
    nonisolated static func previewTime(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        Double(max(0, min(x, width)) / max(width, 1)) * duration
    }

    /// The preview's left edge: centred on the point, kept inside the timeline.
    nonisolated static func previewOffset(x: CGFloat, previewWidth w: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, x - w / 2), max(0, width - w))
    }

    // MARK: Volume

    func toggleMute() { player.volume = player.volume > 0 ? 0 : 1 }
    var volumeIcon: String { player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill" }
    var volumeBinding: Binding<Float> { Binding(get: { self.player.volume }, set: { self.player.volume = $0 }) }

    // MARK: Episodes / up next

    func index(of item: Item) -> Int? { episodes.firstIndex { $0.Id == item.Id } }
    func prevEp(_ item: Item) -> Item? { index(of: item).flatMap { $0 > 0 ? episodes[$0 - 1] : nil } }
    func nextEp(_ item: Item) -> Item? { index(of: item).flatMap { $0 + 1 < episodes.count ? episodes[$0 + 1] : nil } }
    /// Previous / next / episode list buttons.
    func hasEpisodeList(_ item: Item) -> Bool { (item.isEpisode || collection != nil) && episodes.count > 1 }

    /// The "Up next" card: the last 30 seconds of an episode longer than two minutes with a next one.
    nonisolated static func showUpNext(isEpisode: Bool, hasNext: Bool, cancelled: Bool, time: Double, duration: Double) -> Bool {
        guard isEpisode, hasNext, !cancelled, duration > 120 else { return false }
        return time >= duration - 30 && time < duration - 0.5
    }

    func showUpNext(_ item: Item) -> Bool {
        if collection != nil {   // collection mode: from the credits on
            return CollectionPlay.showUpNext(hasNext: nextEp(item) != nil, cancelled: upNextCancelled, time: player.time,
                                             duration: player.duration, marker: creditsMarker ?? player.creditsStart)
        }
        return Self.showUpNext(isEpisode: item.isEpisode, hasNext: nextEp(item) != nil, cancelled: upNextCancelled,
                        time: player.time, duration: player.duration)
    }

    /// Whole seconds until the episode ends ("Next starts in 12s").
    nonisolated static func secsLeft(time: Double, duration: Double) -> Int { max(0, Int((duration - time).rounded(.up))) }
    var secsLeft: Int { Self.secsLeft(time: player.time, duration: player.duration) }

    /// The end of the video: the next episode (auto play on, not cancelled), else close.
    func shouldAutoPlayNext(autoNext: Bool, _ item: Item) -> Item? {
        autoNext && !upNextCancelled ? nextEp(item) : nil
    }

    func loadEpisodes(_ emby: Emby, _ item: Item) async {
        if let c = collection { episodes = c.items; await loadCredits(emby, item); return }
        if item.isEpisode, let sid = item.SeriesId { episodes = await emby.episodes(sid) }
    }

    /// Episode list: its seasons and the episodes of the chosen one.
    var seasons: [Int] { Array(Set(episodes.map { $0.ParentIndexNumber ?? 0 })).sorted() }
    var seasonEpisodes: [Item] { episodes.filter { ($0.ParentIndexNumber ?? 0) == pickerSeason } }
    nonisolated static func seasonName(_ n: Int) -> String { n == 0 ? "Specials" : "Season \(n)" }

    /// The chapter playing now (index in `chapterList`).
    var currentChapter: Int? { player.chapterList.lastIndex { $0.c.start <= player.time } }

    func seekToChapter(_ c: Chapter) { player.seek(to: c.start); panel = nil }

    // MARK: Option lists (subtitles, audio, quality, speed)

    nonisolated static func trackTitle(_ st: MStream) -> String { st.DisplayTitle ?? "Track \(st.Index)" }

    /// Subtitles: "Off" first, then every track.
    nonisolated static func subtitleOptions(_ streams: [MStream]) -> [(Int?, String)] {
        [(nil, "Off")] + streams.map { (Optional($0.Index), trackTitle($0)) }
    }

    nonisolated static func audioOptions(_ streams: [MStream]) -> [(Int, String)] { streams.map { ($0.Index, trackTitle($0)) } }

    nonisolated static let qualities: [(Int, String)] = [(0, "Original"), (8_000_000, "1080p · 8 Mbps"),
                                             (4_000_000, "720p · 4 Mbps"), (1_500_000, "480p · 1.5 Mbps")]

    nonisolated static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    nonisolated static func speedLabel(_ r: Float) -> String { r == 1 ? "1×" : String(format: "%g×", r) }
    nonisolated static func speedHelp(_ r: Float) -> String { r == 1 ? "Normal speed" : "\(String(format: "%g", r))× speed" }

    /// Where the current choice is in a list (the first entry if it isn't there).
    nonisolated static func selectedIndex<T: Equatable>(_ options: [(T, String)], _ current: T) -> Int {
        options.firstIndex { $0.0 == current } ?? 0
    }

    var subtitleOptions: [(Int?, String)] { Self.subtitleOptions(player.subStreams) }
    var audioOptions: [(Int, String)] { Self.audioOptions(player.audioStreams) }

    func setSub(_ emby: Emby, _ idx: Int?) { Task { await player.setSub(emby, idx) } }
    func setAudio(_ emby: Emby, _ idx: Int) { Task { await player.setAudio(emby, idx) } }
    func setQuality(_ emby: Emby, _ q: Int) { Task { await player.setQuality(emby, q) } }
    func setSpeed(_ r: Float) { player.setSpeed(r) }

    // MARK: Subtitle appearance (Settings uses these lists too)

    nonisolated static let sizes: [(String, String, Double)] = [("smaller", "Smaller", 0.032), ("small", "Small", 0.038),
        ("normal", "Normal", 0.045), ("large", "Large", 0.055), ("larger", "Larger", 0.066)]
    nonisolated static let colors: [(String, String, Color)] = [("white", "White", .white), ("yellow", "Yellow", .yellow),
        ("gray", "Light gray", Color(white: 0.8)), ("black", "Black", .black)]
    nonisolated static let shadows: [(String, String)] = [("none", "None"), ("drop", "Drop shadow"), ("outline", "Outline"), ("raised", "Raised")]
    nonisolated static let bgs: [(String, String, Double)] = [("none", "Transparent", 0), ("semi", "Semi-transparent", 0.5), ("black", "Black", 1)]
    nonisolated static let bottomPositions: [(Double, String)] = [0, 5, 10, 15, 20, 25, 30].map { (Double($0), "\($0)%") }

    /// Subtitle distance from the bottom: the user's setting, but above the controls while they're showing.
    nonisolated static func subLift(height: CGFloat, bottomPercent: Double, controlsVisible: Bool) -> CGFloat {
        let base = height * bottomPercent / 100
        return controlsVisible ? max(base, 190) : base
    }
}
