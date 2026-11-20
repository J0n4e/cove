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

    var body: some View {
        RoutePicker(player: player, accent: NSColor(Theme.accent(accentName)), help: clicked ? "" : help) { clicked = true }
            .frame(width: 24, height: 24)
            .frame(width: 42, height: 38)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0)).padding(.vertical, 2).allowsHitTesting(false))
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
        c.onClick = onClick
        // A click opens the system menu: note it (the button's tooltip would show through the menu)
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak c] e in
            if let c, let v = c.view, e.window === v.window, v.bounds.contains(v.convert(e.locationInWindow, from: nil)) {
                c.onClick()
            }
            return e
        }
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        context.coordinator.onClick = onClick
        v.toolTip = help.isEmpty ? nil : help
        style(v)
    }

    static func dismantleNSView(_ v: AVRoutePickerView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }

    private func style(_ v: AVRoutePickerView) {
        if v.player !== player { v.player = player }
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.8), for: .normalHighlighted)
        v.setRoutePickerButtonColor(accent, for: .active)
        v.setRoutePickerButtonColor(accent.withAlphaComponent(0.8), for: .activeHighlighted)
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
