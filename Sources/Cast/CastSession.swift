import AppKit
import Foundation
import Network

/// Casting one movie/episode to a Cast device with Google's Default Media Receiver: connect, LAUNCH the receiver,
/// CONNECT to its transport, LOAD the server's HLS stream, then act as the remote (play/pause/seek/volume/stop,
/// audio or subtitle switch = reload at the current position). The receiver's MEDIA_STATUS drives the remote and
/// the server reports (/Sessions/Playing, …/Progress every 10 s, …/Stopped), so watched state and Continue Watching
/// stay right. Phase 2: the next episode / next film of a collection continues on the TV (CastSessionNext.swift),
/// and a lost connection (sleep, Wi-Fi change, heartbeat timeout) re-attaches to the running cast instead of
/// ending it; a relaunch shows the remote again while the TV still plays it (CastSessionReconnect.swift).
@MainActor
final class CastSession: ObservableObject {
    static let shared = CastSession()

    enum Phase: Equatable { case idle, connecting, loading, active }

    @Published var phase: Phase = .idle
    @Published var device: CastDevice?
    @Published var item: Item?
    @Published var playerState = "IDLE"
    @Published var duration: Double = 0
    @Published var volume: Double = 1
    @Published var error: String?
    /// The item's audio and subtitle tracks (for the remote's menus)
    @Published var streams: [MStream] = []
    @Published var audio: Int?
    @Published var sub: Int?
    /// Bumped every second while playing, so the remote's clock moves.
    @Published var tick = 0
    /// Collection mode (cast from Play collection / Resume collection, or from a player in collection mode)
    @Published var collection: CollectionQueue?
    /// The Up next card's item, while it shows (credits on, autoplay on, not cancelled)
    @Published var upNext: Item?
    @Published var upNextCancelled = false
    /// Reconnecting after a lost connection: the remote says so and its buttons wait
    @Published var reconnecting = false
    /// A short line in the remote ("Reconnected to Living room TV"), cleared after a few seconds
    @Published var notice: String?

    var isCasting: Bool { phase != .idle }
    var isPlaying: Bool { playerState == "PLAYING" || playerState == "BUFFERING" }

    var channel: CastChannel?
    weak var emby: Emby?
    private var requestId = 0
    var transportId: String?
    var receiverSession: String?
    var mediaSessionId: Int?
    var request: CastRequest?
    var playSession: Emby.PlaySession?
    var reportedStart = false
    private var lastReport: Double = -100
    var statusTime: Double = 0
    var statusDate = Date()
    private var clock: Task<Void, Never>?
    /// The series' episodes (next episode) and the credits marker (Emby chapter CreditsStart / Jellyfin Outro)
    var episodes: [Item] = []
    var creditsMarker: Double?
    // Reconnect state (CastSessionReconnect.swift)
    var awaitingReceiver = false
    var awaitingMedia = false
    var reconnectBegan = Date()
    var attempt = 0
    var reconnectTask: Task<Void, Never>?
    var browsing = false
    var restoreTried = false
    /// Re-attaching to a cast saved before a relaunch: a failure ends silently
    var restoring = false
    var pathMonitor: NWPathMonitor?
    var wakeObserver: NSObjectProtocol?
    var lastPath: String?
    var loadSent = false
    /// When the last LOAD went out, and whether the no-subtitles retry was used (CastSubtitles.swift)
    var loadAt = Date()
    var subRetryNoSubs = false
    /// The subtitle as Cove serves it to the TV (CastSubtitleServer.swift), for the LOAD's side track
    var subURL: URL?
    var subVTT: String?

    /// The receiver's position now (its reports come only on changes, so it is moved on while playing).
    var time: Double {
        guard playerState == "PLAYING" else { return statusTime }
        let t = statusTime + Date().timeIntervalSince(statusDate)
        return duration > 0 ? min(t, duration) : t
    }

    private init() { observeSystem() }

    func nextId() -> Int { requestId += 1; return requestId }

    // MARK: Start

