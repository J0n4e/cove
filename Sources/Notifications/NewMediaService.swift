import Foundation
import Combine
import AppKit
import UserNotifications

// New-media notifications: polling, the Jellyfin socket's LibraryChanged, permission, posting and clicks.
// The server and the notification center sit behind protocols, so tests never touch the network or the real
// UNUserNotificationCenter.

/// What the server answers (one signed-in server and user; a switch makes a new one).
protocol NewMediaSource: AnyObject {
    /// The user's libraries; nil when the server can't be reached.
    func libraries() async -> [NewMediaLibrary]?
    /// The newest items of a library (newest first); nil when the request failed (the state is then kept).
    func latest(library: NewMediaLibrary, types: String) async -> [NewMediaItem]?
    /// These items (the socket's ItemsAdded ids).
    func items(ids: [String]) async -> [NewMediaItem]
    /// Which of `among` (library ids) the item is in.
    func libraryOf(itemId: String, among: Set<String>) async -> String?
    /// Of these shows, the ones the user follows: in Favorites or with at least one played episode.
    func followedSeries(_ ids: Set<String>) async -> Set<String>
    /// A poster as a local file for the notification (nil = none).
    func posterFile(_ id: String) async -> URL?
}

enum NotificationPermission: Equatable { case notDetermined, allowed, denied }

/// The notification center (the real one, or a test double).
protocol NewMediaNotifier: AnyObject {
    func permission() async -> NotificationPermission
    func requestPermission() async -> Bool
    func post(_ n: NewMediaNotification, poster: URL?) async
}

/// One signed-in server and user.
struct NewMediaSession: Equatable {
    let server: String
    let userId: String
    let token: String
    let authHeader: String
}

@MainActor
final class NewMediaService: ObservableObject {
    static let shared = NewMediaService()
    /// Every 10 minutes
    static let pollInterval: TimeInterval = 600
    /// Socket news waits this long for more items (a season copied in arrives as many messages)
    static let socketDelay: TimeInterval = 30
    /// At most this many socket ids are looked up per round
    static let maxSocketIds = 30

    @Published private(set) var permission: NotificationPermission = .notDetermined
    /// The user's movie / show libraries (for Settings' Libraries list)
    @Published private(set) var libraries: [NewMediaLibrary] = []

    let notifier: NewMediaNotifier
    private let makeSource: (NewMediaSession) -> NewMediaSource
    private let store: NewMediaStore
    private let prefs: () -> NewMediaPrefs
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let log: (String) -> Void
    private let enabled: Bool

    private(set) var session: NewMediaSession?
    private var source: NewMediaSource?
    private var pollTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private var pendingIds: [String] = []
    private var bag = Set<AnyCancellable>()
    private var wasOn: Bool
    private weak var emby: Emby?
    private var checking = false

    init(enabled: Bool = NSClassFromString("XCTestCase") == nil,
         notifier: NewMediaNotifier? = nil,
         makeSource: ((NewMediaSession) -> NewMediaSource)? = nil,
         defaults: UserDefaults = .standard,
         prefs: (() -> NewMediaPrefs)? = nil,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         log: @escaping (String) -> Void = { DebugLog.write($0) }) {
        self.enabled = enabled
        self.notifier = notifier ?? SystemNotifier.shared
        self.makeSource = makeSource ?? { s -> NewMediaSource in ServerNewMediaSource(session: s) }
        self.store = NewMediaStore(defaults: defaults)
        self.prefs = prefs ?? { NewMediaPrefs.load(defaults) }
        self.now = now
        self.sleep = sleep
        self.log = log
        self.wasOn = (prefs ?? { NewMediaPrefs.load(defaults) })().anyOn
    }

    // MARK: Following the app

