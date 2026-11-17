import AppKit
import SwiftUI

// Glass3D player: a plain black title-bar area with no close / minimise / zoom buttons (owner's choice).
// The window's title bar is made transparent with a black window background, and the three standard window
// buttons are hidden once when the player appears and again after leaving full screen. Nothing animates or fades;
// nothing shows them again during playback. In full screen the buttons are given back to the system's own
// reveal-on-hover bar, so full screen behaves as before. Leaving the player restores the window exactly as it was
// (the inline player shares the main window, whose traffic lights must come back).

/// Reports the player's window (as WindowReader) and, when `black` is on, styles its title bar as above.
struct ClassicPlayerWindowProbe: NSViewRepresentable {
    let black: Bool
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe { Probe(black: black, onWindow: onWindow) }
    func updateNSView(_ v: Probe, context: Context) {}
    static func dismantleNSView(_ v: Probe, coordinator: ()) { v.restore() }

    final class Probe: NSView {
        let black: Bool
        let onWindow: (NSWindow?) -> Void
        private weak var styled: NSWindow?
        private var saved: ClassicPlayerTitleBar.Saved?
        private var observers: [NSObjectProtocol] = []

        init(black: Bool, onWindow: @escaping (NSWindow?) -> Void) {
            self.black = black; self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { self.onWindow(w) }
            guard black else { return }
            if w !== styled { restore() }
            guard let w, styled == nil else { return }
            styled = w
            saved = ClassicPlayerTitleBar.save(w)
            ClassicPlayerTitleBar.apply(w)
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: w, queue: .main) { _ in
                ClassicPlayerTitleBar.setButtonsHidden(w, false)   // full screen: the system's own bar, unchanged
            })
            observers.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { _ in
                ClassicPlayerTitleBar.apply(w)
            })
        }

        func restore() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if let w = styled, let s = saved { ClassicPlayerTitleBar.restore(w, s) }
            styled = nil; saved = nil
        }
    }
}

/// The window changes behind the black player title bar (pure AppKit, no SwiftUI state).
enum ClassicPlayerTitleBar {
    static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    struct Saved {
        let transparent: Bool
        let visibility: NSWindow.TitleVisibility
        let background: NSColor
        let hidden: [Bool]
    }

    static func save(_ w: NSWindow) -> Saved {
        Saved(transparent: w.titlebarAppearsTransparent, visibility: w.titleVisibility, background: w.backgroundColor,
              hidden: buttons.map { w.standardWindowButton($0)?.isHidden ?? false })
    }

    static func apply(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .black
        if !w.styleMask.contains(.fullScreen) { setButtonsHidden(w, true) }
    }

    static func setButtonsHidden(_ w: NSWindow, _ hidden: Bool) {
        for b in buttons { w.standardWindowButton(b)?.isHidden = hidden }
    }

    static func restore(_ w: NSWindow, _ s: Saved) {
        w.titlebarAppearsTransparent = s.transparent
        w.titleVisibility = s.visibility
        w.backgroundColor = s.background
        for (b, h) in zip(buttons, s.hidden) { w.standardWindowButton(b)?.isHidden = h }
    }

    /// Colour of the strip above the video: black in Glass3D, the v1.17.6 grey otherwise.
    static func stripColor(glass3D: Bool) -> Color { glass3D ? .black : ClassicPlayerView.titleBarGray }
}
