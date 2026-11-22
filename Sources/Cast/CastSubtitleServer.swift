import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

// Cove serves the cast subtitle itself: Emby's own subtitle URLs have no CORS headers, so Google's Default Media
// Receiver can't fetch them as a side track (detailedErrorCode=100), and Emby's burn-in shows nothing on the TV.
// While a cast with a text subtitle runs, a tiny HTTP/1.1 server on this Mac serves the track as WebVTT with CORS
// headers at an unguessable path. Pure parts (VTT conversion, request parsing, responses, LAN address choice) are
// unit-tested in Tests/CastSubtitleServerTests.swift.

/// Cues → WebVTT.
enum CastVTT {
    /// "HH:MM:SS.mmm" (hours always shown, so tracks over an hour work).
    nonisolated static func stamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Text for a cue: ASS override tags and HTML-ish tags gone, &<> escaped, line breaks kept (ASS \N too).
    nonisolated static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // A blank line would end the cue early in WebVTT
        let lines = t.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n").replacingOccurrences(of: "-->", with: "--&gt;")
    }

    /// Every cue moved by `offsetMs` (positive = later); a cue pushed before 0 starts at 0, one that ends
    /// before 0 is dropped.
    nonisolated static func shift(_ cues: [Cue], offsetMs: Int) -> [Cue] {
        let off = Double(offsetMs) / 1000
        guard off != 0 else { return cues }
        return cues.compactMap { c in
            let a = max(0, c.start + off), e = c.end + off
            guard e > 0, e > a else { return nil }
            return Cue(start: a, end: e, text: c.text)
        }
    }

    /// A WebVTT file. `offsetMs`: positive shows the subtitles later (as the player's offset).
    nonisolated static func make(_ cues: [Cue], offsetMs: Int = 0) -> String {
        var out = "WEBVTT\n\n"
        for c in shift(cues, offsetMs: offsetMs) {
            let a = c.start, e = c.end
            guard e > 0, e > a else { continue }
            let text = clean(c.text)
            guard !text.isEmpty else { continue }
            out += "\(stamp(a)) --> \(stamp(e))\n\(text)\n\n"
        }
        return out
    }
}

/// The tiny HTTP side: parse one request, build one response.
enum CastHTTP {
    struct Request: Equatable { var method: String; var path: String }

    /// The request line of a (complete or partial) request head; nil until the first line has arrived.
    nonisolated static func parse(_ data: Data) -> Request? {
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let r = s.range(of: "\r\n") ?? s.range(of: "\n") else { return nil }
        let p = s[..<r.lowerBound].split(separator: " ")
        guard p.count >= 2 else { return nil }
        var path = String(p[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return Request(method: p[0].uppercased(), path: path)
    }

    /// True once the whole head (up to the blank line) has arrived.
    nonisolated static func headComplete(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil || data.range(of: Data("\n\n".utf8)) != nil
    }

    nonisolated static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Methods", "GET, OPTIONS"),
        ("Access-Control-Allow-Headers", "*"), ("Cache-Control", "no-cache"), ("Connection", "close"),
    ]

    struct Response: Equatable {
        var status: Int
        var headers: [(String, String)]
        var body: Data
        static func == (a: Response, b: Response) -> Bool {
            a.status == b.status && a.body == b.body && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
        }
        func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

        var data: Data {
            let reason = [200: "OK", 204: "No Content", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
            var h = "HTTP/1.1 \(status) \(reason)\r\n"
            for (k, v) in headers { h += "\(k): \(v)\r\n" }
            return Data((h + "\r\n").utf8) + body
        }
    }

    /// The answer for `req`: GET/HEAD of `/sub/<token>.vtt` → the VTT, OPTIONS → 204, anything else 404/405.
    nonisolated static func respond(_ req: Request?, token: String, vtt: Data) -> Response {
        func make(_ status: Int, _ type: String?, _ body: Data) -> Response {
            var h = corsHeaders
            if let type { h.insert(("Content-Type", type), at: 0) }
            h.append(("Content-Length", String(body.count)))
            return Response(status: status, headers: h, body: body)
        }
        guard let req, !token.isEmpty, req.path == path(token) else { return make(404, "text/plain", Data("Not found".utf8)) }
        switch req.method {
        case "OPTIONS": return make(204, nil, Data())
        case "GET": return make(200, "text/vtt; charset=utf-8", vtt)
        case "HEAD":
            var r = make(200, "text/vtt; charset=utf-8", Data())
            if let i = r.headers.firstIndex(where: { $0.0 == "Content-Length" }) { r.headers[i].1 = String(vtt.count) }
            return r
        default: return make(405, "text/plain", Data())
        }
    }

    nonisolated static func path(_ token: String) -> String { "/sub/\(token).vtt" }

    /// 32 random hex characters.
    nonisolated static func newToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Which of this Mac's addresses the TV can reach.
enum CastLAN {
    struct Interface: Equatable { var name: String; var ip: String; var mask: String }

    nonisolated static func v4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".")
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p { guard let b = UInt8(x) else { return nil }; v = v << 8 | UInt32(b) }
        return v
    }

    nonisolated static func isLoopback(_ ip: String) -> Bool { ip.hasPrefix("127.") }
    nonisolated static func isLinkLocal(_ ip: String) -> Bool { ip.hasPrefix("169.254.") }

    /// The address in the TV's subnet; else the first non-loopback en* address; else any usable one.
    nonisolated static func pick(tv: String?, _ ifs: [Interface]) -> String? {
        let usable = ifs.filter { v4($0.ip) != nil && !isLoopback($0.ip) }
        if let tv, let t = v4(tv) {
            if let m = usable.first(where: { i in
                guard let a = v4(i.ip), let k = v4(i.mask), k != 0 else { return false }
                return a & k == t & k
            }) { return m.ip }
        }
        if let e = usable.first(where: { $0.name.hasPrefix("en") && !isLinkLocal($0.ip) }) { return e.ip }
        return usable.first { !isLinkLocal($0.ip) }?.ip ?? usable.first?.ip
    }

    /// This Mac's IPv4 interfaces.
    static func interfaces() -> [Interface] {
        var out: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            func str(_ sa: UnsafeMutablePointer<sockaddr>?) -> String? {
                guard let sa else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            guard let ip = str(a) else { continue }
            out.append(Interface(name: String(cString: i.pointee.ifa_name), ip: ip, mask: str(i.pointee.ifa_netmask) ?? "255.255.255.0"))
        }
        return out
    }
}

#if canImport(Network)
/// The HTTP server itself. Runs only while a cast with a text subtitle is on; all socket work on a private queue.
final class CastSubtitleServer: @unchecked Sendable {
    static let shared = CastSubtitleServer()

