import Foundation

/// Casting one movie/episode to a Cast device with Google's Default Media Receiver: connect, LAUNCH the receiver,
/// CONNECT to its transport, LOAD the server's HLS stream, then act as the remote (play/pause/seek/volume/stop,
/// audio or subtitle switch = reload at the current position). The receiver's MEDIA_STATUS drives the remote and
/// the server reports (/Sessions/Playing, …/Progress every 10 s, …/Stopped), so watched state and Continue Watching
/// stay right.
@MainActor
final class CastSession: ObservableObject {
    static let shared = CastSession()

    enum Phase: Equatable { case idle, connecting, loading, active }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var device: CastDevice?
    @Published private(set) var item: Item?
    @Published private(set) var playerState = "IDLE"
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 1
    @Published var error: String?
    /// The item's audio and subtitle tracks (for the remote's menus)
    @Published private(set) var streams: [MStream] = []
    @Published private(set) var audio: Int?
    @Published private(set) var sub: Int?
    /// Bumped every second while playing, so the remote's clock moves.
    @Published private(set) var tick = 0

    var isCasting: Bool { phase != .idle }
    var isPlaying: Bool { playerState == "PLAYING" || playerState == "BUFFERING" }

    private var channel: CastChannel?
    private weak var emby: Emby?
    private var requestId = 0
    private var transportId: String?
    private var receiverSession: String?
    private var mediaSessionId: Int?
    private var request: CastRequest?
    private var playSession: Emby.PlaySession?
    private var reportedStart = false
    private var lastReport: Double = -100
    private var statusTime: Double = 0
    private var statusDate = Date()
    private var clock: Task<Void, Never>?
    private var loadSent = false

    /// The receiver's position now (its reports come only on changes, so it is moved on while playing).
    var time: Double {
        guard playerState == "PLAYING" else { return statusTime }
        let t = statusTime + Date().timeIntervalSince(statusDate)
        return duration > 0 ? min(t, duration) : t
    }

    private func nextId() -> Int { requestId += 1; return requestId }

    // MARK: Start

    /// Casts `item` from `start` seconds with the given tracks. A running cast to another item is replaced.
    func cast(_ item: Item, to device: CastDevice, emby: Emby, sourceId: String?, audio: Int?, sub: Int?, start: Double) {
        if CastStream.isLocalOnly(emby.server) {
            error = CastError.localServer.message
            DebugLog.write("cast: server address is local only")
            return
        }
        let sameDevice = self.device?.id == device.id && channel != nil && transportId != nil
        if !sameDevice { end(report: true, quitReceiver: false) } else { reportStop() }
        self.emby = emby
        self.device = device
        self.item = item
        self.audio = audio
        self.sub = sub
        error = nil
        CastDeviceStore.shared.lastUsedId = device.id
        request = CastRequest(itemId: item.id, sourceId: sourceId, audio: audio, sub: sub, start: start)
        statusTime = start; statusDate = Date(); duration = Double(item.RunTimeTicks ?? 0) / 10_000_000
        playerState = "BUFFERING"
        Task {
            let f = await emby.full(item.id)
            guard self.item?.id == item.id else { return }
            let src = f?.MediaSources?.first { $0.Id == sourceId } ?? f?.MediaSources?.first
            streams = src?.MediaStreams ?? []
            if request?.sourceId == nil { request?.sourceId = src?.Id }
            if let s = sub { request?.subIsImage = isImageSub(s) }
            if sameDevice { phase = .loading; sendLoad() } else { connect(device) }
        }
    }

    private func connect(_ device: CastDevice) {
        phase = .connecting
        let c = CastChannel()
        channel = c
        c.onState = { [weak self, weak c] st in
            guard let self, let c, self.channel === c else { return }
            switch st {
            case .ready:
                self.phase = .loading
                self.send(CastMessage.nsReceiver, ["type": "LAUNCH", "appId": CastStream.receiverAppId])
            case .failed:
                self.fail(self.phase == .connecting
                          ? "\(device.name) isn't reachable. Check that it's on and on the same network as this Mac."
                          : "The connection to \(device.name) was lost.")
            case .closed:
                if self.phase != .idle { self.fail("The connection to \(device.name) was closed.") }
            case .connecting: break
            }
        }
        c.onMessage = { [weak self, weak c] m in
            guard let self, let c, self.channel === c else { return }
            self.handle(m)
        }
        transportId = nil; mediaSessionId = nil; receiverSession = nil; loadSent = false
        c.connect(device)
    }

