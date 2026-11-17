import AppKit

/// Whether any of the app's windows can be seen, for background refreshes that only feed what's on screen.
@MainActor
enum AppVisibility {
    static var isVisible: Bool { !NSApp.isHidden && NSApp.occlusionState.contains(.visible) }
}
