import AppKit
import Combine

/// A menu in the menu bar after Help, titled with the connected server's name (both themes): the current server
/// and user, the other saved servers (click to switch), and Switch Server…. Hidden while signed out.
/// SwiftUI's CommandMenu can't go after Help, so it is an AppKit item appended to the main menu, put back when a
/// SwiftUI menu rebuild drops it.
@MainActor
final class ServerMenu: NSObject {
    static let shared = ServerMenu()

    /// The menu's title: the server's name, else its host, else the address; at most `cap` characters (…).
    nonisolated static func title(name: String, address: String, cap: Int = 30) -> String {
        var t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = URL(string: address)?.host ?? address.trimmingCharacters(in: .whitespacesAndNewlines) }
        if t.count > cap { t = String(t.prefix(max(1, cap - 1))).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    private weak var emby: Emby?
    private var subs = Set<AnyCancellable>()
    private let item = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
    private var updating = false

    func attach(_ emby: Emby) {
        guard self.emby !== emby else { return }
        self.emby = emby
        subs.removeAll()
        // server, user and the saved list: rebuild after the change has landed
        emby.$server.combineLatest(emby.$userId, emby.$token, emby.$servers)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: NSMenu.didAddItemNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSMenu.didRemoveItemNotification),
                   NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.ensurePlaced() } }
            .store(in: &subs)
        refresh()
    }

    /// The item is in the main menu, last (after Help), and shown only while signed in.
    private func ensurePlaced() {
        guard !updating, let main = NSApp.mainMenu, let emby else { return }
        updating = true
        defer { updating = false }
        let want = emby.loggedIn
        let idx = main.index(of: item)
        if !want {
            if idx >= 0 { main.removeItem(item) }
            return
        }
        if idx < 0 { main.addItem(item) }
        else if idx != main.numberOfItems - 1 { main.removeItem(item); main.addItem(item) }
    }

    private func refresh() {
        guard let emby else { return }
        let title = Self.title(name: emby.currentServer?.name ?? "", address: emby.server)
        let menu = NSMenu(title: title)
        let user = emby.currentServer?.user ?? ""
        let current = NSMenuItem(title: "✓ " + title + (user.isEmpty ? "" : " (\(user))"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        let others = emby.servers.filter { $0.id != emby.server.lowercased() }
        for s in others {
            let t = Self.title(name: s.name, address: s.url)
            let mi = NSMenuItem(title: t + (s.user.isEmpty ? "" : " (\(s.user))"), action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.id
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let sw = NSMenuItem(title: "Switch Server…", action: #selector(switchServer), keyEquivalent: "")
        sw.target = self
        menu.addItem(sw)
        menu.autoenablesItems = false
        item.title = title
        item.submenu = menu
        ensurePlaced()
    }

    @objc private func switchServer() { emby?.switchServer() }

    /// Another saved server: signs in with its saved session; when that has expired, the server list opens.
    @objc private func pick(_ sender: NSMenuItem) {
        guard let emby, let id = sender.representedObject as? String,
              let s = emby.servers.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            switch await emby.resume(s) {
            case .ok: break
            case .expired: emby.switchServer()   // the server list, to sign in again
            case .unreachable: NSSound.beep()    // stay on the current server
            }
        }
    }
}
