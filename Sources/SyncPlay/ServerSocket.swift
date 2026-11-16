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

    func open() async throws {
        task.resume()
        // URLSession can call the ping handler more than once (e.g. a failed handshake and then the cancel);
        // resuming a continuation twice crashes the app, so only the first call counts
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { e in
                guard once.claim() else { return }
                if let e { c.resume(throwing: e) } else { c.resume() }
            }
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

    private enum K: String, CodingKey { case GroupId, type = "Type", Data }
    private struct StateData: Decodable { let State: String?; let Reason: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        GroupId = try c.decode(String.self, forKey: .GroupId)
        type = try c.decode(String.self, forKey: .type)
        text = try? c.decode(String.self, forKey: .Data)
        let s = try? c.decode(StateData.self, forKey: .Data)
        state = s?.State; reason = s?.Reason
    }
}

enum SocketMessage: Equatable {
    case forceKeepAlive(timeout: Int)
    case keepAlive
    case syncPlayCommand(SyncPlayCommand)
    case syncPlayGroupUpdate(SyncPlayGroupUpdate)
    /// Anything else (Playstate, GeneralCommand, UserDataChanged…): ignored in phase 1.
    case other(String)
}

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
        default: message = .other(type)
        }
    }

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
                if !Task.isCancelled { log("SyncPlay: socket error \((error as NSError).domain) \((error as NSError).code)") }
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
        case .keepAlive, .other: break
        case .syncPlayCommand, .syncPlayGroupUpdate: onMessage(env.message)
        }
    }

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
