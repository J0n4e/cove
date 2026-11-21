import Foundation

// SyncPlay phase 1: Jellyfin's WebSocket (/socket). The server authenticates the upgrade request like any other
// request (WebSocketManager → IAuthService.Authenticate), so the token goes in the Authorization header and never
// in the link. It sends ForceKeepAlive (Data = timeout in seconds, 60) when the socket has been quiet; the client
// answers with KeepAlive and keeps sending one every timeout / 2.

/// What the socket runs on; tests swap in a stub.
protocol SocketTransport: AnyObject {
    /// Connects; returns once the server answered (a ping/pong round trip).
    func open() async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// True for the first caller only (thread-safe).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

final class URLSessionSocketTransport: SocketTransport {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = Net.session) {
        task = session.webSocketTask(with: request)
    }

    /// The handshake's HTTP status when it didn't upgrade (101), for the log
    var handshakeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    func open() async throws {
        // Connected = the handshake finished (HTTP 101), reported by the task's delegate. A ping is not used:
        // through some proxies the server's pong never arrives although the socket works (owner's log: 101, then
        // a ping timeout). URLSession can report more than once (e.g. an error and then the cancel); resuming a
        // continuation twice crashes the app, so only the first report counts. Give up after 15 s.
        let once = OnceFlag()
        let task = self.task
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let d = OpenDelegate { e in
                guard once.claim() else { return }
                if let e { c.resume(throwing: e) } else { c.resume() }
            }
            task.delegate = d
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                guard once.claim() else { return }
                task.cancel(with: .goingAway, reason: nil)
                c.resume(throwing: URLError(.timedOut))
            }
        }
    }

    /// Reports the end of the WebSocket handshake: nil when it opened, else the error.
    private final class OpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        let done: (Error?) -> Void
        init(_ done: @escaping (Error?) -> Void) { self.done = done }
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            done(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            done(error ?? URLError(.networkConnectionLost))
        }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// A SyncPlay command (Jellyfin's SendCommand): play / pause / seek / stop at a server time.
struct SyncPlayCommand: Decodable, Equatable {
    let GroupId: String
    let PlaylistItemId: String?
    let When: String
    let PositionTicks: Int64?
    let Command: String
    let EmittedAt: String?
}

/// A SyncPlay group update (Jellyfin's GroupUpdate<T>). `Data` differs per Type: a user name (UserJoined,
/// UserLeft), a group id (GroupLeft…), or an object (GroupJoined, StateUpdate, PlayQueue). Phase 1 keeps the
/// text form and the state fields; phase 2 decodes the rest.
struct SyncPlayGroupUpdate: Decodable, Equatable {
    let GroupId: String
    let type: String
    let text: String?
    let state: String?
    let reason: String?
    /// GroupJoined: the group (GroupInfoDto)
    let group: SyncPlayGroupInfo?
    /// PlayQueue: the queue (PlayQueueUpdate)
    let queue: SyncPlayQueueUpdate?

    private enum K: String, CodingKey { case GroupId, type = "Type", Data }
    private struct StateData: Decodable { let State: String?; let Reason: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        GroupId = try c.decode(String.self, forKey: .GroupId)
        type = try c.decode(String.self, forKey: .type)
        text = try? c.decode(String.self, forKey: .Data)
        let s = try? c.decode(StateData.self, forKey: .Data)
        state = s?.State; reason = s?.Reason
        group = type == "GroupJoined" ? try? c.decode(SyncPlayGroupInfo.self, forKey: .Data) : nil
        queue = type == "PlayQueue" ? try? c.decode(SyncPlayQueueUpdate.self, forKey: .Data) : nil
    }
}

enum SocketMessage: Equatable {
    case forceKeepAlive(timeout: Int)
    case keepAlive
    case syncPlayCommand(SyncPlayCommand)
    case syncPlayGroupUpdate(SyncPlayGroupUpdate)
    // SyncPlay phase 4: Jellyfin remote control (RemoteControl.swift) ↓
    case playstate(RemotePlaystate)
    case generalCommand(RemoteGeneralCommand)
    case play(RemotePlayRequest)
    // ↑ phase 4
    // --- New-media notifications (Sources/Notifications): Jellyfin's LibraryChanged, the ItemsAdded ids ---
    case libraryChanged([String])
    // --- end new-media notifications ---
    /// Anything else (Playstate, GeneralCommand, UserDataChanged…): ignored in phase 1.
    case other(String)
    // >>> v1.19.0 Now Playing live (Sessions)
    /// Jellyfin's Sessions message (sent while subscribed with SessionsStart): every session, as GET /Sessions.
    case sessions(LiveSessions)
    // <<< v1.19.0 Now Playing live (Sessions)
}

