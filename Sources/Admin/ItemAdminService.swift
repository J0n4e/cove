import AppKit
import Foundation
import Combine

/// Bumped after an admin change to an item (refresh, identify, image edits), so the detail page and any view
/// that observes it reload that item's pictures. The new image tags themselves reach every poster through
/// `Emby.remember` (the links carry the tag), so the old cached picture is never shown again once a view redraws.
@MainActor
final class ItemAdminChanges: ObservableObject {
    static let shared = ItemAdminChanges()
    @Published private(set) var revision = 0
    @Published private(set) var changed: [String: Int] = [:]
    /// The item as read again after the change (pages swap their copy for it: new name, tags, picture links)
    let updates = PassthroughSubject<[String: Item], Never>()
    func bump(_ id: String, item: Item? = nil) {
        revision += 1; changed[id] = revision
        if let item { updates.send([id: item]) }
    }
}

/// Server calls of the item admin tools. Errors come back as plain sentences; tokens are never logged.
@MainActor
enum ItemAdminService {
    /// Sends one request; nil = OK, else the sentence to show. `data` receives the answer body on success.
    @discardableResult
    static func send(_ req: ItemAdminAPI.Request, emby: Emby, action: String, timeout: TimeInterval = 30,
                     data out: ((Data) -> Void)? = nil) async -> String? {
        guard let u = URL(string: emby.server + req.path) else { return "Couldn't \(action) (bad address)." }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = req.method
        emby.authorize(&r)
        if let ct = req.contentType { r.setValue(ct, forHTTPHeaderField: "Content-Type") }
        r.httpBody = req.body
        do {
            let (d, resp) = try await Net.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let m = ItemAdminAPI.message(status: code, action: action) {
                coveLog.error("item admin \(req.method, privacy: .public) \(action, privacy: .public): HTTP \(code)")
                return m
            }
            out?(d)
            return nil
        } catch {
            if (error as? URLError)?.code == .cancelled { return "Cancelled." }
            coveLog.error("item admin \(action, privacy: .public) failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return "Couldn't reach the server to \(action). Check the connection and try again."
        }
    }

    /// The item's raw record (image tags, refresh date, provider ids).
    static func record(_ id: String, emby: Emby) async -> [String: Any]? {
        var out: [String: Any]?
        let path = "/Users/\(ItemAdminAPI.p(emby.userId))/Items/\(ItemAdminAPI.p(id))?Fields=DateLastRefreshed,ProviderIds,Path,ProductionYear"
        _ = await send(.init(method: "GET", path: path), emby: emby, action: "read the item", timeout: 15) { d in
            out = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        return out
    }

    /// The metadata language/country of the item's library (nil when it can't be read or isn't set).
    static func libraryLanguage(_ id: String, emby: Emby) async -> (language: String?, country: String?)? {
        var folders: Data?, ancestors: Data?
        _ = await send(.init(method: "GET", path: "/Library/VirtualFolders"), emby: emby, action: "read the libraries", timeout: 15) { folders = $0 }
        guard folders != nil else { return nil }
        _ = await send(.init(method: "GET", path: "/Items/\(ItemAdminAPI.p(id))/Ancestors?UserId=\(ItemAdminAPI.p(emby.userId))"),
                       emby: emby, action: "read the item", timeout: 15) { ancestors = $0 }
        guard let folders, let ancestors else { return nil }
        return ItemAdminAPI.libraryLanguage(folders: folders, ancestors: ancestors)
    }

    /// After a change: read the item again (new tags go into Emby's tag table through `get`, so every poster link
    /// changes), then tell the pages.
    static func reloadItem(_ id: String, emby: Emby) async {
        let fresh: Item? = try? await emby.get("/Users/\(emby.userId)/Items/\(id)")
        ItemAdminChanges.shared.bump(id, item: fresh)
        // SwiftUI posters work out their picture links from the tag table: redraw them with the new tags
        emby.objectWillChange.send()
    }

    /// Asks for a refresh, then watches the item (refresh date / image tags) for up to ~60 s.
    /// Shows "Refreshing…" and then "Updated" (or "Refresh started" when nothing changed in time).
    static func refresh(_ id: String, name: String, mode: ItemAdminAPI.RefreshMode, replaceImages: Bool,
                        emby: Emby, toast: Bool = true) async -> String? {
        let before = await record(id, emby: emby).map(ItemAdminAPI.snapshot)
        if let err = await send(ItemAdminAPI.refresh(itemId: id, mode: mode, replaceImages: replaceImages),
                                emby: emby, action: "refresh the metadata") { return err }
        if toast { emby.toast = Emby.Toast(text: "Refreshing \u{201C}\(name)\u{201D}…", icon: "arrow.clockwise") }
        let changed = await waitForChange(id, before: before, emby: emby)
        await reloadItem(id, emby: emby)
        if toast {
            emby.toast = changed ? Emby.Toast(text: "Updated \u{201C}\(name)\u{201D}", icon: "checkmark.circle.fill")
                : Emby.Toast(text: "Refresh started – the server is still working on it", icon: "clock")
        }
        return nil
    }

    /// Polls every 3 s for up to `seconds` until the snapshot differs (nil before = wait a little, then report true).
    static func waitForChange(_ id: String, before: String?, emby: Emby, seconds: Int = 60) async -> Bool {
        var waited = 0
        while waited < seconds {
            try? await Task.sleep(for: .seconds(3)); waited += 3
            if Task.isCancelled { return false }
            guard let now = await record(id, emby: emby).map(ItemAdminAPI.snapshot) else { continue }
            if let before { if now != before { try? await Task.sleep(for: .seconds(2)); return true } }
            else if waited >= 6 { return true }
        }
        return false
    }

    static func openWeb(_ id: String, emby: Emby) {
        let sid = UserDefaults.standard.string(forKey: "serverId-" + emby.server.lowercased())
        if let u = ItemAdminAPI.webURL(server: emby.server, itemId: id, jellyfin: emby.isJellyfin, serverId: sid) {
            NSWorkspace.shared.open(u)
        }
    }
}
