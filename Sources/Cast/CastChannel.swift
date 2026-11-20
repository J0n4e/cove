import Foundation
import Network
import Security

/// One TLS connection to a Cast device (port 8009 behind its Bonjour service). Cast devices use a self-signed
/// certificate, so it is accepted as is (the same as every Cast sender does). Sends CONNECT to receiver-0, keeps
/// the heartbeat (PING every 5 s, PONG to the device's PINGs) and hands every other message to `onMessage`.
/// All socket work runs on a private queue; the callbacks are delivered on the main queue.
final class CastChannel: @unchecked Sendable {
    enum State: Equatable { case connecting, ready, failed(String), closed }

    private let queue = DispatchQueue(label: "eu.jonae.cove.cast")
    private var conn: NWConnection?
    private var framer = CastFramer()
    private var heartbeat: DispatchSourceTimer?
    private var lastHeard = Date()
    private var finished = false
    private var isReady = false

    var onState: (State) -> Void = { _ in }
    var onMessage: (CastMessage) -> Void = { _ in }

    func connect(_ device: CastDevice) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        let params = NWParameters(tls: tls, tcp: tcp)
        let c = NWConnection(to: .service(name: device.service, type: "_googlecast._tcp", domain: device.domain, interface: nil),
                             using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] st in self?.handle(st) }
        DebugLog.write("cast: connecting to \(device.model)")
        c.start(queue: queue)
        // Never hang on "connecting": a device that went away fails after 10 s
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.finished, !self.isReady else { return }
            self.fail("timed out")
        }
    }

    private func handle(_ st: NWConnection.State) {
        switch st {
        case .ready:
            isReady = true
            DebugLog.write("cast: connected")
            send(.make(CastMessage.nsConnection, ["type": "CONNECT"]))
            startHeartbeat()
            receive()
            emit(.ready)
        case .failed(let e): fail(Self.describe(e))
        case .waiting(let e): DebugLog.write("cast: waiting (\(Self.describe(e)))")   // the 10 s timeout decides
        case .cancelled: if !finished { finished = true; emit(.closed) }
        default: break
        }
    }

    static func describe(_ e: NWError) -> String {
        switch e {
        case .posix(let c): return "POSIX \(c.rawValue)"
        case .dns(let c): return "DNS \(c)"
        case .tls(let c): return "TLS \(c)"
        default: return "\(e)"
        }
    }

    private func fail(_ why: String) {
        guard !finished else { return }
        finished = true
        DebugLog.write("cast: connection failed (\(why))")
        teardown()
        emit(.failed(why))
    }

    private func emit(_ s: State) { DispatchQueue.main.async { self.onState(s) } }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastHeard = Date()
                for m in self.framer.append(data) { self.dispatch(m) }
                if self.framer.broken { self.fail("bad data"); return }
            }
            if let err { self.fail(Self.describe(err)); return }
            if done { self.fail("closed by the device"); return }
            self.receive()
        }
    }

    private func dispatch(_ m: CastMessage) {
        if m.namespace == CastMessage.nsHeartbeat {
            if m.type == "PING" { send(.make(CastMessage.nsHeartbeat, ["type": "PONG"], to: m.source)) }
            return
        }
        DispatchQueue.main.async { self.onMessage(m) }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastHeard) > 20 { self.fail("no answer for 20 s"); return }
            self.send(.make(CastMessage.nsHeartbeat, ["type": "PING"]))
        }
        t.resume()
        heartbeat = t
    }

    /// Thread-safe: may be called from any queue.
    func send(_ m: CastMessage) {
        queue.async { [weak self] in
            guard let self, let c = self.conn, !self.finished else { return }
            c.send(content: m.framed(), completion: .contentProcessed { err in
                if let err { DebugLog.write("cast: send failed (\(Self.describe(err)))") }
            })
        }
    }

    private func teardown() {
        heartbeat?.cancel(); heartbeat = nil
        conn?.stateUpdateHandler = nil
        conn?.cancel(); conn = nil
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            if let c = self.conn {
                c.send(content: CastMessage.make(CastMessage.nsConnection, ["type": "CLOSE"]).framed(), completion: .idempotent)
            }
            self.finished = true
            self.teardown()
        }
    }
}