// >>> v1.19.0 Now Playing live (Sessions)
/// The session list from a Sessions message. Equal when the same sessions are at the same place (for tests).
struct LiveSessions: Equatable {
    let list: [ActiveSession]
    static func == (a: LiveSessions, b: LiveSessions) -> Bool {
        a.list.map { "\($0.Id)|\($0.PlayState?.PositionTicks ?? -1)|\($0.PlayState?.IsPaused ?? false)" }
            == b.list.map { "\($0.Id)|\($0.PlayState?.PositionTicks ?? -1)|\($0.PlayState?.IsPaused ?? false)" }
    }
}
// <<< v1.19.0 Now Playing live (Sessions)

/// The envelope every message comes in: {"MessageType": …, "Data": …, "MessageId": …}.
struct SocketEnvelope: Decodable {
    let message: SocketMessage
    let messageId: String?

    private enum K: String, CodingKey { case MessageType, Data, MessageId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .MessageType)
        messageId = try? c.decode(String.self, forKey: .MessageId)
        switch type {
        case "ForceKeepAlive":
            let t = (try? c.decode(Int.self, forKey: .Data)) ?? (try? c.decode(Double.self, forKey: .Data)).map { Int($0) }
            message = .forceKeepAlive(timeout: t ?? ServerSocket.defaultTimeout)
        case "KeepAlive": message = .keepAlive
        case "SyncPlayCommand": message = .syncPlayCommand(try c.decode(SyncPlayCommand.self, forKey: .Data))
        case "SyncPlayGroupUpdate": message = .syncPlayGroupUpdate(try c.decode(SyncPlayGroupUpdate.self, forKey: .Data))
        case "Sessions": message = .sessions(LiveSessions(list: try c.decode([ActiveSession].self, forKey: .Data)))   // v1.19.0
        // SyncPlay phase 4: remote control (an odd payload stays .other instead of failing the message) ↓
        case "Playstate": message = (try? c.decode(RemotePlaystate.self, forKey: .Data)).map { .playstate($0) } ?? .other(type)
        case "GeneralCommand": message = (try? c.decode(RemoteGeneralCommand.self, forKey: .Data)).map { .generalCommand($0) } ?? .other(type)
        case "Play": message = (try? c.decode(RemotePlayRequest.self, forKey: .Data)).map { .play($0) } ?? .other(type)
        // ↑ phase 4
        // --- New-media notifications: LibraryChanged ---
        case "LibraryChanged": message = .libraryChanged((try? c.decode(LibraryChangedData.self, forKey: .Data))?.ItemsAdded ?? [])
        // --- end new-media notifications ---
        default: message = .other(type)
        }
    }

    // --- New-media notifications: LibraryChanged's Data (LibraryUpdateInfo) ---
    private struct LibraryChangedData: Decodable { let ItemsAdded: [String]? }
    // --- end new-media notifications ---

    static func decode(_ text: String) -> SocketEnvelope? {
        try? JSONDecoder().decode(SocketEnvelope.self, from: Data(text.utf8))
    }
}

@MainActor
final class ServerSocket {
    /// Jellyfin's WebSocketLostTimeout (SessionWebSocketListener), used until the server says otherwise.
    static let defaultTimeout = 60
    static let keepAliveText = #"{"MessageType":"KeepAlive"}"#

    /// 1, 2, 4 … seconds, at most 60.
    static func backoff(attempt: Int) -> TimeInterval { min(60, pow(2, Double(min(attempt, 6)))) }
    static func keepAliveInterval(timeout: Int) -> TimeInterval { Double(max(timeout, 2)) / 2 }

    /// ws(s)://<server>/socket?deviceId=…, with the token in the Authorization header (never in the link).
    /// nil when the server address isn't http(s) or the socket link wouldn't be same-origin with it.
    static func request(server: String, deviceId: String, authorization: String) -> URLRequest? {
        guard let base = URL(string: server), var c = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        c.scheme = scheme == "https" ? "wss" : "ws"
        c.user = nil; c.password = nil; c.fragment = nil
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/socket"
        c.queryItems = [URLQueryItem(name: "deviceId", value: deviceId)]
        guard let ws = c.url, sameOrigin(ws: ws, server: base) else { return nil }
        var r = URLRequest(url: ws)
        r.setValue(authorization, forHTTPHeaderField: "Authorization")
        return r
    }

