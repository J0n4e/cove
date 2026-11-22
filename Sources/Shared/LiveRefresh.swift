import Foundation
import Combine

extension Notification.Name {
    /// A playback stopped (player, Cast, AirPlay); userInfo "id" (String) and "finished" (Bool).
    static let covePlaybackStopped = Notification.Name("covePlaybackStopped")
}

/// Live updates of what pages hold: after a playback stops (resume points, Continue Watching, Next Up) and after an
/// admin edit of an item (pictures, metadata, identify, refresh). Only the changed item ids are touched.
enum LiveRefresh {
    /// How long after a stop the pages ask the server again (it needs a moment to save the position).
    nonisolated(unsafe) static var afterStopDelay: Double = 1.5

    /// `items` with every item found in `fresh` replaced by its new copy; nil when none of them is there.
    static func replacing(_ items: [Item], with fresh: [String: Item]) -> [Item]? {
        guard !fresh.isEmpty, items.contains(where: { fresh[$0.id] != nil }) else { return nil }
        // A deleted item comes as a tombstone (DeletedItems.announce): it leaves the list
        return items.compactMap { i in fresh[i.id].map { $0.isTombstone ? nil : $0 } ?? i }
    }

    /// Home rows after an admin change (nil = nothing changed).
    static func replacing(rows: [Row], with fresh: [String: Item]) -> [Row]? {
        var changed = false
        let out = rows.map { r -> Row in
            guard let n = replacing(r.items, with: fresh) else { return r }
            changed = true
            var c = r; c.items = n; return c
        }
        return changed ? out : nil
    }

    /// Continue Watching right after a stop: the stopped item moves to the front (when the row has it).
    static func movingToFront(_ id: String, in rows: [Row]) -> [Row]? {
        guard let i = rows.firstIndex(where: { $0.feed == .resume }),
              let j = rows[i].items.firstIndex(where: { $0.id == id }), j > 0 else { return nil }
        var out = rows, items = rows[i].items
        let it = items.remove(at: j); items.insert(it, at: 0)
        out[i].items = items
        return out
    }
}

/// Calls `apply` with the freshly read items after each admin change (ItemAdminChanges). Main actor only.
@MainActor
final class ItemChangeWatch {
    private var c: AnyCancellable?
    init(_ apply: @escaping @MainActor ([String: Item]) -> Void) {
        c = ItemAdminChanges.shared.updates.sink { fresh in MainActor.assumeIsolated { apply(fresh) } }
    }
}

/// Calls `apply` (item id, finished) when a playback stops.
@MainActor
final class PlaybackStopWatch {
    private let token = ObserverToken()
    init(_ apply: @escaping @MainActor (String, Bool) -> Void) {
        token.token = NotificationCenter.default.addObserver(forName: .covePlaybackStopped, object: nil, queue: .main) { n in
            let id = n.userInfo?["id"] as? String ?? ""
            let fin = n.userInfo?["finished"] as? Bool ?? false
            MainActor.assumeIsolated { apply(id, fin) }
        }
    }
}