    private func send(_ ns: String, _ body: [String: Any], to dst: String = "receiver-0") {
        var b = body
        if b["requestId"] == nil && ns != CastMessage.nsConnection { b["requestId"] = nextId() }
        channel?.send(.make(ns, b, to: dst))
    }

    private func isImageSub(_ idx: Int) -> Bool {
        streams.first { $0.Index == idx }.map { imageSubCodecs.contains(($0.Codec ?? "").lowercased()) } ?? false
    }

    private func sendLoad() {
        guard let emby, let item, var req = request, let tid = transportId else { return }
        let ps = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profile = device?.profile ?? .basic
        let url: URL
        switch CastStream.url(server: emby.server, token: emby.token, keyName: emby.keyName, deviceId: emby.deviceId,
                              playSessionId: ps, req: req, profile: profile) {
        case .failure(let e): fail(e.message); return
        case .success(let u): url = u
        }
        var subtitle: (url: URL, name: String, lang: String?)?
        if let s = req.sub, !req.subIsImage, let sid = req.sourceId,
           let u = CastStream.subtitleURL(server: emby.server, token: emby.token, keyName: emby.keyName,
                                          itemId: item.id, sourceId: sid, index: s) {
            let st = streams.first { $0.Index == s }
            subtitle = (u, st?.DisplayTitle ?? "Subtitles", st?.Language)
        }
        var images: [URL] = []
        if let b = item.backdropId, let u = CastStream.imageURL(server: emby.server, token: emby.token, keyName: emby.keyName, id: b, kind: "Backdrop") { images.append(u) }
        if let u = CastStream.imageURL(server: emby.server, token: emby.token, keyName: emby.keyName, id: item.posterId, kind: "Primary") { images.append(u) }
        let meta = CastMeta(title: item.Name, seriesTitle: item.isEpisode ? item.SeriesName : nil,
                            season: item.isEpisode ? item.ParentIndexNumber : nil, episode: item.isEpisode ? item.IndexNumber : nil,
                            images: images, duration: duration > 0 ? duration : nil)
        playSession = Emby.PlaySession(itemId: item.id, sourceId: req.sourceId, method: "Transcode", url: url,
                                       server: emby.server, token: emby.token)
        reportedStart = false
        mediaSessionId = nil
        loadSent = true
        req.start = statusTime
        let body = CastLoad.body(url: url, hls: true, meta: meta, start: req.start, subtitle: subtitle,
                                 hevc: profile.hevc, requestId: nextId())
        DebugLog.write("cast: LOAD at \(Int(req.start)) s (\(profile.videoCodecs)/\(profile.audioCodecs), sub: \(req.sub.map(String.init) ?? "off")\(req.subIsImage ? " burned in" : ""))")
        channel?.send(.make(CastMessage.nsMedia, body, to: tid))
        startClock()
    }

    // MARK: Messages

    private func handle(_ m: CastMessage) {
        guard let j = m.json, let type = j["type"] as? String else { return }
        switch (m.namespace, type) {
        case (CastMessage.nsReceiver, "RECEIVER_STATUS"):
            guard let st = CastReceiverStatus.parse(j) else { return }
            if let v = st.volume { volume = v }
            if let tid = st.transportId {
                receiverSession = st.sessionId
                if transportId != tid {
                    transportId = tid
                    DebugLog.write("cast: receiver running")
                    channel?.send(.make(CastMessage.nsConnection, ["type": "CONNECT"], to: tid))
                    send(CastMessage.nsMedia, ["type": "GET_STATUS"], to: tid)
                    if !loadSent { sendLoad() }
                }
            } else if transportId != nil {
                fail(st.otherApp.map { "\($0) took over the TV." } ?? "The TV closed the player.")
            }
        case (CastMessage.nsReceiver, "LAUNCH_ERROR"):
            fail("The TV couldn't start the Cast player (\(j["reason"] as? String ?? "unknown reason")).")
        case (CastMessage.nsConnection, "CLOSE"):
            if m.source == transportId { fail("The TV closed the player.") }
        case (CastMessage.nsMedia, "MEDIA_STATUS"):
            guard let st = CastMediaStatus.parse(j) else { return }
            apply(st)
        case (CastMessage.nsMedia, "LOAD_FAILED"):
            fail("The TV couldn't load this video. The server may not be reachable from the TV at \(URL(string: emby?.server ?? "")?.host ?? "its address").")
        case (CastMessage.nsMedia, "INVALID_REQUEST"):
            DebugLog.write("cast: invalid request (\(j["reason"] as? String ?? "?"))")
        default: break
        }
    }

