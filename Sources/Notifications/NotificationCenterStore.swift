import Foundation
import Combine

/// The in-app notification list (Activity → Notifications) and the toast on screen. Main-actor only: NewMediaService
/// (also @MainActor) adds to it and the views observe it; the file is written on a serial background queue from a
/// snapshot, so nothing is shared across threads.
@MainActor
final class NotificationCenterStore: ObservableObject {
    static let shared = NotificationCenterStore(file: NotificationCenterStore.defaultFile)

    /// Application Support/Cove/notifications.json
    nonisolated static var defaultFile: URL? {
        guard NSClassFromString("XCTestCase") == nil,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Cove", isDirectory: true).appendingPathComponent("notifications.json")
    }

    /// Only the ACTIVE server's notifications (owner: one sees just the server Cove is on). Old entries without a
    /// server count as the active one's.
    @Published private(set) var items: [StoredNotification] = []
    /// Every server's entries, as saved; `items` is the active server's slice of it.
    private var all: [StoredNotification] = [] { didSet { items = NotificationInbox.forServer(all, activeServer) } }
    /// The server Cove is on (set by Emby when it changes)
    private(set) var activeServer = ""
    /// Cove's own toast (Glass3D, Cove in front)
    @Published var toast: StoredNotification?
    /// Bumped by the toast's "Show all": Activity opens its Notifications tab
    @Published private(set) var showListTick = 0
    /// Set with the tick; the Activity page takes it when it appears (it may not exist yet)
    var showListPending = false

    let file: URL?
    private let now: () -> Date
    private static let io = DispatchQueue(label: "eu.jonae.cove.notifications", qos: .utility)

    init(file: URL?, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        if let file, let d = try? Data(contentsOf: file) {
            all = NotificationInbox.pruned(NotificationInbox.decode(d), now: now())
            items = all   // didSet doesn't run inside init; no active server yet → everything
        }
    }

    var unread: Int { NotificationInbox.unreadCount(items) }

    /// Keeps a notification Cove just made; with `.toast` it is also shown as the in-app toast.
    @discardableResult
    func add(_ n: NewMediaNotification, presentation: NotificationPresentation) -> StoredNotification {
        let s = StoredNotification(n, date: now(), target: NewMediaService.userInfo(n))
        all = NotificationInbox.adding(s, to: all, now: now())
        if presentation == .toast, NotificationInbox.isServer(s.server, activeServer) { toast = s }
        save()
        return s
    }

    func markRead(_ id: String) {
        guard items.contains(where: { $0.id == id && !$0.read }) else { return }
        all = NotificationInbox.markRead(id, in: all); save()
    }
    /// Read / Clear act on the active server's list only; the other servers' entries stay for when Cove is back there.
    func markAllRead() {
        let mine = Set(items.map(\.id))
        all = all.map { var n = $0; if mine.contains(n.id) { n.read = true }; return n }; save()
    }
    func remove(_ id: String) {
        all = NotificationInbox.removing(id, from: all)
        if toast?.id == id { toast = nil }
        save()
    }
    func clearAll() {
        let mine = Set(items.map(\.id))
        all = all.filter { !mine.contains($0.id) }; toast = nil; save()
    }

    /// Cove switched server: the list, the unread dot and the toast follow it.
    func setActiveServer(_ server: String) {
        guard server.lowercased() != activeServer.lowercased() else { return }
        activeServer = server
        items = NotificationInbox.forServer(all, server)
        if let t = toast, !NotificationInbox.isServer(t.server, server) { toast = nil }
    }

    func requestShowList() { showListPending = true; showListTick += 1 }

    private func save() {
        guard let file, let data = NotificationInbox.encode(all) else { return }
        Self.io.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
