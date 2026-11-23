import AppKit
import SwiftUI

/// Side windows (Settings, About, Help, Manage server, admin tools, update/messages) close by themselves as soon
/// as another window or another app becomes active (owner: "I close a window, check something, open it again").
/// They stay open while a view inside says it holds unsaved changes or a running action (`.keepsWindowOpen`),
/// while a system panel / sheet / alert of theirs is up, or while a window they opened is in front.
/// The decision is a pure function so it can be tested without AppKit.
enum AutoClose {
    /// What became key after the side window resigned.
    enum NewKey: Equatable {
        /// No key window in this app (a menu is tracking, or the app is switching): wait.
        case none
        /// The side window itself is key again.
        case itself
        /// A sheet, alert, popover, open/save panel or child window of the side window, or a window it opened.
        case related
        /// Any other window of this app (the main window, the player, another side window).
        case other
    }

    struct Situation: Equatable {
        var appActive: Bool
        var newKey: NewKey
        /// A view in the window holds unsaved changes or a running action.
        var keepOpen: Bool
        /// A sheet is attached or an app-modal panel/alert is running.
        var hasModal: Bool
        /// Shown less than `graceSeconds` ago (its own open animation / activation).
        var openedRecently: Bool
    }

    static let graceSeconds: TimeInterval = 0.5
    static let settleDelay: TimeInterval = 0.15

    static func shouldClose(_ s: Situation) -> Bool {
        if s.keepOpen || s.hasModal || s.openedRecently { return false }
        if !s.appActive { return true }   // another app came to the front
        return s.newKey == .other
    }

    static func openedRecently(shownAt: Date?, now: Date = Date()) -> Bool {
        guard let shownAt else { return false }
        return now.timeIntervalSince(shownAt) < graceSeconds
    }
}

/// The AppKit side, used by `PanelWindow`.
@MainActor
enum AutoCloseMonitor {
    private static var started = false

    /// Watches app deactivation once; every visible PanelWindow then gets checked.
    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { checkAll() }
        }
    }

    static func checkAll() {
        for case let w as PanelWindow in NSApp.windows where w.isVisible { schedule(w) }
    }

    /// Waits a short runloop hop so NSApp.keyWindow / isActive describe the new state.
    static func schedule(_ w: PanelWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoClose.settleDelay) { [weak w] in
            guard let w else { return }
            MainActor.assumeIsolated { check(w) }
        }
    }

    static func check(_ w: PanelWindow) {
        guard w.isVisible, !w.isKeyWindow || !NSApp.isActive else { return }
        let s = AutoClose.Situation(appActive: NSApp.isActive, newKey: relation(of: NSApp.keyWindow, to: w),
                                    keepOpen: !w.keepOpenReasons.isEmpty,
                                    hasModal: w.attachedSheet != nil || NSApp.modalWindow != nil,
                                    openedRecently: AutoClose.openedRecently(shownAt: w.shownAt))
        guard AutoClose.shouldClose(s) else { return }
        DebugLog.write("AutoClose: \(w.title)")
        w.performClose(nil)
        if w.isVisible { w.close() }   // no close button/refusing delegate: still close (same windowWillClose work)
    }

    static func relation(of key: NSWindow?, to w: PanelWindow) -> AutoClose.NewKey {
        guard let key else { return .none }
        if key === w { return .itself }
        var p: NSWindow? = key
        while let c = p {
            if c.sheetParent === w || c.parent === w { return .related }
            if let pw = c as? PanelWindow, pw.opener === w { return .related }
            p = c.sheetParent ?? c.parent ?? (c as? PanelWindow)?.opener
        }
        // Popovers, tooltips and system panels that aren't attached: a non-PanelWindow NSPanel
        if key is NSPanel && !(key is PanelWindow) { return .related }
        return .other
    }
}

/// Marks the hosting window as "keep open" while `active` is true (unsaved changes, a running action).
private final class WindowHoldView: NSView {
    let token = UUID().uuidString
    var active = false { didSet { apply() } }
    private weak var holder: PanelWindow?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    func apply() {
        let w = window as? PanelWindow
        if holder !== w { holder?.keepOpenReasons.remove(token) }
        holder = w
        if active { w?.keepOpenReasons.insert(token) } else { w?.keepOpenReasons.remove(token) }
    }
    func release() { holder?.keepOpenReasons.remove(token) }
}

private struct WindowHold: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> WindowHoldView { WindowHoldView() }
    func updateNSView(_ v: WindowHoldView, context: Context) { v.active = active }
    static func dismantleNSView(_ v: WindowHoldView, coordinator: ()) { v.release() }
}

extension View {
    /// Keeps a side window from closing by itself when it loses focus while `active` is true.
    func keepsWindowOpen(_ active: Bool) -> some View {
        background(WindowHold(active: active).frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