    private let queue = DispatchQueue(label: "eu.jonae.cove.castsubs")
    private var listener: NWListener?
    private var port: UInt16?
    private var token = ""
    private var vtt = Data()
    private var fetchesLogged = Set<String>()

    /// Serves `vtt` at a new unguessable path and returns its URL for the TV (nil: no server / no LAN address).
    /// `tv`: the Cast device's IPv4, `local`: this Mac's address on the connection to it (best when known).
    func serve(_ vttText: String, tv: String?, local: String?) async -> URL? {
        guard let port = await start() else { return nil }
        let host: String? = (local.flatMap { CastLAN.v4($0) != nil && !CastLAN.isLoopback($0) ? $0 : nil })
            ?? CastLAN.pick(tv: tv, CastLAN.interfaces())
        guard let host else { DebugLog.write("cast: no LAN address for the subtitle server"); return nil }
        let t = CastHTTP.newToken()
        let body = Data(vttText.utf8)
        queue.sync { token = t; vtt = body; fetchesLogged = [] }
        DebugLog.write("cast: subtitle server on \(host):\(port)")
        return URL(string: "http://\(host):\(port)\(CastHTTP.path(t))")
    }

    /// Starts listening (port picked by the system); the port, or nil when it failed.
    private func start() async -> UInt16? {
        if let p = queue.sync(execute: { port }) { return p }
        return await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            queue.async {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let l = try? NWListener(using: params, on: .any) else {
                    DebugLog.write("cast: subtitle server couldn't start"); cont.resume(returning: nil); return
                }
                var resumed = false
                func done(_ p: UInt16?) { if !resumed { resumed = true; cont.resume(returning: p) } }
                l.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready: self.port = l.port?.rawValue; done(self.port)
                    case .failed(let e):
                        DebugLog.write("cast: subtitle server failed (\(e))")
                        self.listener = nil; self.port = nil; l.cancel(); done(nil)
                    case .cancelled: done(nil)
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                self.listener = l
                l.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 5) { done(nil) }
            }
        }
    }

    // MARK: AirPlay local HLS (Player/AirPlayLocalHLS.swift): /hls/<token>/master.m3u8, subs.m3u8, sub_<i>.vtt

    private var hlsToken = ""
    private var hlsMaster = ""
    private var hlsSubs = ""
    private var hlsCues: [Cue] = []
    private var hlsMpegts = 0
    private var hlsOffsetMs = 0

    /// Serves an AirPlay master playlist (built by `master(subsURI)`) and its WebVTT rendition cut from `cues`.
    /// Returns the master's URL on this Mac's LAN address (nil: no server / no address).
    func serveHLS(master: (String) -> String?, cues: [Cue], duration: Double, offsetMs: Int, mpegts: Int) async -> URL? {
        guard let port = await start() else { return nil }
        guard let host = CastLAN.pick(tv: nil, CastLAN.interfaces()) else {
            DebugLog.write("airplay: no LAN address for the local HLS"); return nil
        }
        let t = CastHTTP.newToken()
        let base = "http://\(host):\(port)/hls/\(t)/"
        guard let m = master(base + "subs.m3u8") else { return nil }
        let subs = AirPlayHLS.subsPlaylist(duration: duration) { base + "sub_\($0).vtt" }
        queue.sync {
            hlsToken = t; hlsMaster = m; hlsSubs = subs; hlsCues = cues; hlsMpegts = mpegts; hlsOffsetMs = offsetMs
            fetchesLogged = []
        }
        return URL(string: base + "master.m3u8")
    }

    /// New cues for the served rendition (another text track, or the offset changed): same URLs.
    func updateHLSCues(_ cues: [Cue], offsetMs: Int) {
        queue.async { self.hlsCues = cues; self.hlsOffsetMs = offsetMs; self.fetchesLogged = [] }
    }

    /// Only the offset changed (the player's ± buttons during AirPlay): segments fetched from now on are shifted.
    func updateHLSOffset(_ offsetMs: Int) {
        queue.async { self.hlsOffsetMs = offsetMs }
    }

    /// Stops serving the AirPlay HLS (the listener stays while a Cast subtitle uses it).
    func stopHLS() {
        queue.async {
            guard !self.hlsToken.isEmpty else { return }
            self.hlsToken = ""; self.hlsMaster = ""; self.hlsSubs = ""; self.hlsCues = []
            DebugLog.write("airplay: local HLS stopped")
            if self.token.isEmpty, self.listener != nil {
                self.listener?.cancel(); self.listener = nil; self.port = nil
            }
        }
    }

    /// The /hls/ answer, or nil when the path isn't one of ours.
    private func hlsResponse(_ req: CastHTTP.Request) -> CastHTTP.Response? {
        let cues = hlsCues, ts = hlsMpegts, off = hlsOffsetMs
        guard let (type, body) = AirPlayHLS.route(req.path, token: hlsToken, master: hlsMaster, subs: hlsSubs,
                                                  segment: { i in i >= 0 ? AirPlayHLS.segment(cues, index: i, mpegts: ts, offsetMs: off) : nil })
        else { return nil }
        var h = CastHTTP.corsHeaders
        h.insert(("Content-Type", type), at: 0)
        let data = Data(body.utf8)
        h.append(("Content-Length", String(data.count)))
        switch req.method {
        case "OPTIONS": return CastHTTP.Response(status: 204, headers: CastHTTP.corsHeaders, body: Data())
        case "HEAD": return CastHTTP.Response(status: 200, headers: h, body: Data())
        case "GET": return CastHTTP.Response(status: 200, headers: h, body: data)
        default: return CastHTTP.Response(status: 405, headers: CastHTTP.corsHeaders, body: Data())
        }
    }

    func stop() {
        queue.async {
            guard self.listener != nil else { return }
            guard self.hlsToken.isEmpty else {   // AirPlay still uses the server: only the Cast subtitle goes
                self.token = ""; self.vtt = Data(); return
            }
            self.listener?.cancel(); self.listener = nil; self.port = nil
            self.token = ""; self.vtt = Data()
            DebugLog.write("cast: subtitle server stopped")
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
        queue.asyncAfter(deadline: .now() + 15) { c.cancel() }   // never keep a stuck client
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = got
            if let data { buf.append(data) }
            if CastHTTP.headComplete(buf) || done || err != nil || buf.count > 32_768 {
                self.answer(c, CastHTTP.parse(buf))
            } else {
                self.read(c, buf)
            }
        }
    }

    private func answer(_ c: NWConnection, _ req: CastHTTP.Request?) {
        if let req, req.path.hasPrefix("/hls/"), let r = hlsResponse(req) {
            let what = AirPlayHLS.fetchName(req.path)
            if fetchesLogged.insert("hls \(what)").inserted { DebugLog.write("airplay: TV/player fetched \(what)") }
            c.send(content: r.data, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let r = CastHTTP.respond(req, token: token, vtt: vtt)
        if r.status != 404, let req {
            var from = "?"
            if case .hostPort(let h, _) = c.endpoint { from = "\(h)".components(separatedBy: "%").first ?? "\(h)" }
            let key = "\(req.method) \(from)"
            if fetchesLogged.insert(key).inserted { DebugLog.write("cast: TV fetched the subtitle (\(req.method), from \(from))") }
        } else {
            DebugLog.write("cast: subtitle server: 404 for \(req?.method ?? "a bad request")")
        }
        c.send(content: r.data, completion: .contentProcessed { _ in c.cancel() })
    }
}
#endif

#if canImport(IOKit)
/// Keeps the Mac from idle sleep while the TV may still fetch the subtitle from it.
enum CastSubAwake {
    private static var id: IOPMAssertionID = 0
    static func set(_ on: Bool) {
        if on, id == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Cove Cast subtitles" as CFString, &id)
        } else if !on, id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
}
#endif