    /// Casts `item` from `start` seconds with the given tracks. A running cast to another item is replaced.
    /// `collection`: collection mode (the queue continues on the TV). `pickTracks`: choose audio/subtitles as local
    /// playback would (series/collection memory, preferred language, SRT first) instead of `audio`/`sub`;
    /// `wantedSub` is the detail page's episode Subtitles menu ("off" or a language).
    func cast(_ item: Item, to device: CastDevice, emby: Emby, sourceId: String?, audio: Int?, sub: Int?, start: Double,
              collection: CollectionQueue? = nil, pickTracks: Bool = false, wantedSub: String? = nil) {
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
        self.collection = collection
        upNext = nil; upNextCancelled = false; creditsMarker = nil
        if !(item.isEpisode && collection == nil && episodes.contains { $0.Id == item.Id }) { episodes = [] }
        error = nil
        subRetryNoSubs = false
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
            if pickTracks {
                let d = UserDefaults.standard
                let t = CastTracks.pick(streams, memory: CastContinue.memoryKey(item, collection: collection).flatMap(SeriesLang.get),
                                        wantedSub: wantedSub, subAlways: d.bool(forKey: "subAlways"), subLang: d.string(forKey: "subLang"))
                self.audio = t.audio; self.sub = t.sub
                request?.audio = t.audio; request?.sub = t.sub
                DebugLog.write("cast: tracks from memory (audio \(t.audio.map(String.init) ?? "default"), sub \(t.sub.map(String.init) ?? "off"))")
            }
            await prepareSubtitle()
            guard self.item?.id == item.id else { return }
            loadContinuation(emby, item, chapters: f?.Chapters ?? [])
            if sameDevice { phase = .loading; sendLoad() } else { connect(device) }
        }
    }

    func connect(_ device: CastDevice, reattach: Bool = false) {
        if !reattach { phase = .connecting }
        awaitingReceiver = reattach
        let c = CastChannel()
        channel = c
        c.onState = { [weak self, weak c] st in
            guard let self, let c, self.channel === c else { return }
            switch st {
            case .ready:
                if self.awaitingReceiver { self.send(CastMessage.nsReceiver, ["type": "GET_STATUS"]); return }
                self.phase = .loading
                self.send(CastMessage.nsReceiver, ["type": "LAUNCH", "appId": CastStream.receiverAppId])
            case .failed, .closed:
                if self.reconnecting { self.scheduleAttempt(); return }
                if self.phase == .connecting {
                    self.fail("\(device.name) isn't reachable. Check that it's on and on the same network as this Mac.")
                } else if self.phase != .idle {
                    self.startReconnect("connection lost")   // heartbeat timeout, Wi-Fi drop, TV off: retry first
                }
            case .connecting: break
            }
        }
        c.onMessage = { [weak self, weak c] m in
            guard let self, let c, self.channel === c else { return }
            self.handle(m)
        }
        transportId = nil; mediaSessionId = nil; loadSent = reattach
        if !reattach { receiverSession = nil }
        c.connect(device)
    }

    func send(_ ns: String, _ body: [String: Any], to dst: String = "receiver-0") {
        var b = body
        if b["requestId"] == nil && ns != CastMessage.nsConnection { b["requestId"] = nextId() }
        channel?.send(.make(ns, b, to: dst))
    }

    func isImageSub(_ idx: Int) -> Bool {
        streams.first { $0.Index == idx }.map { imageSubCodecs.contains(($0.Codec ?? "").lowercased()) } ?? false
    }

    func sendLoad() {
        guard let emby, let item, let req = request, let tid = transportId else { return }
        if req.sub != nil, !req.subIsImage, subVTT != nil, subURL == nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.publishSubtitle()
                guard self.item?.id == item.id, self.transportId == tid else { return }
                if self.subURL == nil { self.request?.sub = nil }
                self.sendLoad()
            }
            return
        }
        let ps = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profile = device?.profile ?? .basic
        let url: URL
        switch CastStream.url(server: emby.server, token: emby.token, keyName: emby.keyName, deviceId: emby.deviceId,
                              playSessionId: ps, req: req, profile: profile) {
        case .failure(let e): fail(e.message); return
        case .success(let u): url = u
        }
        // Emby ignores hand-built burn-in params: ask PlaybackInfo for the server's own burn-in stream
        if let s = req.sub, req.subIsImage, Emby.burnInRoute(isJellyfin: emby.isJellyfin) == .playbackInfo {
            let itemId = item.id
            Task { @MainActor [weak self] in
                let got = await emby.burnInPlaybackInfo(itemId: itemId, sourceId: req.sourceId, sub: s, audio: req.audio,
                                                        start: nil, maxBitrate: 40_000_000,
                                                        audioCodecs: profile.audioCodecs, addKey: true)
                guard let self, self.item?.id == itemId, self.transportId == tid else { return }
                self.sendLoad(url: got?.url ?? url, emby: emby, item: item, req: req, tid: tid, profile: profile)
            }
            return
        }
        sendLoad(url: url, emby: emby, item: item, req: req, tid: tid, profile: profile)
    }

    private func sendLoad(url: URL, emby: Emby, item: Item, req: CastRequest, tid: String, profile: CastProfile) {
        var req = req
        var subtitle: (url: URL, name: String, lang: String?)?
        if let s = req.sub, !req.subIsImage, let u = subURL {
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
        loadAt = Date()
        req.start = statusTime
        let body = CastLoad.body(url: url, hls: true, meta: meta, start: req.start, subtitle: subtitle,
                                 hevc: profile.hevc, requestId: nextId(), textStyle: Self.textStyle())
        DebugLog.write("cast: LOAD at \(Int(req.start)) s (\(profile.videoCodecs)/\(profile.audioCodecs), sub: \(req.sub.map(String.init) ?? "off")\(req.subIsImage ? " burned in" : (subtitle != nil ? " served by Cove" : "")))\(req.subIsImage && req.sub != nil ? " [\(Emby.burnInLog(url.absoluteString))]" : "")")
        channel?.send(.make(CastMessage.nsMedia, body, to: tid))
        startClock()
        saveActive()
    }

    /// Cast text style from Cove's subtitle appearance settings.
    static func textStyle() -> [String: Any] {
        let d = UserDefaults.standard
        return CastSubtitles.style(size: d.string(forKey: "subTextSize"), color: d.string(forKey: "subColor"),
                                   shadow: d.string(forKey: "subShadowStyle"), bg: d.string(forKey: "subBg"))
    }

    // MARK: Messages

    private func handle(_ m: CastMessage) {
        guard let j = m.json, let type = j["type"] as? String else { return }
        switch (m.namespace, type) {
        case (CastMessage.nsReceiver, "RECEIVER_STATUS"):
            guard let st = CastReceiverStatus.parse(j) else { return }
            if awaitingReceiver { reattach(st); return }
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
                endCleanly(st.otherApp != nil ? CastReconnect.takenOverMessage : CastReconnect.endedMessage)
            }
        case (CastMessage.nsReceiver, "LAUNCH_ERROR"):
            fail("The TV couldn't start the Cast player (\(j["reason"] as? String ?? "unknown reason")).")
        case (CastMessage.nsConnection, "CLOSE"):
            if m.source == transportId { fail("The TV closed the player.") }
        case (CastMessage.nsMedia, "MEDIA_STATUS"):
            let st = CastMediaStatus.parse(j)
            if awaitingMedia { reattached(st); return }
            guard let st else { return }
            if st.playerState == "IDLE", st.idleReason == "ERROR" {
                let s = request?.sub
                let sd = s.map { i in CastSubtitles.describe(i, streams.first { $0.Index == i }) } ?? "none"
                DebugLog.write("cast: receiver error (\(Self.errorDetails(j))), sub sent: \(sd)\(request?.subIsImage == true ? " burned in" : (s != nil ? " side track" : "")), \(Int(Date().timeIntervalSince(loadAt))) s after LOAD")
            }
            apply(st)
        case (CastMessage.nsMedia, "ERROR"):
            DebugLog.write("cast: receiver error event (\(Self.errorDetails(j)))")
        case (CastMessage.nsMedia, "LOAD_FAILED"):
            DebugLog.write("cast: LOAD_FAILED (\(Self.errorDetails(j)))")
            if retrySubtitleAfterError() { return }
            fail("The TV couldn't load this video. The server may not be reachable from the TV at \(URL(string: emby?.server ?? "")?.host ?? "its address").")
        case (CastMessage.nsMedia, "INVALID_REQUEST"):
            DebugLog.write("cast: invalid request (\(j["reason"] as? String ?? "?"))")
        default: break
        }
    }

    func apply(_ st: CastMediaStatus) {
        // An old session's status after a reload: ignore
        if let cur = mediaSessionId, st.mediaSessionId < cur { return }
        mediaSessionId = st.mediaSessionId
        if st.playerState != playerState { DebugLog.write("cast: \(st.playerState)\(st.idleReason.map { " (\($0))" } ?? "") at \(Int(st.currentTime)) s") }
        if let d = st.duration, d > 0 { duration = d }
        if st.playerState == "IDLE" {
            switch st.idleReason {
            case "FINISHED":
                statusTime = duration
                if !playNextAtEnd() { finish(nil) }   // the next episode / film continues on the TV
            case "ERROR": if !retrySubtitleAfterError() { fail("The TV couldn't play this video.") }
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

    func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase != .idle else { return }
                self.tick &+= 1
                n += 1
                self.report(force: false)
                self.updateUpNext()
                if n % 15 == 0, let tid = self.transportId { self.send(CastMessage.nsMedia, ["type": "GET_STATUS"], to: tid) }
            }
        }
    }

    private func report(force: Bool) {
        guard !reconnecting, reportedStart, let ps = playSession, let e = emby else { return }
        let t = time
        guard force || abs(t - lastReport) >= 10 else { return }
        lastReport = t
        let paused = playerState == "PAUSED"
        Task { await e.reportProgress(ps, t, paused: paused) }
        saveActive()
    }

    func reportStop() {
        guard let ps = playSession, let e = emby else { return }
        let t = time, d = duration
        playSession = nil
        if reportedStart { Task { await e.reportStopped(ps, t, duration: d) } } else { Task { await e.stopEncoding(ps) } }
        reportedStart = false
    }

    // MARK: Remote

    func media(_ type: String, _ extra: [String: Any] = [:]) {
        guard !reconnecting, let tid = transportId, let ms = mediaSessionId else { return }
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
    /// Both also update the series / collection memory, as the local player does.
    func setAudio(_ idx: Int) {
        if let item, let k = CastContinue.memoryKey(item, collection: collection),
           let l = CastTracks.audioMemory(idx, streams: streams) { SeriesLang.set(k, "audio", l) }
        subRetryNoSubs = false
        reload { $0.audio = idx }; audio = idx
    }
    func setSub(_ idx: Int?) {
        if let item, let k = CastContinue.memoryKey(item, collection: collection) {
            SeriesLang.set(k, "sub", CastTracks.subMemory(idx, streams: streams))
        }
        sub = idx
        subRetryNoSubs = false
        guard request != nil else { return }
        // Off with a served side track: just hide it on the TV (no reload)
        if idx == nil, request?.sub != nil, request?.subIsImage == false, mediaSessionId != nil {
            request?.sub = nil
            media("EDIT_TRACKS_INFO", ["activeTrackIds": [Int]()])
            DebugLog.write("cast: subtitles off (EDIT_TRACKS_INFO)")
            stopSubtitleServer()
            return
        }
        request?.sub = idx; request?.subIsImage = false
        request?.start = time
        Task {
            await prepareSubtitle()
            guard sub == idx else { return }
            reload { r in r.sub = idx }
        }
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

    func fail(_ message: String) {
        guard phase != .idle else { return }
        DebugLog.write("cast: \(message)")
        error = message
        end(report: true, quitReceiver: false)
    }

    private func finish(_ message: String?) {
        DebugLog.write("cast: playback ended")
        end(report: true, quitReceiver: false)
    }

    func end(report: Bool, quitReceiver: Bool) {
        if report { reportStop() }
        if quitReceiver {
            if mediaSessionId != nil { media("STOP") }
            if let s = receiverSession { send(CastMessage.nsReceiver, ["type": "STOP", "sessionId": s]) }
        }
        clock?.cancel(); clock = nil
        stopSubtitleServer()
        stopReconnect()
        SavedCast.clear()
        let c = channel
        channel = nil
        // Let the STOP messages go out before closing
        if let c { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.close() } }
        transportId = nil; mediaSessionId = nil; receiverSession = nil; loadSent = false
        phase = .idle
        playerState = "IDLE"
        item = nil
        request = nil
        collection = nil; upNext = nil; episodes = []; creditsMarker = nil
    }
}