    /// Follows sign-in, server switches and sign-out, the settings and the Jellyfin socket.
    func attach(to emby: Emby) {
        guard enabled, self.emby == nil else { return }
        self.emby = emby
        Publishers.CombineLatest3(emby.$server, emby.$token, emby.$userId)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self, weak emby] s, t, u in
                guard let self, let emby else { return }
                MainActor.assumeIsolated {
                    self.update(t.isEmpty || u.isEmpty || s.isEmpty ? nil
                                : NewMediaSession(server: s, userId: u, token: t, authHeader: emby.authHeader))
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.prefsChanged(self.prefs()) } }
            }
            .store(in: &bag)
        emby.syncPlay.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] m in
                MainActor.assumeIsolated {
                    if case .libraryChanged(let ids) = m { self?.itemsAdded(ids) }
                }
            }
            .store(in: &bag)
        // Both kinds are on by default: ask macOS once at launch, or nothing could ever be shown
        Task {
            await refreshPermission()
            if prefs().anyOn, permission == .notDetermined { await ensurePermission() }
        }
    }

    /// A new session (or none): stop the old one's work, start polling for the new one.
    func update(_ s: NewMediaSession?) {
        guard s != session else { return }
        pollTask?.cancel(); pollTask = nil
        socketTask?.cancel(); socketTask = nil
        pendingIds = []
        session = s
        source = s.map(makeSource)
        libraries = []
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel(); pollTask = nil
        // Tests (enabled: false) drive check() themselves
        guard enabled, session != nil, prefs().anyOn else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                do { try await self.sleep(Self.pollInterval) } catch { return }
            }
        }
    }

    /// Settings changed. Turned on after being off: start again from a fresh baseline (no news from while it was off).
    func prefsChanged(_ p: NewMediaPrefs) {
        let on = p.anyOn
        defer { wasOn = on }
        guard on != wasOn else { return }
        if on {
            if let s = session { store.removeServer(s.server) }
            startPolling()
            Task { await ensurePermission() }
        } else {
            pollTask?.cancel(); pollTask = nil
        }
    }

    // MARK: Checking

    /// One round: every movie / show library's newest items against what was known; posts what's new.
    func check() async {
        guard let s = session, let src = source, !checking else { return }
        checking = true
        defer { checking = false }
        guard let libs = await src.libraries(), session == s else { return }
        let eligible = libs.filter { NewMediaLibrary.eligible(kind: $0.kind) }
        libraries = eligible
        let p = prefs()
        guard p.anyOn else { return }
        // Every library is checked whatever the settings, so switching one on later starts from a fresh state
        let all = NewMediaPrefs()
        for lib in eligible {
            guard let types = lib.includeTypes(all), let items = await src.latest(library: lib, types: types),
                  session == s else { continue }
            let key = NewMediaDetector.stateKey(server: s.server, userId: s.userId, library: lib.id)
            let old = store.get(key)
            let (new, state) = NewMediaDetector.diff(old, items, now: now())
            store.set(state, for: key)
            if old == nil { log("Notifications: baseline for a library (\(items.count) items)") }
            guard !new.isEmpty, !p.libsOff.contains(lib.id) else { continue }
            await announce(new, in: lib, session: s, prefs: p, source: src)
        }
    }

    private func announce(_ items: [NewMediaItem], in lib: NewMediaLibrary, session s: NewMediaSession,
                          prefs p: NewMediaPrefs, source src: NewMediaSource) async {
        var followed = Set<String>()
        if p.onlyFollowed {
            let shows = Set(items.filter(\.isEpisode).compactMap(\.SeriesId))
            if !shows.isEmpty { followed = await src.followedSeries(shows) }
        }
        let wanted = NewMediaDetector.filter(items, prefs: p, followed: followed)
        guard !wanted.isEmpty, session == s else { return }
        let notes = NewMediaDetector.batches(wanted, library: lib, server: s.server, userId: s.userId)
        log("Notifications: \(wanted.count) new item(s) in a library, \(notes.count) notification(s)")
        for n in notes {
            var file: URL?
            if let id = n.posterId { file = await src.posterFile(id) }
            await notifier.post(n, poster: file)
        }
    }

    // MARK: Jellyfin socket

    /// LibraryChanged's ItemsAdded: wait a little for the rest (and the metadata), then look.
    func itemsAdded(_ ids: [String]) {
        guard session != nil, prefs().anyOn, !ids.isEmpty else { return }
        for id in ids where !pendingIds.contains(id) { pendingIds.append(id) }
        if pendingIds.count > Self.maxSocketIds { pendingIds = Array(pendingIds.suffix(Self.maxSocketIds)) }
        guard socketTask == nil else { return }
        socketTask = Task { [weak self] in
            do { try await self?.sleep(Self.socketDelay) } catch { return }
            await self?.flushSocket()
        }
    }

    /// A normal round first (it finds most of them and marks them seen), then the ones it didn't list (Jellyfin
    /// dates an item by its file, so an old file copied in today isn't among the newest): looked up one by one.
    func flushSocket() async {
        socketTask = nil
        let ids = pendingIds
        pendingIds = []
        guard let s = session, let src = source, !ids.isEmpty else { return }
        await check()
        guard session == s else { return }
        let p = prefs()
        let libs = libraries.filter { !p.libsOff.contains($0.id) }
        var seen = Set<String>()
        for lib in libraries {
            if let st = store.get(NewMediaDetector.stateKey(server: s.server, userId: s.userId, library: lib.id)) { seen.formUnion(st.seen) }
        }
        let rest = ids.filter { !seen.contains($0) }
        guard !rest.isEmpty, !libs.isEmpty else { return }
        let items = await src.items(ids: rest).filter { ($0.isMovie || $0.isEpisode) && !$0.played }
        var byLib: [String: [NewMediaItem]] = [:]
        for it in items {
            if let l = await src.libraryOf(itemId: it.Id, among: Set(libraries.map(\.id))) { byLib[l, default: []].append(it) }
        }
        guard session == s else { return }
        for lib in libraries {
            guard let found = byLib[lib.id], !found.isEmpty else { continue }
            let key = NewMediaDetector.stateKey(server: s.server, userId: s.userId, library: lib.id)
            guard let st = store.get(key) else { continue }   // no baseline yet: nothing is news
            store.set(NewMediaDetector.remember(found, in: st, now: now()), for: key)
            if libs.contains(lib) { await announce(found, in: lib, session: s, prefs: p, source: src) }
        }
    }

    // MARK: Permission

    func refreshPermission() async { permission = await notifier.permission() }

    /// Asks macOS the first time (when a toggle is on); afterwards just reads the answer.
    @discardableResult
    func ensurePermission() async -> NotificationPermission {
        var p = await notifier.permission()
        if p == .notDetermined { p = await notifier.requestPermission() ? .allowed : .denied }
        permission = p
        return p
    }

    /// Settings → Send test notification.
    func sendTest() async {
        guard await ensurePermission() == .allowed else { return }
        let n = NewMediaNotification(id: "cove-test-\(UUID().uuidString)", title: "New movie",
                                     body: "This is how Cove tells you about new movies and episodes.",
                                     thread: "cove-test", target: .test, posterId: nil,
                                     server: session?.server ?? "", userId: session?.userId ?? "", libraryId: "")
        await notifier.post(n, poster: nil)
    }

    static func openSystemSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Clicks

    /// A clicked notification: Cove to the front and the item, show or library opened. One from another
    /// server or user than the current one only shows a message (switching servers behind the user's back
    /// would drop what they were doing).
    func open(_ info: [AnyHashable: Any]) async {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.isMiniaturized && $0.canBecomeMain }) { w.deminiaturize(nil) }
        guard let emby, let kind = info["kind"] as? String, kind != "test" else { return }
        let server = info["server"] as? String ?? "", user = info["userId"] as? String ?? ""
        guard server.lowercased() == emby.server.lowercased(), user == emby.userId else {
            let name = emby.servers.first { $0.id == server.lowercased() }?.name ?? (URL(string: server)?.host ?? "another server")
            emby.toast = Emby.Toast(text: "That notification is from \(name). Switch to it to open it.", icon: "bell")
            return
        }
        let id = info["id"] as? String ?? ""
        switch kind {
        case "item", "series":
            if let it = await emby.itemRecord(id) { emby.openPage(it) }
        case "library":
            if UserDefaults.standard.string(forKey: "theme") ?? "apple" == "apple" {
                NavState.shared.popToRoot(); NavState.shared.sel = id
            } else {
                ClassicNavState.shared.popToRoot(); ClassicNavState.shared.sel = id
            }
        default: break
        }
    }

    /// What a notification carries for its click.
    static func userInfo(_ n: NewMediaNotification) -> [String: String] {
        var d = ["server": n.server, "userId": n.userId, "libraryId": n.libraryId]
        switch n.target {
        case .item(let id): d["kind"] = "item"; d["id"] = id
        case .series(let id): d["kind"] = "series"; d["id"] = id
        case .library(let id): d["kind"] = "library"; d["id"] = id
        case .test: d["kind"] = "test"
        }
        return d
    }
}

