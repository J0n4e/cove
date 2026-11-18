import AppKit
import Combine
import Foundation

// SyncPlay phase 1: invisible plumbing, Jellyfin only. While signed in to a Jellyfin server Cove keeps its
// WebSocket open, tells the server what it can do (so Dashboard → Sessions shows remote-control buttons), keeps an
// estimate of the server clock and reads whether this user may use SyncPlay. No UI and no playback changes:
// commands that arrive are published on `messages` for phase 2 and otherwise ignored. Emby gets none of this.

@MainActor
final class SyncPlayService: ObservableObject {
    struct Credentials: Equatable {
        let server: String
        let token: String
        let userId: String
        let deviceId: String
        let authHeader: String
        /// The Authorization header Jellyfin reads (the token never goes into a link)
        var authorization: String { authHeader + ", Token=\"\(token)\"" }
    }

    typealias HTTP = (URLRequest) async throws -> (Data, URLResponse)

    /// GeneralCommandType names (MediaBrowser.Model/Session/GeneralCommandType.cs) that relate to playback.
    /// Pause / seek / stop arrive as Playstate messages, which SupportsMediaControl enables.
    static let supportedCommands = ["PlayState", "Play", "VolumeUp", "VolumeDown", "Mute", "Unmute", "ToggleMute",
                                    "SetVolume", "SetAudioStreamIndex", "SetSubtitleStreamIndex", "ToggleFullscreen",
                                    "DisplayMessage"]

    @Published private(set) var connected = false
    @Published private(set) var serverVersion: String?
    /// The user's Policy.SyncPlayAccess: CreateAndJoinGroups, JoinGroups or None
    @Published private(set) var syncPlayAccess: String?
    /// The signed-in user's name (default group name "<name>'s group")
    @Published private(set) var userName: String?
    private(set) var timeSync = TimeSync()
    /// SyncPlayCommand / SyncPlayGroupUpdate messages, for phase 2.
    let messages = PassthroughSubject<SocketMessage, Never>()
    /// v1.19.0: the session lists Jellyfin pushes while Now Playing is subscribed (SessionsStart).
    let sessions = PassthroughSubject<[ActiveSession], Never>()
    /// v1.19.0: a text message over the socket (false: no socket / not connected).
    @discardableResult
    func sendSocketText(_ text: String) async -> Bool {
        guard let socket else { return false }
        return await socket.sendText(text)
    }

    /// Jellyfin 10.8 or newer, and the user may join groups.
    var syncPlayAvailable: Bool { Self.available(version: serverVersion, access: syncPlayAccess) }

    static func available(version: String?, access: String?) -> Bool {
        guard let version, let access, access != "None" else { return false }
        let n = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let major = n.first ?? 0, minor = n.count > 1 ? n[1] : 0
        return major > 10 || (major == 10 && minor >= 8)
    }

    private let enabled: Bool
    private let http: HTTP
    private let makeTransport: (URLRequest) -> SocketTransport
    private let sleep: (TimeInterval) async throws -> Void
    private let log: (String) -> Void
    /// Settings → Playback → Live connection to the server (default on)
    private let liveSetting: () -> Bool
    nonisolated static let liveSocketKey = "jellyfinLiveSocket"
    nonisolated static func liveSocketDefault() -> Bool { UserDefaults.standard.object(forKey: liveSocketKey) as? Bool ?? true }
    /// SyncPlay (phase 2) needs the socket now: in a group it stays open even with the live connection off.
    private(set) var socketNeeded = false
    private(set) var current: Credentials?
    private(set) var socket: ServerSocket?
    private var tasks: [Task<Void, Never>] = []
    private var bag: Set<AnyCancellable> = []
    private var wakeObserver: NSObjectProtocol?
    /// The socket dropped since it last connected (phase 3: rejoin the group when it's back)
    private var wasDisconnected = false

    /// SyncPlay phase 2: the group this session is in (if any).
    lazy var group: SyncPlayGroup = makeGroup()

