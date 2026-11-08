import AVKit
import MediaPlayer
import SwiftUI

// Playback logic shared by both themes: stream selection, subtitles drawn by the app, resume, progress
// reports to the server and the pause keep-alive. Each theme has its own player screen on top of it
// (PlayerView in Views.swift, ClassicPlayerView in ClassicViews.swift).

@MainActor
final class PlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var error = ""
    @Published var caption = ""
    @Published var loadingSubs = false
    private var subGen = 0
    // Current state shown in the player menus
    @Published var streams: [MStream] = []
    @Published var sub: Int? = nil
    @Published var audio: Int? = nil
    @Published var quality = 0
    @Published var speed: Float = {
        let v = UserDefaults.standard.double(forKey: "defaultSpeed")
        return v > 0 ? Float(v) : 1
    }()
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    /// Remembered between videos and launches (mute included).
    @Published var volume: Float = (UserDefaults.standard.object(forKey: "playerVolume") as? NSNumber)?.floatValue ?? 1 {
        didSet { player?.volume = volume; UserDefaults.standard.set(volume, forKey: "playerVolume") }
    }
    @Published var subOffset = 0 { didSet { updateCaption(now) } }   // ms, positive = later
    private var obs: NSKeyValueObservation?
    private var cues: [Cue] = []
    private var timeObs: Any?
    private var req: PlayRequest?
    private var pendingSeek: Double = 0
    private var resumeTarget: Double = 0      // where the item was told to start; checked once it is ready
    private weak var emby: Emby?
    private var lastReport: Double = 0
    private var reportedStart = false
    private var session: Emby.PlaySession?
    /// Bumped by every start() and stop(): a start that was overtaken (another track chosen meanwhile, or the
    /// player closed while it was still loading) sees the change after its next await and gives up.
    private var startGen = 0
    /// False until the stream is ready to play (the screen shows a spinner meanwhile).
    @Published var isReady = false
    /// The player that is playing now, so quitting and sleep can reach it.
    static weak var active: PlayerModel?

    // Chapters, intro/credits markers, scrub thumbnails, picture-in-picture
    @Published var chapters: [Chapter] = []
    @Published var hasThumbs = false
    @Published var inIntro = false            // shown as a "Skip Intro" button when auto-skip is off
    @Published var skippedIntro = false       // brief "Intro skipped" notice
    @Published var pipActive = false
    private var metaFor = ""
    private var introDone = false
    private var bif = Data()
    private var frames: [(t: Double, r: Range<Int>)] = []
    private var thumbCache: [Int: NSImage] = [:]
    private var pip: AVPictureInPictureController?
    private var pipObs: NSKeyValueObservation?

    var introStart: Double? { chapters.first { $0.MarkerType == "IntroStart" }?.start }
    var introEnd: Double? { chapters.first { $0.MarkerType == "IntroEnd" }?.start }
    var creditsStart: Double? { chapters.first { $0.MarkerType == "CreditsStart" }?.start }
    /// Real chapters with their index on the server (needed for chapter images).
    var chapterList: [(i: Int, c: Chapter)] { chapters.enumerated().filter { !$0.element.isMarker }.map { ($0.offset, $0.element) } }
    var isTranscoding: Bool { session?.method == "Transcode" }
    var autoSkipIntro: Bool { UserDefaults.standard.object(forKey: "autoSkipIntro") as? Bool ?? true }

    var audioStreams: [MStream] { streams.filter { $0.`Type` == "Audio" } }
    var subStreams: [MStream] { streams.filter { $0.`Type` == "Subtitle" } }
    var now: Double { player?.currentTime().seconds ?? 0 }

    var watchedEnough: Bool {
        guard let p = player, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 else { return false }
        return p.currentTime().seconds / d > 0.9
    }

    func start(_ emby: Emby, _ req: PlayRequest, direct: Bool = true) async {
        stop()
        startGen += 1
        let gen = startGen
        func current() -> Bool { gen == startGen && !Task.isCancelled }
        error = ""; cues = []; isReady = false
        self.emby = emby
        Self.active = self
        if pendingSeek == 0, let s = req.start, s > 0 { pendingSeek = s }
        self.req = req
        sub = req.sub; quality = req.maxBitrate ?? 0
        let f = (streams.isEmpty || metaFor != req.item.id) ? await emby.full(req.item.id) : nil
        guard current() else { return }
        if let f {
            let src = f.MediaSources?.first { $0.Id == req.sourceId } ?? f.MediaSources?.first
            if streams.isEmpty { streams = src?.MediaStreams ?? [] }
            if metaFor != req.item.id {
                metaFor = req.item.id
                chapters = f.Chapters ?? []
                introDone = false; inIntro = false
                loadThumbs(emby, req.item.id, src?.Id)
            }
        }
        let auds = streams.filter { $0.`Type` == "Audio" }
        audio = req.audio ?? (auds.first { $0.IsDefault == true } ?? auds.first)?.Index
        var req = req
        // Audio / subtitles remembered for this series
        if req.item.isEpisode, let sid = req.item.SeriesId, let m = SeriesLang.get(sid) {
            // (with "Always load preferred subtitle language" on, that setting wins over what was remembered for the series)
            if req.sub == nil, !req.noSub, !UserDefaults.standard.bool(forKey: "subAlways"), let l = m["sub"] {
                if l == "off" { req.noSub = true; self.req?.noSub = true }
                else if let i = preferredSub(streams, lang: l) { req.sub = i; sub = i; self.req?.sub = i }
            }
            if req.audio == nil, let l = m["audio"],
               let st = auds.first(where: { ($0.Language ?? "").lowercased() == l.lowercased() }), st.Index != audio {
                req.audio = st.Index; audio = st.Index; self.req?.audio = st.Index
            }
        }
        // "Always load preferred subtitle language"
        let d = UserDefaults.standard
        if req.sub == nil, !req.noSub, d.bool(forKey: "subAlways"), let lang = d.string(forKey: "subLang"), !lang.isEmpty,
           let idx = preferredSub(streams, lang: lang) {
            req.sub = idx; sub = idx; self.req?.sub = idx
        }
        // Text subtitles are drawn by the app and load in the background, so the video starts right away
        // (embedded ones can take a while the first time). Image subtitles are burned in by the server.
        if let s = req.sub, !isImageSub(s), !req.burnIn {
            req.sub = nil
            loadCues(emby, req.item.id, req.sourceId, s)
        }
        await emby.killStaleEncodings()
        guard current() else { return }
        // A stream that starts part-way through the file must not copy the video (see Emby.withoutVideoCopy)
        let midFile = pendingSeek > 0
        let resolved = await emby.resolveStream(req, direct: direct, reencode: midFile)
        guard let u = resolved else {
            if current() { error = "Couldn't get a stream from the server." }
            return
        }
        let method = u.absoluteString.contains("Static=true") ? "DirectPlay" : "Transcode"
        let ps = Emby.PlaySession(itemId: req.item.id, sourceId: req.sourceId, method: method, url: u)
        guard current() else {
            // Overtaken while the server prepared this stream: make sure its conversion doesn't keep running
            if method == "Transcode" { Task { await emby.stopEncoding(ps) } }
            return
        }
        session = ps
        let it = AVPlayerItem(url: u)
        // Start at the resume point right away. Loading from 0 and seeking afterwards makes the server restart
        // its transcode part-way, which can shift the stream's timeline against the subtitles.
        if pendingSeek > 0 {
            resumeTarget = pendingSeek
            time = pendingSeek
            it.seek(to: CMTime(seconds: pendingSeek, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            pendingSeek = 0
        }
        obs = it.observe(\.status, options: [.new]) { [weak self] i, _ in
            if i.status == .failed {
                let m = i.error?.localizedDescription ?? "Playback failed."
                Task { @MainActor in self?.error = m }
            }
            if i.status == .readyToPlay {
                Task { @MainActor in
                    guard let self else { return }
                    self.isReady = true
                    if self.resumeTarget > 0 {
                        let t = self.resumeTarget; self.resumeTarget = 0
                        // Safety net in case the early seek was not applied: exact seek now
                        if abs(self.now - t) > 2 {
                            await self.player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                                    toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        self.updateCaption(self.now)
                        self.dlog("resume to \(self.fmt(t)): player at \(self.fmt(self.now)) (\(self.session?.method ?? "?")), re-encode requested")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(5))
                            self?.logServer()
                        }
                    }
                    if !self.reportedStart, let ps = self.session {
                        self.reportedStart = true
                        await self.emby?.reportStart(ps, self.now)
                    }
                }
            }
        }
        let p = AVPlayer(playerItem: it)
        p.volume = volume
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        player = p
        p.defaultRate = speed
        p.play()
        // A conversion that never starts would otherwise leave a black screen with a spinner forever
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, gen == self.startGen, !self.isReady, self.error.isEmpty else { return }
            self.error = "The server didn't start the video. Try again, or choose a lower quality."
        }
    }

    /// Cove is quitting: report where playback stopped and end the server's conversion before the app goes
    /// away (AppDelegate waits for this, a few seconds at most).
    func stopForQuit() async {
        guard let p = player, let ps = session, let e = emby else { stop(); return }
        let t = p.currentTime().seconds, d = p.currentItem?.duration.seconds ?? 0
        let started = reportedStart
        session = nil                               // stop() must not report a second time
        stop()
        if started { await e.reportStopped(ps, t.isFinite ? t : 0, duration: d.isFinite ? d : 0, quick: true) }
        else { await e.stopEncoding(ps) }
    }

    /// The Mac is going to sleep: pause (which reports the position and keeps the session alive).
    func pauseForSleep() {
        if let p = player, p.rate > 0 { togglePlay() }
    }

    /// Restart the stream with new settings, keeping the playback position.
    private func restart(_ emby: Emby, _ change: (inout PlayRequest) -> Void) async {
        guard var r = req else { return }
        change(&r)
        // While an earlier restart is still loading there is no player yet (`now` reads 0): keep its position
        pendingSeek = player != nil ? now : max(pendingSeek, time)
        await start(emby, r)
    }

    func isImageSub(_ idx: Int) -> Bool {
        imageSubCodecs.contains((streams.first { $0.Index == idx }?.Codec ?? "").lowercased())
    }

    /// Downloads a text subtitle in the background; playback keeps going meanwhile.
    private func loadCues(_ emby: Emby, _ itemId: String, _ sourceId: String?, _ idx: Int) {
        subGen += 1
        let gen = subGen
        cues = []; caption = ""; loadingSubs = true
        Task {
            let c = await emby.subtitleCues(itemId, sourceId, idx)
            guard gen == subGen else { return }   // user picked another track meanwhile
            loadingSubs = false
            if let c { cues = c; updateCaption(now) }
            else { await restart(emby) { $0.sub = idx; $0.burnIn = true } }   // couldn't read as text: burn it in
        }
    }

    func setSub(_ emby: Emby, _ idx: Int?) async {
        guard idx != sub, let r = req else { return }
        if r.item.isEpisode, let sid = r.item.SeriesId {
            SeriesLang.set(sid, "sub", idx.flatMap { i in streams.first { $0.Index == i } }.map(subLangName) ?? "off")
        }
        // Burned in by the server: an image subtitle, or a text one that couldn't be read (burnIn). Either way
        // only a new stream can change or remove it, and the next track must not be burned in again.
        let wasBurned = (sub.map(isImageSub) ?? false) || (req?.burnIn ?? false)
        if let idx {
            if isImageSub(idx) {
                await restart(emby) { $0.sub = idx; $0.burnIn = false }
            } else {
                sub = idx; req?.sub = idx
                if wasBurned { await restart(emby) { $0.sub = idx; $0.burnIn = false } }
                else { loadCues(emby, r.item.id, r.sourceId, idx) }
            }
        } else {
            subGen += 1
            cues = []; caption = ""; loadingSubs = false; sub = nil; req?.sub = nil; req?.noSub = true
            if wasBurned { await restart(emby) { $0.sub = nil; $0.noSub = true; $0.burnIn = false } }
        }
    }

    func setAudio(_ emby: Emby, _ idx: Int) async {
        guard idx != audio else { return }
        if let r = req, r.item.isEpisode, let sid = r.item.SeriesId,
           let l = streams.first(where: { $0.Index == idx })?.Language, !l.isEmpty {
            SeriesLang.set(sid, "audio", l)
        }
        await restart(emby) { $0.audio = idx }
    }

    func setQuality(_ emby: Emby, _ q: Int) async {
        guard q != quality else { return }
        await restart(emby) { $0.maxBitrate = q > 0 ? q : nil }
    }

    func setSpeed(_ r: Float) {
        speed = r
        player?.defaultRate = r
        if player?.rate ?? 0 > 0 { player?.rate = r }
    }

    private func tick(_ t: Double) {
        if t.isFinite { time = t }
        if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        let isPlaying = (player?.rate ?? 0) > 0
        if isPlaying != playing {
            playing = isPlaying
            sendProgress(t, force: true)
        }
        sendProgress(t)
        updateCaption(t)
        checkIntro(t)
    }

    private func checkIntro(_ t: Double) {
        guard let s = introStart, let e = introEnd, e > s + 2, t.isFinite else { return }
        let inside = t >= s && t < e - 1
        if inside, !introDone, autoSkipIntro {
            introDone = true
            seek(to: e)
            skippedIntro = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.skippedIntro = false
            }
            return
        }
        if inside != inIntro { inIntro = inside && !autoSkipIntro }
    }

    func skipIntro() { if let e = introEnd { introDone = true; inIntro = false; seek(to: e) } }
    func watchIntro() { if let s = introStart { skippedIntro = false; seek(to: s) } }

    // MARK: Scrub thumbnails (BIF)

    private func loadThumbs(_ emby: Emby, _ id: String, _ sourceId: String?) {
        bif = Data(); frames = []; thumbCache = [:]; hasThumbs = false
        Task { @MainActor in
            guard let d = await emby.bifData(id, sourceId), self.metaFor == id else { return }
            let f = Self.parseBIF(d)
            self.bif = d; self.frames = f; self.hasThumbs = !f.isEmpty
        }
    }

    /// BIF: 64-byte header (magic, version, count @12, ms per frame @16), then (frame, offset) pairs.
    static func parseBIF(_ d: Data) -> [(t: Double, r: Range<Int>)] {
        let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46]
        guard d.count > 72, Array(d.prefix(4)) == magic else { return [] }
        func u32(_ o: Int) -> Int {
            guard o + 4 <= d.count else { return 0 }
            return d.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
        }
        let count = u32(12)
        let sep = Double(u32(16) == 0 ? 1000 : u32(16)) / 1000
        var out: [(t: Double, r: Range<Int>)] = []
        guard count > 0, 64 + 8 * (count + 1) <= d.count else { return [] }
        for i in 0..<count {
            let ts = u32(64 + 8 * i), a = u32(64 + 8 * i + 4), b = u32(64 + 8 * (i + 1) + 4)
            if ts == 0xFFFF_FFFF { break }
            if a < b, b <= d.count { out.append((Double(ts) * sep, a..<b)) }
        }
        return out
    }

    func thumb(at t: Double) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1, f = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if frames[m].t <= t { f = m; lo = m + 1 } else { hi = m - 1 }
        }
        if let img = thumbCache[f] { return img }
        let img = NSImage(data: bif.subdata(in: frames[f].r))
        if thumbCache.count > 200 { thumbCache.removeAll() }
        thumbCache[f] = img
        return img
    }

    // MARK: Picture in picture

    var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard pipSupported, pip?.playerLayer !== layer else { return }
        pip = AVPictureInPictureController(playerLayer: layer)
        pipObs = pip?.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] c, _ in
            let on = c.isPictureInPictureActive
            Task { @MainActor in self?.pipActive = on }
        }
    }

    func togglePiP() {
        guard let p = pip else { return }
        if p.isPictureInPictureActive { p.stopPictureInPicture() } else { p.startPictureInPicture() }
    }

    // MARK: Playback info

    func playbackInfo() async -> [(String, String)] {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func mbps(_ b: Double) -> String { b >= 1_000_000 ? String(format: "%.1f Mbps", b / 1_000_000) : "\(Int(b / 1000)) kbps" }
        var out: [(String, String)] = []
        out.append(("Play method", isTranscoding ? "Transcode" : "Direct play"))
        if let v = streams.first(where: { $0.`Type` == "Video" }) {
            var s = (v.Codec ?? "?").uppercased()
            if let w = v.Width, let h = v.Height { s += " · \(w)×\(h)" }
            if let b = v.BitRate { s += " · " + mbps(Double(b)) }
            out.append(("Source video", s))
        }
        if let a = streams.first(where: { $0.Index == audio }) { out.append(("Source audio", a.DisplayTitle ?? a.Codec ?? "?")) }
        if isTranscoding, let t = await emby?.sessionInfo()?["TranscodingInfo"] as? [String: Any] {
            var v = (t["IsVideoDirect"] as? Bool == true) ? "copied" : ((t["VideoCodec"] as? String ?? "?").uppercased())
            if let w = num(t["Width"]), let h = num(t["Height"]) { v += " · \(Int(w))×\(Int(h))" }
            out.append(("Server video", v))
            out.append(("Server audio", (t["IsAudioDirect"] as? Bool == true) ? "copied" : ((t["AudioCodec"] as? String ?? "?").uppercased())))
            if let b = num(t["Bitrate"]) { out.append(("Stream bitrate", mbps(b))) }
            if let f = num(t["Framerate"]) { out.append(("Encoder speed", String(format: "%.0f fps", f))) }
            if let r = t["TranscodeReasons"] as? [String], !r.isEmpty {
                out.append(("Why transcoding", r.map { $0.replacingOccurrences(of: "NotSupported", with: " not supported") }.joined(separator: ", ")))
            }
        }
        if let it = player?.currentItem {
            let sz = it.presentationSize
            if sz.width > 0 { out.append(("Playing", "\(Int(sz.width))×\(Int(sz.height))")) }
            if let e = it.accessLog()?.events.last {
                if e.indicatedBitrate > 0 { out.append(("Indicated", mbps(e.indicatedBitrate))) }
                if e.observedBitrate > 0 { out.append(("Network", mbps(e.observedBitrate))) }
                out.append(("Dropped / stalls", "\(max(0, e.numberOfDroppedVideoFrames)) / \(max(0, e.numberOfStalls))"))
            }
        }
        return out
    }

    /// Tells the server the current position every 10 s (and on pause/play), so it can resume later.
    private func sendProgress(_ t: Double, force: Bool = false) {
        guard reportedStart, let ps = session, t.isFinite, force || abs(t - lastReport) >= 10 else { return }
        lastReport = t
        let paused = !playing
        Task { await emby?.reportProgress(ps, t, paused: paused) }
    }

    private var pausedAt: Date?
    private var debugTimer: Timer?

    func togglePlay() {
        guard let p = player else { return }
        if p.rate > 0 {
            p.pause(); pausedAt = Date()
            dlog("pause at \(fmt(now))")
            pausedKeepAlive(true)
            startDebugPolling()
        } else {
            let away = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
            pausedAt = nil
            pausedKeepAlive(false)
            debugTimer?.invalidate(); debugTimer = nil
            dlog("resume at \(fmt(now)) after \(Int(away))s pause")
            // No re-seek here: the pause keep-alive stops the server from restarting its transcode, and a
            // zero-tolerance seek on resume could hang the stream.
            p.play()
            logServer()
        }
        playing = p.rate > 0
    }

    /// While paused the player stops asking for video, and after ~60 s of silence the server ends the
    /// session and kills the transcode. Resuming then starts a new transcode whose timeline is slightly
    /// offset, so subtitles drift. Report the pause at once and keep pinging until playback resumes.
    private var keepAlive: Timer?
    private func pausedKeepAlive(_ on: Bool) {
        keepAlive?.invalidate(); keepAlive = nil
        guard let ps = session, reportedStart else { return }
        let t = now, e = emby
        lastReport = t
        Task { await e?.reportProgress(ps, t, paused: on) }
        guard on else { return }
        keepAlive = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Same session and a live player only: after stop() `now` reads 0, which would overwrite the
                // resume point. The position is read before the awaits.
                guard let self, let cur = self.session, cur.id == ps.id, self.player != nil, let e = self.emby else { return }
                let t = self.now
                await e.ping(cur)
                guard self.session?.id == ps.id else { return }
                await e.reportProgress(cur, t, paused: true)
            }
        }
    }

    // MARK: debug log (~/Library/Logs/Cove.log)
    private func fmt(_ t: Double) -> String { String(format: "%.2fs", t) }
    private func startDebugPolling() {
        guard DebugLog.enabled else { return }
        logServer()
        debugTimer?.invalidate()
        debugTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logServer() }
        }
    }
    private func logServer() {
        guard DebugLog.enabled, let e = emby else { return }
        let t = now, ev = player?.currentItem?.accessLog()?.events.last
        Task { @MainActor in
            let s = await e.mySessionJSON()
            self.dlog("player \(self.fmt(t)) segs=\(ev?.numberOfMediaRequests ?? 0) stalls=\(ev?.numberOfStalls ?? 0) | server \(s)")
        }
    }
    func dlog(_ m: String) { DebugLog.write(m) }

    func seek(to t: Double) {
        let c = max(0, duration > 0 ? min(t, duration - 1) : t)
        time = c
        player?.seek(to: CMTime(seconds: c, preferredTimescale: 600))
        updateCaption(c)
    }

    func skip(_ d: Double) { seek(to: now + d) }

    private func updateCaption(_ raw: Double) {
        let t = raw - Double(subOffset) / 1000
        // binary search for the last cue starting at or before t
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        // Cues can overlap (two speakers, a sign plus dialogue): show every cue that covers t, in order
        var lines: [String] = []
        var i = found
        while i >= 0 && found - i < 8 {
            if t <= cues[i].end { lines.insert(cues[i].text, at: 0) }
            i -= 1
        }
        let text = lines.joined(separator: "\n")
        if text != caption { caption = text }
    }

    func stop() {
        startGen += 1
        subGen += 1; loadingSubs = false          // a subtitle still downloading must not restart playback later
        if Self.active === self { Self.active = nil }
        if let p = player, let ps = session, reportedStart {
            let t = p.currentTime().seconds
            let d = p.currentItem?.duration.seconds ?? 0
            let e = emby
            Task { await e?.reportStopped(ps, t.isFinite ? t : 0, duration: d.isFinite ? d : 0) }
        } else if let ps = session, let e = emby {
            Task { await e.stopEncoding(ps) }   // closed before playback began: still kill the transcode
        }
        session = nil
        reportedStart = false; lastReport = 0
        if let o = timeObs { player?.removeTimeObserver(o) }
        timeObs = nil
        debugTimer?.invalidate(); debugTimer = nil; pausedAt = nil
        keepAlive?.invalidate(); keepAlive = nil
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        player?.pause(); player = nil; obs = nil; caption = ""; resumeTarget = 0
    }
}
