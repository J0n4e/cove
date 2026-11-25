import SwiftUI
import AppKit

extension View {
    /// The intro pills sit over the player, whose tap gesture toggles pause. Give the whole pill a hit shape
    /// and swallow taps that miss its Button, so a click never falls through and pauses the episode.
    func introPillConsumesClicks() -> some View {
        contentShape(Rectangle()).onTapGesture {}
    }
}


/// While the 'Watch intro' pill is on screen, Space plays the intro instead of pausing (owner). An app-level key
/// monitor, so it works whatever has the keyboard focus (the player's own Space handler can miss it).
struct SpaceWatchesIntro: ViewModifier {
    let action: () -> Void
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    let plain = e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                    guard e.keyCode == 49, plain, !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
                    action()
                    return nil
                }
            }
            .onDisappear {
                if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            }
    }
}

extension View {
    func spaceWatchesIntro(_ action: @escaping () -> Void) -> some View { modifier(SpaceWatchesIntro(action: action)) }
}
