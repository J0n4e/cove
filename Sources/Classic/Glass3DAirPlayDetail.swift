import AppKit
import SwiftUI

// The AirPlay pill on detail pages (right after Cast): starts what the primary button plays (Resume when in progress,
// else Play; a collection plays/resumes in collection mode, like the Cast pill), PAUSED at its position, with the
// player's controls up and the system AirPlay menu opened from the bar's AirPlay button.
// Playback then starts by itself when the picture goes to a TV (external playback active), or, when no device was
// picked, once the menu closes (a menu click returns when it closes) or after a 5 s timeout: it plays here.
// If the picker's button can't be found the bar's AirPlay button glows in the accent for 2 s instead.

/// The hand-off from the detail page to the player (pure parts unit-tested in Tests/AirPlayDetailTests.swift).
@MainActor
final class AirPlayDetailStart: ObservableObject {
    static let shared = AirPlayDetailStart()

    enum Phase: Equatable { case idle, armed, menuOpen, done }
    /// How long an armed start waits for its player (a start that never comes doesn't leak into a later one).
    nonisolated static let armWindow: TimeInterval = 20
    /// Play here when no device was picked within this time after the menu was opened.
    nonisolated static let menuTimeout: TimeInterval = 5
    /// Delay before clicking the picker's button (the view must be in its window).
    nonisolated static let clickDelay: TimeInterval = 0.4
    /// A click that blocks at least this long was a menu tracked until it closed.
    nonisolated static let menuTrackedMin: TimeInterval = 0.3

    @Published private(set) var phase: Phase = .idle
    /// Fallback highlight of the bar's AirPlay button.
    @Published var pulse = false
    private var armedAt: Date?
    /// Set synchronously when a picker takes the menu (SwiftUI may update the picker several times)
    private var claimed = false

    /// The detail page's AirPlay pill, just before it starts playback.
    func arm() { armedAt = Date(); claimed = false; phase = .armed; DebugLog.write("airplay: detail start, menu requested") }

    nonisolated static func isArmed(phase: Phase, armedAt: Date?, now: Date) -> Bool {
        guard phase == .armed || phase == .menuOpen, let armedAt else { return false }
        return now.timeIntervalSince(armedAt) < armWindow
    }

    /// The player starts paused while this is true (PlayerModel.start).
    var holdsStart: Bool { Self.isArmed(phase: phase, armedAt: armedAt, now: Date()) }
    /// The bar's route picker should open its menu now.
    var wantsMenu: Bool { phase == .armed && !claimed && holdsStart }

    /// When to start playing (pure): on the TV as soon as the route is up, else here once the menu is gone.
    nonisolated static func shouldPlay(externalActive: Bool, menuClosed: Bool, sinceMenu: TimeInterval) -> Bool {
        externalActive || menuClosed || sinceMenu >= menuTimeout
    }

    /// Whether a click's duration means the menu was tracked (and is now closed).
    nonisolated static func menuClosed(clickDuration: TimeInterval) -> Bool { clickDuration >= menuTrackedMin }

    /// Called from the picker's NSView update: the published change waits for the next run loop turn.
    func claimMenu() {
        claimed = true
        DispatchQueue.main.async { if self.phase == .armed { self.phase = .menuOpen } }
    }
    func finish() { phase = .done; armedAt = nil }

    func fallback() {
        DebugLog.write("airplay: menu open fallback")
        withAnimation(Glass3DTokens.Motion.standard) { pulse = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Glass3DTokens.Motion.slow) { self.pulse = false }
        }
    }

    /// Opens the AVRoutePickerView's menu by clicking its internal button. `done(menuClosed)` reports whether the
    /// click came back after a tracked menu closed; nil when no button was found.
    static func openMenu(in picker: NSView, done: @escaping (Bool?) -> Void) {
        func attempt(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + clickDelay) {
                guard picker.window != nil else {
                    if tries > 0 { attempt(tries - 1) } else { done(nil) }
                    return
                }
                guard let b = button(in: picker) else { done(nil); return }
                let t0 = Date()
                b.performClick(nil)
                done(menuClosed(clickDuration: Date().timeIntervalSince(t0)))
            }
        }
        attempt(5)
    }

    private static func button(in v: NSView) -> NSButton? {
        for s in v.subviews {
            if let b = s as? NSButton { return b }
            if let b = button(in: s) { return b }
        }
        return nil
    }
}