// MARK: - The real notification center

/// UNUserNotificationCenter. Needs an app bundle with an id (eu.jonae.cove); without one (swift run, tests)
/// it does nothing instead of crashing.
final class SystemNotifier: NSObject, NewMediaNotifier, UNUserNotificationCenterDelegate {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && NSClassFromString("XCTestCase") == nil }
    private var center: UNUserNotificationCenter? { Self.available ? UNUserNotificationCenter.current() : nil }

    /// Clicks and banners while Cove is in front; called once at launch (AppDelegate).
    static let shared = SystemNotifier()
    static func install() { shared.center?.delegate = shared }

    func permission() async -> NotificationPermission {
        guard let c = center else { return .denied }
        switch await c.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    func requestPermission() async -> Bool {
        guard let c = center else { return false }
        return (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ n: NewMediaNotification, poster: URL?) async {
        guard let c = center else { return }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.threadIdentifier = n.thread
        content.sound = .default
        content.userInfo = NewMediaService.userInfo(n)
        if let poster, let a = try? UNNotificationAttachment(identifier: "poster", url: poster, options: nil) {
            content.attachments = [a]
        }
        let r = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do { try await c.add(r) } catch { DebugLog.write("Notifications: post failed \((error as NSError).domain) \((error as NSError).code)") }
    }

    // Banners also while Cove is the front app
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let strings = info.reduce(into: [String: String]()) { d, kv in
            if let k = kv.key as? String, let v = kv.value as? String { d[k] = v }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Task { await NewMediaService.shared.open(strings) }
            }
            completionHandler()
        }
    }
}

