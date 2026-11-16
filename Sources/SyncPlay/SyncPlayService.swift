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
    private(set) var timeSync = TimeSync()
    /// SyncPlayCommand / SyncPlayGroupUpdate messages, for phase 2.
    let messages = PassthroughSubject<SocketMessage, Never>()

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
    static let liveSocketKey = "jellyfinLiveSocket"
    static func liveSocketDefault() -> Bool { UserDefaults.standard.object(forKey: liveSocketKey) as? Bool ?? true }
    /// SyncPlay (phase 2) needs the socket now: in a group it stays open even with the live connection off.
    private(set) var socketNeeded = false
    private(set) var current: Credentials?
    private(set) var socket: ServerSocket?
    private var tasks: [Task<Void, Never>] = []
    private var bag: Set<AnyCancellable> = []
    private var wakeObserver: NSObjectProtocol?

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
            MainActor.assumeIsolated { self?.socket?.reconnectNow() }
        }
    }

    /// Starts for a signed-in Jellyfin session, stops otherwise. Calling it again with the same session does nothing.
    func update(_ c: Credentials?, isJellyfin: Bool) {
        guard let c, isJellyfin else { stop(); return }
        guard c != current else { return }
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
        let s = ServerSocket(request: r, makeTransport: makeTransport, sleep: sleep)
        s.log = log
        s.onConnect = { [weak self] in
            guard let self else { return }
            self.connected = true
            // The server ties capabilities to the session; send them again after every (re)connect
            self.tasks.append(Task { await self.postCapabilities(c) })
        }
        s.onDisconnect = { [weak self] in self?.connected = false }
        s.onMessage = { [weak self] m in self?.messages.send(m) }
        socket = s
        s.start()
    }

    func stop() {
        socket?.stop(); socket = nil
        tasks.forEach { $0.cancel() }; tasks = []
        current = nil
        socketNeeded = false   // a SyncPlay group doesn't outlive the session
        connected = false
        serverVersion = nil; syncPlayAccess = nil
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

    func postCapabilities(_ c: Credentials) async {
        guard var r = request(c, "/Sessions/Capabilities/Full") else { return }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.capabilitiesBody()
        do {
            let (_, resp) = try await http(r)
            log("SyncPlay: capabilities sent, HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            log("SyncPlay: capabilities failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    private struct PublicInfo: Decodable { let Version: String? }
    private struct UserInfo: Decodable {
        struct Policy: Decodable { let SyncPlayAccess: String? }
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