/// The detail page pill: same circle, size and hover as the Cast pill.
struct AirPlayDetailButton: View {
    let model: DetailModel
    @EnvironmentObject var emby: Emby

    var body: some View {
        Button { model.playForAirPlay(emby: emby) } label: {
            Label("AirPlay", systemImage: "airplayvideo").classicGlassPill(size: 44).glass3DRoundOutline()
        }
        .buttonStyle(HoverButton()).helpLabel("AirPlay")
    }
}

extension DetailModel {
    /// Plays what the primary button would (Resume when in progress), armed for the AirPlay menu.
    func playForAirPlay(emby: Emby) {
        AirPlayDetailStart.shared.arm()
        if item.isBox {
            let films = kids
            let i = CollectionPlay.resumeIndex(films: films, position: { emby.resumeAt($0) }, played: { emby.isPlayed($0) }) ?? 0
            guard let q = CollectionPlay.queue(collection: item, films: films, start: i), let film = q.current else {
                AirPlayDetailStart.shared.finish(); return
            }
            emby.playCollection(q, start: emby.resumeAt(film))
            return
        }
        playNow()   // nil = from the resume point (0 when not started), the page's audio/subtitle choice
    }
}

/// In the player: keeps the controls up while the AirPlay menu is pending and starts playback when it's time.
/// Draws nothing.
struct AirPlayDetailPlayerHook: View {
    @ObservedObject var model: PlayerModel
    let ui: PlayerUIModel
    @ObservedObject private var start = AirPlayDetailStart.shared
    @State private var menuAt: Date?

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .onAppear { if start.holdsStart { ui.openAirPlayMenu = true; ui.poke() } }
            .onChange(of: start.phase) { _, p in if p == .menuOpen { menuAt = Date(); ui.poke() } }
            .onChange(of: model.airPlayActive) { _, on in if on { go("route active") } }
            .task(id: menuAt) {
                guard menuAt != nil else { return }
                try? await Task.sleep(for: .seconds(AirPlayDetailStart.menuTimeout))
                if !Task.isCancelled { go("no device picked") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .airPlayDetailMenuClosed)) { _ in go("menu closed") }
            .onDisappear { if ui.openAirPlayMenu { start.finish() } }
    }

    func go(_ why: String) {
        guard ui.openAirPlayMenu else { return }
        ui.openAirPlayMenu = false
        start.finish()
        DebugLog.write("airplay: detail start playing (\(why))")
        if !model.playing { model.togglePlay() }
        ui.poke()
    }

    /// Called by the bar's picker after its click (menuClosed nil = no button found).
    static func clicked(_ menuClosed: Bool?) {
        let s = AirPlayDetailStart.shared
        if menuClosed == nil { s.fallback() }
        // A tracked menu has closed: the hook plays now (if the route came up it has played already)
        if menuClosed == true { NotificationCenter.default.post(name: .airPlayDetailMenuClosed, object: nil) }
    }
}

extension Notification.Name {
    static let airPlayDetailMenuClosed = Notification.Name("CoveAirPlayDetailMenuClosed")
}

/// The detail row's TV button: only the one chosen in Settings → Playback (Cast also while a cast runs).
struct DetailTvButtons: View {
    let model: DetailModel
    @AppStorage(TvTarget.key) private var tvTarget = TvTarget.cast
    @ObservedObject private var castSession = CastSession.shared

    var body: some View {
        if TvTarget.shows(TvTarget.cast, tvTarget: tvTarget, casting: castSession.isCasting) { CastButton(model: model) }
        if TvTarget.shows(TvTarget.airplay, tvTarget: tvTarget) { AirPlayDetailButton(model: model) }
    }
}
