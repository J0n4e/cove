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

    @Published private(set) var items: [StoredNotification] = []
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
            items = NotificationInbox.pruned(NotificationInbox.decode(d), now: now())
        }
    }

    var unread: Int { NotificationInbox.unreadCount(items) }

    /// Keeps a notification Cove just made; with `.toast` it is also shown as the in-app toast.
    @discardableResult
    func add(_ n: NewMediaNotification, presentation: NotificationPresentation) -> StoredNotification {
        let s = StoredNotification(n, date: now(), target: NewMediaService.userInfo(n))
        items = NotificationInbox.adding(s, to: items, now: now())
        if presentation == .toast { toast = s }
        save()
        return s
    }

    func markRead(_ id: String) {
        guard items.contains(where: { $0.id == id && !$0.read }) else { return }
        items = NotificationInbox.markRead(id, in: items); save()
    }
    func markAllRead() { items = NotificationInbox.markAllRead(items); save() }
    func remove(_ id: String) {
        items = NotificationInbox.removing(id, from: items)
        if toast?.id == id { toast = nil }
        save()
    }
    func clearAll() { items = []; toast = nil; save() }

    func requestShowList() { showListPending = true; showListTick += 1 }

    private func save() {
        guard let file, let data = NotificationInbox.encode(items) else { return }
        Self.io.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