    private func makeGroup() -> SyncPlayGroup {
        let g = SyncPlayGroup()
        let log = self.log
        g.log = { log($0) }
        g.available = { [weak self] in self?.syncPlayAvailable ?? false }
        g.send = { [weak self] path, body, post in await self?.send(path, body: body, post: post) }
        g.socketNeeded = { [weak self] on in self?.setSocketNeeded(on) }
        g.waitConnected = { [weak self] in
            // The server sends group updates over the socket only: give it up to 10 s to open
            for _ in 0..<40 {
                guard let self, !self.connected, self.current != nil else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        g.clock = { [weak self] in self?.timeSync ?? TimeSync() }
        g.playback = { PlayerModel.active }
        g.listen(to: messages)
        return g
    }

    /// A SyncPlay request for the current session. nil: not signed in to Jellyfin, or the server said no.
    func send(_ path: String, body: Data?, post: Bool) async -> Data? {
        guard let c = current else { return nil }
        return await send(c, path, body: body, post: post)
    }

    private func send(_ c: Credentials, _ path: String, body: Data?, post: Bool) async -> Data? {
        guard var r = request(c, path) else { return nil }
        if post {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body ?? Data("{}".utf8)
        }
        do {
            let (d, resp) = try await http(r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                log("SyncPlay: \(path) answered HTTP \(code)")
                return nil
            }
            return d
        } catch {
            log("SyncPlay: \(path) failed: \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }

    /// `enabled` is off inside the test runner, so the app's own Emby objects made by other tests never open
    /// sockets or post to stub servers; SyncPlay tests make their own service.
    init(enabled: Bool = NSClassFromString("XCTestCase") == nil,
         http: @escaping HTTP = { try await Net.session.data(for: $0) },
         makeTransport: @escaping (URLRequest) -> SocketTransport = { URLSessionSocketTransport(request: $0) },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         log: @escaping (String) -> Void = { DebugLog.write($0) },
         liveSetting: @escaping () -> Bool = { SyncPlayService.liveSocketDefault() }) {
        self.enabled = enabled
        self.liveSetting = liveSetting
        self.http = http
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.log = log
    }

    /// Follows sign-in, sign-out, server switches and the Jellyfin/Emby answer without touching those paths.
    func attach(to emby: Emby) {
        guard enabled else { return }
        group.opener = { [weak emby] id, start in await emby?.syncPlayOpen(id, start: start) }
        // SyncPlay phase 4: a group started on an episode queues the series' following ones; Dashboard remote control ↓
        group.queueFor = { [weak emby] id in await emby?.syncPlaySeriesQueue(id) ?? [id] }
        RemoteCommandRouter.shared.attach(to: emby, messages: messages)
        RemoteCommandRouter.shared.groupPlayNow = { [weak self] id, start in
            self?.group.remotePlayNow(id, startTicks: Int64((start * SyncPlayGroup.ticksPerSecond).rounded())) ?? false
        }
        // ↑ phase 4
        // Closing the player while in a group leaves the group
        emby.$playing.map { $0 == nil }.removeDuplicates().dropFirst()
            .sink { [weak self] closed in
                MainActor.assumeIsolated { if closed { self?.group.playerClosed() } }
            }
            .store(in: &bag)
        Publishers.CombineLatest4(emby.$server, emby.$token, emby.$userId, emby.$isJellyfin)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self, weak emby] s, t, u, j in
                guard let self, let emby else { return }
                let c = t.isEmpty || u.isEmpty || s.isEmpty ? nil
                    : Credentials(server: s, token: t, userId: u, deviceId: emby.deviceId, authHeader: emby.authHeader)
                // isJellyfin can still be the previous server's answer right after a switch: also check the
                // answer stored for this server, so an Emby server never gets a Jellyfin socket
                let known = UserDefaults.standard.bool(forKey: "jellyfin-" + s.lowercased())
                self.update(c, isJellyfin: j && known)
            }
            .store(in: &bag)
        // Settings → Playback → Live connection: start or stop the socket right away
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in SyncPlayService.liveSocketDefault() }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.liveSettingChanged() } }
            .store(in: &bag)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // reconnectNow doesn't report a disconnect: count the wake as one (phase 3 rejoin)
                if self?.socket != nil { self?.wasDisconnected = true }
                self?.socket?.reconnectNow()
            }
        }
    }

    /// Starts for a signed-in Jellyfin session, stops otherwise. Calling it again with the same session does nothing.
    func update(_ c: Credentials?, isJellyfin: Bool) {
        guard let c, isJellyfin else { leaveGroup(); stop(); return }
        guard c != current else { return }
        leaveGroup()
        stop()
        current = c
        refreshSocket()
        // Capabilities don't depend on the socket: post them right away too, so the Dashboard shows Cove as
        // controllable even if the socket can't connect (or is switched off)
        tasks.append(Task { await postCapabilities(c) })
        tasks.append(Task { await loadInfo(c) })
        tasks.append(Task { await pollTime(c) })
    }

    /// SyncPlay joins (true) or leaves (false) a group: with the live connection off, opens or closes the socket.
    func setSocketNeeded(_ needed: Bool) {
        socketNeeded = needed
        refreshSocket()
    }

    /// The live-connection setting changed.
    func liveSettingChanged() { refreshSocket() }

    /// The socket is open while signed in to Jellyfin and either the live connection is on or SyncPlay needs it.
    private func refreshSocket() {
        guard let c = current else { return }
        let want = liveSetting() || socketNeeded
        if want, socket == nil { startSocket(c) }
        else if !want, let s = socket {
            log("SyncPlay: live connection off, closing the socket")
            s.stop(); socket = nil; connected = false
        }
    }

    private func startSocket(_ c: Credentials) {
        guard let r = ServerSocket.request(server: c.server, deviceId: c.deviceId, authorization: c.authorization) else {
            log("SyncPlay: not connecting, the socket address isn't the server's")
            return
        }
        wasDisconnected = false
        let s = ServerSocket(request: r, makeTransport: makeTransport, sleep: sleep)
        s.log = log
        s.onConnect = { [weak self] in
            guard let self else { return }
            let again = self.wasDisconnected
            self.connected = true
            self.wasDisconnected = false
            // Phase 3: back after a drop / sleep while in a group: make sure the server still has us in it
            if again, self.group.isInGroup { self.tasks.append(Task { await self.group.rejoin() }) }
            // The server ties capabilities to the session; send them again after every (re)connect
            self.tasks.append(Task { await self.postCapabilities(c) })
        }
        s.onDisconnect = { [weak self] in self?.connected = false; self?.wasDisconnected = true }
        s.onMessage = { [weak self] m in self?.messages.send(m) }
        s.onSessions = { [weak self] list in self?.sessions.send(list) }
        socket = s
        s.start()
    }

    /// Sign-out or server switch while in a group: tell the old server, with the old session's credentials.
    private func leaveGroup() {
        guard group.isActive, let old = current else { return }
        log("SyncPlay: session changed, leaving the group")
        group.reset()
        Task { _ = await self.send(old, "/SyncPlay/Leave", body: nil, post: true) }
    }

    func stop() {
        group.reset()
        socket?.stop(); socket = nil
        tasks.forEach { $0.cancel() }; tasks = []
        current = nil
        socketNeeded = false   // a SyncPlay group doesn't outlive the session
        connected = false
        serverVersion = nil; syncPlayAccess = nil; userName = nil
        timeSync = TimeSync()
    }

    private func request(_ c: Credentials, _ path: String) -> URLRequest? {
        guard let u = URL(string: c.server + path) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 10)
        r.setValue(c.authorization, forHTTPHeaderField: "Authorization")
        return r
    }

    static func capabilitiesBody() -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "PlayableMediaTypes": ["Video", "Audio"],
            "SupportedCommands": supportedCommands,
            "SupportsMediaControl": true,
        ] as [String: Any], options: [.sortedKeys])) ?? Data()
    }

    /// Timing: waits before each retry of the capabilities post (5 tries in all)
    nonisolated static let capabilitiesBackoff: [TimeInterval] = [2, 4, 8, 16]

    /// Retried on a 5xx or a network error (a restarting server answers 502 / 503 for a while) while the same
    /// session is current.
    func postCapabilities(_ c: Credentials) async {
        guard var r = request(c, "/Sessions/Capabilities/Full") else { return }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.capabilitiesBody()
        let tries = Self.capabilitiesBackoff.count + 1
        for n in 1...tries {
            guard !Task.isCancelled, current == c else { return }
            var retry = false
            do {
                let (_, resp) = try await http(r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                retry = code >= 500
                log("SyncPlay: capabilities sent, HTTP \(code) (try \(n)/\(tries))")
            } catch {
                retry = true
                log("SyncPlay: capabilities failed: \((error as NSError).domain) \((error as NSError).code) (try \(n)/\(tries))")
            }
            guard retry, n < tries else { return }
            let wait = Self.capabilitiesBackoff[n - 1]
            log("SyncPlay: capabilities retry in \(Int(wait)) s")
            do { try await sleep(wait) } catch { return }
        }
    }

    private struct PublicInfo: Decodable { let Version: String? }
    private struct UserInfo: Decodable {
        struct Policy: Decodable { let SyncPlayAccess: String? }
        let Name: String?
        let Policy: Policy?
    }

    func loadInfo(_ c: Credentials) async {
        if let r = request(c, "/System/Info/Public"), let (d, _) = try? await http(r),
           let v = try? JSONDecoder().decode(PublicInfo.self, from: d), current == c {
            serverVersion = v.Version
        }
        if let r = request(c, "/Users/\(c.userId)"), let (d, resp) = try? await http(r),
           (resp as? HTTPURLResponse)?.statusCode ?? 200 == 200,
           let u = try? JSONDecoder().decode(UserInfo.self, from: d), current == c {
            syncPlayAccess = u.Policy?.SyncPlayAccess
            userName = u.Name
        }
    }

    private func pollTime(_ c: Credentials) async {
        var pings = 0
        while !Task.isCancelled, current == c {
            if let r = request(c, "/GetUtcTime") {
                let t0 = Date()
                if let (d, _) = try? await http(r),
                   let s = try? JSONDecoder().decode(UtcTimeResponse.self, from: d).sample(sent: t0, received: Date()),
                   current == c {
                    timeSync.add(s)
                }
            }
            pings += 1
            do { try await sleep(TimeSync.pollInterval(afterPings: pings)) } catch { return }
        }
    }
}
