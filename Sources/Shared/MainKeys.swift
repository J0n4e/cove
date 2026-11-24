import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// The main window's Esc rule, as a pure decision.
enum MainKeys {
    static let escKeyCode: UInt16 = 53
    /// Esc leaves the main window's full screen only when nothing else wants it: no modifiers, not while typing
    /// in a field, not while a menu, list or the search pill is open (Esc closes those first), not in the player.
    static func escLeavesFullScreen(fullScreen: Bool, modifiers: Bool = false, typing: Bool, menuOpen: Bool,
                                    searchOpen: Bool, playing: Bool = false) -> Bool {
        fullScreen && !modifiers && !typing && !menuOpen && !searchOpen && !playing
    }
}

/// Keys in the main window: ⌘F opens Search, "H" goes Home, ⌘← goes Back (as ⌘[ does), ← → turn the Home banner,
/// F / ⌃⌘F toggle full screen and Esc leaves it. Not while typing in a field (⌘← moves the cursor there), not in
/// the player.
enum SearchKey {
    /// `escBusy`: something in the window takes Esc first (profile menu, search pill, a glass list).
    static func install(isPlaying: @escaping () -> Bool, focus: @escaping () -> Void,
                        home: @escaping () -> Void, back: @escaping () -> Void,
                        banner: @escaping (Int) -> Bool, escBusy: @escaping () -> Bool = { false }) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard let w = ev.window, w.title != "Player", !(w is PanelWindow), w.attachedSheet == nil, w.sheetParent == nil,
                  !(w.firstResponder is NSText), !isPlaying() else { return ev }
            let mods = ev.modifierFlags.intersection([.command, .control, .option, .shift])
            // Esc: out of full screen (the open menu, list or search pill closes first: their own Esc runs)
            if ev.keyCode == MainKeys.escKeyCode {
                let busy = escBusy() || DropdownCenter.openLists > 0
                guard MainKeys.escLeavesFullScreen(fullScreen: w.styleMask.contains(.fullScreen), modifiers: !mods.isEmpty,
                                                   typing: false, menuOpen: busy, searchOpen: false) else { return ev }
                w.toggleFullScreen(nil)
                return nil
            }
            if ev.keyCode == 123 && mods == .command { back(); return nil }   // ⌘←
            // ⌘F: the Mac's usual Find shortcut opens search (the only one)
            if mods == .command, ev.charactersIgnoringModifiers?.lowercased() == "f" { focus(); return nil }
            if mods.isEmpty && (ev.keyCode == 123 || ev.keyCode == 124) {         // ← →, only on Home
                return banner(ev.keyCode == 123 ? -1 : 1) ? nil : ev
            }
            // ⌃⌘F: macOS's own full-screen shortcut, handled here too (the app's menus don't carry it on every setup)
            if mods == [.control, .command], ev.charactersIgnoringModifiers?.lowercased() == "f" { w.toggleFullScreen(nil); return nil }
            // F: the main window in/out of full screen, like F in the player (⌃⌘F, the Mac's own, works too)
            if mods.isEmpty, ev.charactersIgnoringModifiers?.lowercased() == "f" { w.toggleFullScreen(nil); return nil }
            // H: Home (S for search was dropped for ⌘F, owner)
            guard mods.subtracting(.shift).isEmpty, ev.charactersIgnoringModifiers?.lowercased() == "h" else { return ev }
            home()
            return nil
        }
    }
}

/// State shared between the page area and the title bar's navigation buttons.
final class NavState: ObservableObject {
    static let shared = NavState()
    @Published var sel = "home"
    /// Bumped when the page already shown is clicked again (sidebar or top bar); the library reloads on it.
    @Published var reselect = 0
    @Published var query = ""
    @Published var searchOpen = false
    /// Goes up to put the cursor in the search field (the S key)
    @Published var focusSearch = 0
    /// ← → on Home: the banner turns one page that way
    struct Nudge: Equatable { let id = UUID(); let dir: Int }
    @Published var bannerNudge: Nudge?
    @Published var activeCount = 0
    @Published var showSettings = false
    var popToRoot: () -> Void = {}
    /// Pushes an item's page (for views outside SwiftUI navigation, as the AppKit poster grid)
    var open: (Item) -> Void = { _ in }
    /// Pushes any page (a person, from the AppKit grid's header)
    var push: (any Hashable) -> Void = { _ in }

    /// After a server or user change (switch, sign-in, sign-out): back to Home with no pushed pages and the
    /// search closed, so no page of the previous server (Favorites, a library id it alone had) stays selected.
    func reset() {
        sel = "home"; query = ""; searchOpen = false
        popToRoot()
    }

    /// Pages that exist on every server; any other selection is a library id.
    static let fixedPages: Set<String> = ["home", "favorites", "nowplaying", "recent"]

    /// The selection to keep once the library list is known: a library that isn't in it goes back to Home.
    /// An empty list (still loading) keeps the selection.
    static func selection(_ sel: String, libIds: [String]) -> String {
        if fixedPages.contains(sel) || libIds.isEmpty || libIds.contains(sel) { return sel }
        return "home"
    }
}

/// Removes the toolbar's default left-aligned title (`ToolbarDefaultItemKind.title` needs macOS 15).
struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}

/// Confirmation pill at the bottom of the window after a favorite or watched change; fades after 2 s.
struct ToastOverlay: View {
    @EnvironmentObject var emby: Emby
    var raised = false   // the search box is open at the bottom: sit above it
    var body: some View {
        VStack {
            Spacer()
            if let t = emby.toast {
                Label(t.text, systemImage: t.icon)
                    .coveFont(size: 14, weight: .semibold).lineLimit(1)
                    .toastStyle()   // the shared toast look
                    .padding(.bottom, raised ? 80 : Glass3DTokens.Space.xxl)
                    .transition(.toast())
                    .id(t.id)
                    .task(id: t.id) {
                        try? await Task.sleep(for: .seconds(2))
                        if emby.toast?.id == t.id { emby.toast = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Glass3DTokens.Toast.animation, value: emby.toast)
        .allowsHitTesting(false)
    }
}