// MARK: - The server

/// Emby and Jellyfin answer the same requests here. Works on its own copy of the sign-in, so a server switch
/// mid-request can't mix servers; failures are only logged (no "can't reach" banner for a background check).
final class ServerNewMediaSource: NewMediaSource {
    let session: NewMediaSession
    private let http: (URLRequest) async throws -> (Data, URLResponse)

    init(session: NewMediaSession, http: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await Net.session.data(for: $0) }) {
        self.session = session
        self.http = http
    }

    static let fields = "DateCreated,SeriesName,SeriesId,ParentIndexNumber,IndexNumber,ProductionYear,UserData"

    func request(_ path: String, _ q: [String: String]) -> URLRequest? {
        guard var c = URLComponents(string: session.server + path) else { return nil }
        if !q.isEmpty { c.queryItems = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let u = c.url else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 20)
        r.setValue(session.token, forHTTPHeaderField: "X-Emby-Token")
        r.setValue(session.authHeader + ", Token=\"\(session.token)\"", forHTTPHeaderField: "Authorization")
        return r
    }

    private func data(_ path: String, _ q: [String: String] = [:]) async -> Data? {
        guard let r = request(path, q) else { return nil }
        do {
            let (d, resp) = try await http(r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(code) else { DebugLog.write("Notifications: request answered HTTP \(code)"); return nil }
            return d
        } catch {
            DebugLog.write("Notifications: request failed \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }

    private func list(_ path: String, _ q: [String: String]) async -> [NewMediaItem]? {
        guard let d = await data(path, q) else { return nil }
        return try? JSONDecoder().decode(NewMediaItemList.self, from: d).Items
    }

    private struct LibView: Decodable { let Id: String; let Name: String; let CollectionType: String? }
    private struct Views: Decodable { let Items: [LibView] }

    func libraries() async -> [NewMediaLibrary]? {
        guard let d = await data("/Users/\(session.userId)/Views"),
              let v = try? JSONDecoder().decode(Views.self, from: d) else { return nil }
        return v.Items.map { NewMediaLibrary(id: $0.Id, name: $0.Name, kind: $0.CollectionType) }
    }

    func latest(library: NewMediaLibrary, types: String) async -> [NewMediaItem]? {
        await list("/Users/\(session.userId)/Items", [
            "ParentId": library.id, "IncludeItemTypes": types, "Recursive": "true",
            "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": "50",
            "Fields": Self.fields, "EnableImages": "false", "EnableTotalRecordCount": "false"])
    }

    func items(ids: [String]) async -> [NewMediaItem] {
        guard !ids.isEmpty else { return [] }
        return await list("/Users/\(session.userId)/Items", ["Ids": ids.joined(separator: ","), "Fields": Self.fields,
                                                              "EnableImages": "false"]) ?? []
    }

    private struct Ancestor: Decodable { let Id: String }

    func libraryOf(itemId: String, among: Set<String>) async -> String? {
        guard let d = await data("/Items/\(itemId)/Ancestors", ["UserId": session.userId]),
              let a = try? JSONDecoder().decode([Ancestor].self, from: d) else { return nil }
        return a.first { among.contains($0.Id) }?.Id
    }

    private struct Show: Decodable {
        let Id: String
        let UserData: UD?
        struct UD: Decodable { let Played: Bool?; let IsFavorite: Bool?; let PlayedPercentage: Double? }
    }
    private struct Shows: Decodable { let Items: [Show] }
    private struct Count: Decodable { let TotalRecordCount: Int? }

    func followedSeries(_ ids: Set<String>) async -> Set<String> {
        var out = Set<String>()
        var unsure: [String] = []
        if let d = await data("/Users/\(session.userId)/Items", ["Ids": ids.sorted().joined(separator: ","), "Fields": "UserData"]),
           let shows = try? JSONDecoder().decode(Shows.self, from: d) {
            for s in shows.Items {
                if NewMediaFollow.follows(favorite: s.UserData?.IsFavorite, played: s.UserData?.Played,
                                          playedPercentage: s.UserData?.PlayedPercentage, playedEpisodes: nil) {
                    out.insert(s.Id)
                } else { unsure.append(s.Id) }
            }
        } else { unsure = ids.sorted() }
        // The show's own numbers aren't always filled in: ask for one played episode of it
        for id in unsure.prefix(10) {
            if let d = await data("/Users/\(session.userId)/Items", ["ParentId": id, "IncludeItemTypes": "Episode",
                                    "Recursive": "true", "IsPlayed": "true", "Limit": "1", "EnableImages": "false"]),
               let c = try? JSONDecoder().decode(Count.self, from: d),
               NewMediaFollow.follows(favorite: nil, played: nil, playedPercentage: nil, playedEpisodes: c.TotalRecordCount) {
                out.insert(id)
            }
        }
        return out
    }

    func posterFile(_ id: String) async -> URL? {
        guard let d = await data("/Items/\(id)/Images/Primary", ["maxWidth": "300", "quality": "85", "format": "jpg"]),
              !d.isEmpty else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoveNotifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(UUID().uuidString + ".jpg")
        do { try d.write(to: f); return f } catch { return nil }
    }
}

/// "A show I follow": in Favorites, or at least one episode played.
enum NewMediaFollow {
    static func follows(favorite: Bool?, played: Bool?, playedPercentage: Double?, playedEpisodes: Int?) -> Bool {
        favorite == true || played == true || (playedPercentage ?? 0) > 0 || (playedEpisodes ?? 0) > 0
    }
}