    /// The socket link, read back as http(s), must have the server's scheme, host and port.
    static func sameOrigin(ws: URL, server: URL) -> Bool {
        guard var c = URLComponents(url: ws, resolvingAgainstBaseURL: false) else { return false }
        switch c.scheme?.lowercased() {
        case "ws": c.scheme = "http"
        case "wss": c.scheme = "https"
        default: return false
        }
        guard let http = c.url else { return false }
        return Net.sameOrigin(http, server)
    }

    let request: URLRequest
    private let makeTransport: (URLRequest) -> SocketTransport
    private let sleep: (TimeInterval) async throws -> Void
    var onConnect: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var onMessage: (SocketMessage) -> Void = { _ in }
    var onSessions: ([ActiveSession]) -> Void = { _ in }   // v1.19.0 Now Playing live
    var log: (String) -> Void = { _ in }

    private(set) var connected = false
    private(set) var keepAliveInterval = ServerSocket.keepAliveInterval(timeout: ServerSocket.defaultTimeout)
    private var attempt = 0
    private var runTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var transport: SocketTransport?

    init(request: URLRequest,
         makeTransport: @escaping (URLRequest) -> SocketTransport = { URLSessionSocketTransport(request: $0) },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.request = request
        self.makeTransport = makeTransport
        self.sleep = sleep
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runTask?.cancel(); runTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        transport?.close(); transport = nil
        connected = false
    }

    /// After wake from sleep: drop the (probably dead) connection and connect again right away.
    func reconnectNow() {
        stop()
        attempt = 0
        start()
    }

    private func run() async {
        while !Task.isCancelled {
            let t = makeTransport(request)
            transport = t
            log("SyncPlay: socket connecting (attempt \(attempt + 1))")
            do {
                try await t.open()
                guard !Task.isCancelled else { break }
                connected = true
                attempt = 0
                log("SyncPlay: socket connected to \(request.url?.host ?? "server")")
                startKeepAlive(ServerSocket.defaultTimeout, on: t)
                onConnect()
                while !Task.isCancelled {
                    handle(try await t.receive(), on: t)
                }
            } catch {
                if !Task.isCancelled {
                    let status = (t as? URLSessionSocketTransport)?.handshakeStatus.map { ", HTTP \($0)" } ?? ""
                    log("SyncPlay: socket error \((error as NSError).domain) \((error as NSError).code)\(status)")
                }
            }
            t.close()
            // Cancelled = stop() / reconnectNow() already reset the state (and may have started a new run)
            guard !Task.isCancelled else { break }
            connected = false
            keepAliveTask?.cancel(); keepAliveTask = nil
            transport = nil
            onDisconnect()
            let wait = Self.backoff(attempt: attempt)
            attempt += 1
            log("SyncPlay: socket closed, reconnecting in \(Int(wait)) s")
            do { try await sleep(wait) } catch { break }
        }
    }

    private func handle(_ text: String, on t: SocketTransport) {
        guard let env = SocketEnvelope.decode(text) else { return }
        switch env.message {
        case .forceKeepAlive(let timeout):
            startKeepAlive(timeout, on: t)
            Task { try? await t.send(Self.keepAliveText) }
        case .keepAlive: break
        case .other(let type): if ServerAlertDetector.socketTypes.contains(type) { onMessage(env.message) }   // server alerts
        case .syncPlayCommand, .syncPlayGroupUpdate: onMessage(env.message)
        case .sessions(let live): onSessions(live.list)   // v1.19.0 Now Playing live
        case .playstate, .generalCommand, .play: onMessage(env.message)   // SyncPlay phase 4: remote control
        // --- New-media notifications: published on SyncPlayService.messages ---
        case .libraryChanged(let ids): if !ids.isEmpty { onMessage(env.message) }
        // --- end new-media notifications ---
        }
    }

    // >>> v1.19.0 Now Playing live (Sessions)
    /// Sends a text message (e.g. SessionsStart). false when the socket isn't connected or the send failed.
    @discardableResult
    func sendText(_ text: String) async -> Bool {
        guard connected, let t = transport else { return false }
        do { try await t.send(text); return true } catch { return false }
    }
    // <<< v1.19.0 Now Playing live (Sessions)

    private func startKeepAlive(_ timeout: Int, on t: SocketTransport) {
        keepAliveTask?.cancel()
        let every = Self.keepAliveInterval(timeout: timeout)
        keepAliveInterval = every
        let sleep = self.sleep
        keepAliveTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleep(every)
                    guard !Task.isCancelled else { return }
                    try await t.send(Self.keepAliveText)
                } catch { return }
            }
        }
    }
}
