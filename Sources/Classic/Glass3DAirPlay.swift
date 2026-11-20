import AVKit
import SwiftUI

// AirPlay in the Glass3D player: the system route picker as a bar button (right after Cast), and the glass
// "Playing on <device>" card shown instead of the black video while the picture is on the TV.

/// The bar's AirPlay button: AVRoutePickerView (the system's device list), white like the other bar icons,
/// accent while AirPlay is on, same size and hover as the other buttons.
struct Glass3DAirPlayButton: View {
    let player: AVPlayer?
    let help: String
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    /// Clicked: the system's AirPlay menu is open, so no tooltip until the pointer leaves the button.
    @State private var clicked = false
    /// Detail page AirPlay start: glows when the menu couldn't be opened (Glass3DAirPlayDetail.swift)
    @ObservedObject private var detailStart = AirPlayDetailStart.shared

    var body: some View {
        RoutePicker(player: player, accent: NSColor(Theme.accent(accentName)), help: clicked ? "" : help) { clicked = true }
            .frame(width: 24, height: 24)
            .frame(width: 42, height: 38)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0)).padding(.vertical, 2).allowsHitTesting(false))
            .overlay(Capsule().strokeBorder(Theme.accent(accentName), lineWidth: 2).padding(.vertical, 2)
                .shadow(color: Theme.accent(accentName), radius: 6)
                .opacity(detailStart.pulse ? 1 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
            .onHover { h in
                withAnimation(Glass3DTokens.Motion.fast) { hover = h }
                if !h { clicked = false }
            }
            .helpLabel(clicked ? "" : help)
    }
}

private struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer?
    let accent: NSColor
    let help: String
    let onClick: () -> Void

    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?
        weak var player: AVPlayer?
        var onClick: () -> Void = {}
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.toolTip = help
        style(v)
        let c = context.coordinator
        c.view = v
        c.player = player
        c.onClick = onClick
        openForDetailStart(v)
        // A click opens the system menu: note it (the button's tooltip would show through the menu). The monitor only
        // observes: it always hands the event on unchanged, and the SwiftUI state change waits until the click has
        // been delivered, so the picker's button gets its mouse-down and nothing redraws under it meanwhile.
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak c] e in
            if let c, let v = c.view as? AVRoutePickerView, e.window === v.window,
               v.bounds.contains(v.convert(e.locationInWindow, from: nil)) {
                AirPlayMenu.opened(picker: v, expected: c.player)
                let f = c.onClick
                DispatchQueue.main.async { f() }
            } else if let c, e.window === c.view?.window, AirPlayMenu.open {
                AirPlayMenu.closed("menu closed (click in the player)")
            }
            return e
        }
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.player = player
        style(v)
        openForDetailStart(v)
        let tip = help.isEmpty ? nil : help
        if v.toolTip != tip { v.toolTip = tip }
    }

    static func dismantleNSView(_ v: AVRoutePickerView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }

    /// Started from the detail page's AirPlay pill: open the system menu once (Glass3DAirPlayDetail.swift).
    private func openForDetailStart(_ v: AVRoutePickerView) {
        let s = AirPlayDetailStart.shared
        // Not before the picker routes the player: a pick with no player moves only the Mac's sound
        guard s.wantsMenu, let p = player, v.player === p else { return }
        s.claimMenu()
        AirPlayMenu.opened(picker: v, expected: p)
        AirPlayDetailStart.openMenu(in: v) { AirPlayDetailPlayerHook.clicked($0) }
    }

    private func style(_ v: AVRoutePickerView) {
        // The picker must route the AVPlayer that plays: re-set whenever the player instance changes
        if let p = player, !p.allowsExternalPlayback { p.allowsExternalPlayback = true }
        if v.player !== player {
            v.player = player
            DebugLog.write("airplay: picker player \(player == nil ? "cleared" : "set")")
        }
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.8), for: .normalHighlighted)
        v.setRoutePickerButtonColor(accent, for: .active)
        v.setRoutePickerButtonColor(accent.withAlphaComponent(0.8), for: .activeHighlighted)
    }
}

/// The system AirPlay menu is open (opened from the bar's picker): the player keeps its controls (and so the picker,
/// the menu's target) on screen until the menu closes, as for the Cast menu. Ends on the menu's end of tracking, a
/// route change, or after 60 s at most.
@MainActor
enum AirPlayMenu {
    private static var openedAt: Date?
    private static var observers: [NSObjectProtocol] = []
    nonisolated static let maxOpen: TimeInterval = 60

    nonisolated static func isOpen(openedAt: Date?, now: Date) -> Bool {
        openedAt.map { now.timeIntervalSince($0) < maxOpen } ?? false
    }
    static var open: Bool { isOpen(openedAt: openedAt, now: Date()) }

    static func opened(picker: AVRoutePickerView, expected: AVPlayer?) {
        openedAt = Date()
        let p = picker.player
        DebugLog.write("airplay: menu opened (picker player \(p == nil ? "none" : "set"), matches=\(p != nil && p === expected), allowsExternalPlayback=\(p?.allowsExternalPlayback ?? false))")
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { closed("menu closed") }
            })
        }
        // What the pick did, once the route had time to come up (audio-only AirPlay: sound moves, the picture stays;
        // macOS has no AVPlayer.externalPlaybackType, so the audio route tells it)
        for delay in [3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak picker] in
                MainActor.assumeIsolated {
                    let ext = picker?.player?.isExternalPlaybackActive ?? false
                    let audio = AirPlayRoute.deviceName()
                    DebugLog.write("airplay: after menu \(Int(delay)) s: external playback active=\(ext), audio route=\(audio ?? "this Mac")\(audio != nil && !ext ? " (audio-only AirPlay)" : "")")
                }
            }
        }
    }

    static func closed(_ why: String) {
        guard openedAt != nil else { return }
        openedAt = nil
        DebugLog.write("airplay: \(why)")
    }
}

/// "Playing on <device>": the film's backdrop dimmed, a dark glass card in the middle. Clicks pass through to the
/// player (click to pause, controls), which keep driving the TV.
struct AirPlayPlayingCard: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    let device: String

    var body: some View {
        ZStack {
            CachedImage(url: item.backdropId.flatMap { emby.image($0, "Backdrop", width: 1280) }) { phase in
                if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) } else { Color.black }
            }
            .overlay(Color.black.opacity(0.62))
            .clipped()
            .ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "airplayvideo").cvFont(40, weight: .medium)
                Text("Playing on \(device)").cvFont(18, weight: .semibold).multilineTextAlignment(.center)
                Text(item.Name).cvFont(13).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 36).padding(.vertical, 26)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous).fill(Color.black.opacity(0.35)))
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75))
            .environment(\.colorScheme, .dark)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