    private func apply(_ st: CastMediaStatus) {
        // An old session's status after a reload: ignore
        if let cur = mediaSessionId, st.mediaSessionId < cur { return }
        mediaSessionId = st.mediaSessionId
        if st.playerState != playerState { DebugLog.write("cast: \(st.playerState)\(st.idleReason.map { " (\($0))" } ?? "") at \(Int(st.currentTime)) s") }
        if let d = st.duration, d > 0 { duration = d }
        if st.playerState == "IDLE" {
            switch st.idleReason {
            case "FINISHED": statusTime = duration; finish(nil)
            case "ERROR": fail("The TV couldn't play this video.")
            case "CANCELLED": finish(nil)
            default: break   // INTERRUPTED: a new LOAD replaced it
            }
            return
        }
        playerState = st.playerState
        statusTime = st.currentTime; statusDate = Date()
        phase = .active
        if !reportedStart, st.playerState == "PLAYING", let ps = playSession, let e = emby {
            reportedStart = true
            lastReport = st.currentTime
            Task { await e.reportStart(ps, st.currentTime) }
        } else {
            report(force: true)
        }
    }

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase != .idle else { return }
                self.tick &+= 1
                n += 1
                self.report(force: false)
                if n % 15 == 0, let tid = self.transportId { self.send(CastMessage.nsMedia, ["type": "GET_STATUS"], to: tid) }
            }
        }
    }

    private func report(force: Bool) {
        guard reportedStart, let ps = playSession, let e = emby else { return }
        let t = time
        guard force || abs(t - lastReport) >= 10 else { return }
        lastReport = t
        let paused = playerState == "PAUSED"
        Task { await e.reportProgress(ps, t, paused: paused) }
    }

    private func reportStop() {
        guard let ps = playSession, let e = emby else { return }
        let t = time, d = duration
        playSession = nil
        if reportedStart { Task { await e.reportStopped(ps, t, duration: d) } } else { Task { await e.stopEncoding(ps) } }
        reportedStart = false
    }

    // MARK: Remote

    private func media(_ type: String, _ extra: [String: Any] = [:]) {
        guard let tid = transportId, let ms = mediaSessionId else { return }
        var b = extra
        b["type"] = type; b["mediaSessionId"] = ms
        send(CastMessage.nsMedia, b, to: tid)
    }

    func togglePlay() {
        if playerState == "PAUSED" { media("PLAY") } else { media("PAUSE") }
    }

    func seek(to t: Double) {
        let c = max(0, duration > 0 ? min(t, duration - 1) : t)
        statusTime = c; statusDate = Date()
        media("SEEK", ["currentTime": c])
    }

    func skip(_ d: Double) { seek(to: time + d) }

    func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        send(CastMessage.nsReceiver, ["type": "SET_VOLUME", "volume": ["level": volume]])
    }

    /// Audio or subtitle change: the server must make a new stream, so reload at the current position.
    func setAudio(_ idx: Int) { reload { $0.audio = idx }; audio = idx }
    func setSub(_ idx: Int?) {
        sub = idx
        reload { r in r.sub = idx; r.subIsImage = idx.map(isImageSub) ?? false }
    }

    private func reload(_ change: (inout CastRequest) -> Void) {
        guard var r = request, transportId != nil else { return }
        change(&r)
        request = r
        statusTime = time; statusDate = Date()
        reportStop()
        sendLoad()
    }

    /// The × in the remote: stop on the TV (its player closes) and end the session.
    func stop() {
        DebugLog.write("cast: stopped by the user")
        end(report: true, quitReceiver: true)
    }

    // MARK: End

    private func fail(_ message: String) {
        guard phase != .idle else { return }
        DebugLog.write("cast: \(message)")
        error = message
        end(report: true, quitReceiver: false)
    }

    private func finish(_ message: String?) {
        DebugLog.write("cast: playback ended")
        end(report: true, quitReceiver: false)
    }

    private func end(report: Bool, quitReceiver: Bool) {
        if report { reportStop() }
        if quitReceiver {
            if mediaSessionId != nil { media("STOP") }
            if let s = receiverSession { send(CastMessage.nsReceiver, ["type": "STOP", "sessionId": s]) }
        }
        clock?.cancel(); clock = nil
        let c = channel
        channel = nil
        // Let the STOP messages go out before closing
        if let c { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.close() } }
        transportId = nil; mediaSessionId = nil; receiverSession = nil; loadSent = false
        phase = .idle
        playerState = "IDLE"
        item = nil
        request = nil
    }
}
