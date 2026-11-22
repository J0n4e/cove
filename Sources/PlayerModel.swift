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
    @Published var subOffset = 0 {   // ms, positive = later
        didSet {
            updateCaption(now)
            // AirPlay's local WebVTT rendition (same cue shifting as Cast)
            if airPlayLocalSub != nil, oldValue != subOffset { CastSubtitleServer.shared.updateHLSOffset(subOffset) }
        }
    }
    private var obs: NSKeyValueObservation?
    private var cues: [Cue] = []
    /// The film's seconds the downloaded cues cover (infinity: the whole track)
    private var cuesUpTo: Double = 0
    private var subTask: Task<Void, Never>?
    /// The track is still downloading: "Loading subtitles…" shows wherever its cues haven't come yet
    private var subFetching = false
    private var timeObs: Any?
    private var req: PlayRequest?
    private var pendingSeek: Double = 0
    private var resumeTarget: Double = 0      // where the item was told to start; checked once it is ready
    // SyncPlay timing (SyncPlay/SyncPlayTiming.swift) ↓
    var syncGroupMode = false
    var syncPrerolled = false
    var syncSeeks = 0
    var syncSeekGen = 0
    // ↑ SyncPlay timing
    private weak var emby: Emby?
    private var lastReport: Double = 0
    private var reportedStart = false
    private var session: Emby.PlaySession?
    /// Bumped by every start() and stop(): a start that was overtaken (another track chosen meanwhile, or the
    /// player closed while it was still loading) sees the change after its next await and gives up.
    var startGen = 0
    /// After a playback failure on this item: have the server convert the video (TS + H.264, no copy).
    private var forceTranscode = false
    /// The running stream copies the video and started mid-file (its picture can be a GOP off the clock).
    private(set) var streamCopiedMidFile = false
    private var failObs: NSObjectProtocol?
    private var retrying = false
    // Embedded text subtitles read from the HLS stream (Player/LegibleSubtitles.swift) ↓
    var legible: LegibleSubtitles?
    var legibleGroup: AVMediaSelectionGroup?
    /// The track shown from the stream (nil: cues, or none)
    var inStreamSub: Int?
    var inStreamDecided = false
    var inStreamFirst = false
    var inStreamT0 = Date()
    /// This film's stream brought no subtitle rendition once: later tracks are downloaded instead
    var inStreamUnsupported = false
    var embyRef: Emby? { emby }
    var currentRequest: PlayRequest? { req }
    // ↑ in-stream subtitles
    // AirPlay video (Player/AirPlay.swift) ↓
    @Published var airPlayActive = false
    @Published var airPlayDevice = "AirPlay device"
    var airPlayObs: NSKeyValueObservation?
    /// The subtitle is burned in only because of AirPlay (Cove draws it again when AirPlay ends)
    var airPlayBurned = false
    var airPlayBurnPending = false
    /// Cove is restarting the stream for an AirPlay subtitle change: keep the AVPlayer (the route) and don't take
    /// a brief isExternalPlaybackActive=false as "AirPlay ended" (Player/AirPlay.swift)
    var airPlayRestartInProgress = false
    var airPlayRestartToken = 0
    var airPlayOffSince: Date?
    /// Text track served on AirPlay through Cove's local HLS (Player/AirPlayLocalHLSPlayer.swift)
    var airPlayLocalSub: Int?
    var airPlayLocalName = ""
    var airPlayLocalAt = Date.distantPast
    // ↑ AirPlay
    /// The file's video is HEVC (typically 4K / HDR): ask for fMP4 segments so it can be passed through.
    var sourceIsHEVC: Bool {
        let c = (streams.first { $0.`Type` == "Video" }?.Codec ?? "").lowercased()
        return c == "hevc" || c == "h265"
    }
    /// The file's video is HDR (HDR10, HLG, Dolby Vision).
    var sourceIsHDR: Bool {
        let r = (streams.first { $0.`Type` == "Video" }?.VideoRange ?? "").lowercased()
        return r.contains("hdr") || r.contains("dolby") || r.contains("hlg") || r.contains("pq")
    }
    /// The screen can show HDR. AVPlayer refuses an HDR stream on an SDR screen (AVFoundation -11868),
    /// so on such a screen an HDR video is converted by the server instead of passed through.
    static var screenIsHDR: Bool {
        (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }
    /// The screen's width in pixels: a converted video doesn't need to be wider.
    static var screenWidth: Int? {
        guard let s = NSScreen.main else { return nil }
        return Int(s.frame.width * s.backingScaleFactor)
    }
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
    /// Served through the server's HLS pipeline (Direct Stream or Transcode): the server runs a job for it.
    var isTranscoding: Bool { session?.hls == true }
    var autoSkipIntro: Bool { UserDefaults.standard.object(forKey: "autoSkipIntro") as? Bool ?? true }

    var audioStreams: [MStream] { streams.filter { $0.`Type` == "Audio" } }
    var subStreams: [MStream] { streams.filter { $0.`Type` == "Subtitle" } }
    var now: Double { player?.currentTime().seconds ?? 0 }

    /// `seek`: the position a restart keeps (nil: a new start, which uses the request's resume point).
    func start(_ emby: Emby, _ req: PlayRequest, direct: Bool = true, seek: Double? = nil) async {
        stop()
        pendingSeek = Self.effectiveStart(keep: seek, requestStart: req.start)
        startGen += 1
        let gen = startGen
        func current() -> Bool { gen == startGen && !Task.isCancelled }
        error = ""; cues = []; cuesUpTo = 0; isReady = false
        // The next episode takes over an AirPlaying player: decide its subtitle for the TV from the start
        if !airPlayActive, Self.airPlayHandoffFresh { airPlayActive = true }
        airPlayBurned = airPlayBurnPending && req.burnIn; airPlayBurnPending = false
        self.emby = emby
        Self.active = self
        self.req = req
        sub = req.sub; quality = req.maxBitrate ?? 0
        let f = (streams.isEmpty || metaFor != req.item.id) ? await emby.full(req.item.id) : nil
        guard current() else { return }
        if let f {
            let src = f.MediaSources?.first { $0.Id == req.sourceId } ?? f.MediaSources?.first
            if streams.isEmpty { streams = src?.MediaStreams ?? [] }
            if metaFor != req.item.id {
                metaFor = req.item.id
                forceTranscode = false
                // A server that left the subtitle out of its stream once (Emby) won't have it next time either:
                // go straight to the download path, so a resume re-encodes and the cues stay in sync (owner)
                inStreamUnsupported = Self.hlsSubsMissing.contains(emby.server)
                chapters = f.Chapters ?? []
                introDone = false; inIntro = false
                loadThumbs(emby, req.item.id, src?.Id)
            }
        }
        let auds = streams.filter { $0.`Type` == "Audio" }
        audio = req.audio ?? (auds.first { $0.IsDefault == true } ?? auds.first)?.Index
        var req = req
        // Audio / subtitles remembered for this series (or this collection, in collection mode)
        if let sid = SeriesLang.key(req), let m = SeriesLang.get(sid) {
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
        // Embedded text tracks come inside the HLS stream when the server can (shown at once); external files and
        // the fallback are downloaded.
        var wantInStream: Int?
        var coveDrawn = false
        // AirPlay + text subtitle: the server streams without it, Cove adds it as a WebVTT rendition (local HLS)
        let localSub = airPlayLocalChoice(req)
        if let s = localSub { dlog("airplay: subtitle track \(s) via Cove's local HLS (WebVTT rendition)"); req.sub = nil }
        if localSub == nil, let s = req.sub, !isImageSub(s), !req.burnIn, airPlayActive,
           Self.airPlaySubAction(path: Self.subPath(streams.first { $0.Index == s }, burnIn: false, directPlay: false),
                                 airPlay: true, playingInStream: false, burnedForAirPlay: false, hls: true,
                                 inStreamUnsupported: Self.airPlayNoHlsSubs(isJellyfin: emby.isJellyfin, known: inStreamUnsupported),
                                 textCodec: Self.isTextCodec(streams.first { $0.Index == s })) == .burnIn {
            dlog("airplay: subtitle track \(s) burned in by the server (not in the HLS stream here)")
            req.burnIn = true; self.req?.burnIn = true; airPlayBurned = true
        }
        if let s = req.sub, !isImageSub(s), !req.burnIn {
            req.sub = nil
            if !inStreamUnsupported,
               airPlayActive || Self.subPath(streams.first { $0.Index == s }, burnIn: false, directPlay: false) == .inStream {
                if airPlayActive { dlog("airplay: subtitle track \(s) inside the HLS stream, rendered by AVPlayer") }
                req.hlsSub = s; wantInStream = s
            } else {
                dlog("subs: extraction (track \(s))")
                coveDrawn = true
                loadCues(emby, req.item.id, req.sourceId, s, from: pendingSeek)
            }
        }
        await emby.killStaleEncodings()
        guard current() else { return }
        // Resume keeps the video copied (Direct stream). The URL has no StartTimeTicks: the HLS playlist covers the
        // whole file and the player seeks in it, so the player's clock is the media time (see ResumeStrategy).
        let midFile = pendingSeek > 0
        let resumeReencode = ResumeStrategy.reencode(resuming: midFile, forceTranscode: forceTranscode,
                                                     coveDrawnSub: coveDrawn)
        streamCopiedMidFile = midFile && !resumeReencode
        if midFile {
            dlog("resume: \(ResumeStrategy.logLine(reencode: resumeReencode, forceTranscode: forceTranscode, coveDrawnSub: coveDrawn)), seek in whole-file playlist to \(fmt(pendingSeek)), start offset 0 s (strategy: \(ResumeStrategy.name))")
        }
        // A 4K HEVC video passes through unchanged when the screen can show it (HDR needs an HDR screen)
        let passHEVC = sourceIsHEVC && !forceTranscode && (!sourceIsHDR || Self.screenIsHDR)
        if sourceIsHEVC { dlog("HEVC source (\(sourceIsHDR ? "HDR" : "SDR"), screen \(Self.screenIsHDR ? "HDR" : "SDR")): \(passHEVC ? "fMP4 pass-through" : "converted")") }
        // The server must convert the video when HEVC can't pass through (HDR on an SDR screen) or after a
        // failure; the retry also goes back to stereo AAC, the proven audio (risk control for the audio copy).
        let mustConvert = forceTranscode || (sourceIsHEVC && !passHEVC)
        if forceTranscode { dlog("stream: retry after a playback error, forcing a conversion (video + stereo AAC)") }
        let resolved = await emby.resolveStream(req, direct: direct && !forceTranscode, reencode: resumeReencode,
                                                hevc: passHEVC, maxWidth: Self.screenWidth,
                                                convert: mustConvert, safeAudio: forceTranscode)
        guard let u = resolved else {
            // (a 401 or a server error from PlaybackInfo is shown as is: converting wouldn't help)
            if current(), Self.failureAction(.streamRequest, alreadyConverted: forceTranscode) == .showError {
                error = emby.lastStreamError ?? "Couldn't get a stream from the server."
            }
            return
        }
        // First guess from the URL; corrected from the server's TranscodingInfo once the stream runs
        let srcAudio = (audioStreams.first { $0.Index == req.audio } ?? audioStreams.first { $0.IsDefault == true }
                        ?? audioStreams.first)?.Codec
        let method = PlayMethod.guess(url: u.absoluteString, sourceAudio: srcAudio)
        streamContainer = emby.lastStreamContainer
        var playURL = u
        if let s = localSub {
            if method != "DirectPlay", let lu = await airPlayLocalURL(emby, server: u, track: s, req: req, gen: gen) {
                playURL = lu
            } else if current() {
                dlog("airplay: local HLS not possible\(method == "DirectPlay" ? " (Direct Play)" : ""): restarting with track \(s) burned in")
                if let lsub = self.req?.item.id, method != "DirectPlay" { Self.airPlayLocalFailedItems.insert(lsub) }
                airPlayBurnPending = true
                Task { @MainActor [weak self] in await self?.restartKeepingPosition { $0.sub = s; $0.burnIn = true } }
            }
        }
        let ps = Emby.PlaySession(itemId: req.item.id, sourceId: req.sourceId, method: method, url: u,
                                  server: emby.server, token: emby.token)
        guard current() else {
            // Overtaken while the server prepared this stream: make sure its conversion doesn't keep running
            if ps.hls { Task { await emby.stopEncoding(ps) } }
            return
        }
        session = ps
        let it = AVPlayerItem(url: playURL)
        if let s = wantInStream {
            if method == "DirectPlay", airPlayActive {   // the TV can't get Cove's cues: burn it in
                dlog("airplay: Direct Play has no subtitle stream: restarting with track \(s) burned in")
                airPlayBurnPending = true
                Task { @MainActor [weak self] in await self?.restartKeepingPosition { $0.sub = s; $0.burnIn = true } }
            } else if method == "DirectPlay" {   // no HLS, so no renditions: download the track (the file itself: exact)
                dlog("subs: extraction (track \(s), Direct Play)")
                loadCues(emby, req.item.id, req.sourceId, s, from: pendingSeek)
            } else {
                attachInStream(it, s, gen: gen)
            }
        }
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
                let code = (i.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "unknown error"
                Task { @MainActor in self?.playbackFailed(code, gen: gen) }
            }
            if i.status == .readyToPlay {
                Task { @MainActor in
                    // A stale event from a stream that was restarted meanwhile must not mark the new one ready
                    guard let self, gen == self.startGen, self.player?.currentItem === i else { return }
                    self.isReady = true
                    self.selectInStream(i, gen: gen); self.selectAirPlayLocal(i, gen: gen)
                    if self.resumeTarget <= 0 { self.syncPreroll() }   // SyncPlay timing
                    if self.resumeTarget > 0 {
                        let t = self.resumeTarget; self.resumeTarget = 0
                        // Safety net in case the early seek was not applied: exact seek now
                        if abs(self.now - t) > 2 {
                            await self.player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                                    toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        self.updateCaption(self.now)
                        self.syncPreroll()   // SyncPlay timing
                        self.dlog("resume to \(self.fmt(t)): player at \(self.fmt(self.now)) (\(self.session?.method ?? "?")), start offset \(String(format: "%.2f", ResumeStrategy.offset(requested: t, playerAt: self.now))) s")
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(5))
                            self?.logServer()
                        }
                    }
                    guard gen == self.startGen else { return }
                    if !self.reportedStart, let ps = self.session {
                        self.reportedStart = true
                        await self.emby?.reportStart(ps, self.now)
                        self.confirmMethod(gen: gen)
                    }
                }
            }
        }
        // A stream can also fail part-way (a segment AVPlayer can't decode)
        failObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: it,
                                                         queue: .main) { [weak self] n in
            let code = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
                .map { "\($0.domain) \($0.code)" } ?? "unknown error"
            MainActor.assumeIsolated { self?.playbackFailed(code, gen: gen) }
        }
        // An AirPlaying player is reused (the route belongs to it): the next episode stays on the TV
        let handed = Self.takeAirPlayHandoff()
        if handed != nil { dlog("airplay: reusing the AirPlay player for this item") }
        let p = handed ?? AVPlayer()
        p.replaceCurrentItem(with: it)
        observeAirPlay(p, gen: gen)
        p.volume = volume
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, gen == self.startGen else { return }
                self.tick(t.seconds)
            }
        }
        player = p
        p.defaultRate = speed
        syncPrerolled = false; syncSeeks = 0
        syncGroupMode = emby.syncPlay.group.isInGroup   // SyncPlay timing: exact starts while in a group
        if syncGroupMode { p.automaticallyWaitsToMinimizeStalling = false }
        if !req.startPaused, !AirPlayDetailStart.shared.holdsStart { p.play() }   // detail AirPlay: paused until a route   // a SyncPlay group starts it once everyone is ready
        // A conversion that never starts would otherwise leave a black screen with a spinner forever
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, gen == self.startGen, !self.isReady, self.error.isEmpty else { return }
            self.error = "The server didn't start the video. Try again, or choose a lower quality."
        }
    }

    /// The source container, for the Playback info overlay ("mkv → hls").
    private var streamContainer: String?

    /// A few seconds after the start, read the server's TranscodingInfo for this session and report the real
    /// method (Direct Stream when video and audio are both copied). Logged once per start.
    private func confirmMethod(gen: Int) {
        guard let ps = session else { return }
        guard ps.hls else { dlog("play method: DirectPlay (static file)"); return }
        Task { @MainActor [weak self] in
            var info: [String: Any]?
            for _ in 0..<3 {   // the server may need a moment to start its job
                try? await Task.sleep(for: .seconds(4))
                guard let self, gen == self.startGen else { return }
                info = await self.emby?.sessionInfo()?["TranscodingInfo"] as? [String: Any]
                if info?["IsVideoDirect"] != nil { break }
            }
            guard let self, gen == self.startGen, var cur = self.session else { return }
            let m = PlayMethod.classify(url: ps.url.absoluteString, transcodingInfo: info)
            let reasons = PlayMethod.reasons(info)
            self.dlog("play method: \(m) (first guess \(ps.method))"
                      + (info == nil ? ", server gave no TranscodingInfo" : "")
                      + "; video \((info?["IsVideoDirect"] as? Bool) == true ? "copied" : (info?["VideoCodec"] as? String ?? "?"))"
                      + ", audio \((info?["IsAudioDirect"] as? Bool) == true ? "copied" : (info?["AudioCodec"] as? String ?? "?"))"
                      + "; reasons: \(reasons.isEmpty ? "none" : reasons.joined(separator: ","))")
            if self.req?.sub != nil, self.airPlayLocalSub == nil, (info?["IsVideoDirect"] as? Bool) == true { self.dlog("WARNING: burn-in requested but the server copies the video: the subtitle won't show") }
            guard m != cur.method else { return }
            cur.method = m
            self.session = cur
            if self.reportedStart { await self.emby?.reportProgress(cur, self.now, paused: !self.playing) }
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

    /// AVPlayer couldn't play the stream (CoreMedia -12927 and similar: a format macOS can't decode or doesn't
    /// accept in that container). The first time, have the server convert the video and carry on from the same
    /// position with the same audio and subtitles; only if that fails too is the error shown.
    private func playbackFailed(_ code: String, gen: Int) {
        // Both the item status and the "failed to play to end" notice can report the same failure: act once
        guard gen == startGen, player != nil, let emby, error.isEmpty, !retrying else { return }
        if airPlayLocalFailed(gen: gen) { return }   // local AirPlay HLS: server burn-in once instead
        var info = code
        if let ev = player?.currentItem?.errorLog()?.events.last {   // (its URI holds the token: not logged)
            info += "; log: \(ev.errorDomain) \(ev.errorStatusCode) \(ev.errorComment ?? "")"
        }
        let how = "\(session?.method ?? "?")\(sourceIsHEVC && !forceTranscode && (!sourceIsHDR || Self.screenIsHDR) ? ", HEVC fMP4" : "")"
        dlog("playback failed (\(how)): \(info)")
        coveLog.error("Playback failed (\(how, privacy: .public)): \(info, privacy: .public)")
        if Self.failureAction(.player, alreadyConverted: forceTranscode) == .retryConverted {
            dlog("retrying with the video converted by the server")
            forceTranscode = true          // at most one automatic retry per item
            retrying = true
            Task {
                // Stopped or switched to another film meanwhile: don't start anything
                if gen == startGen { await retryTranscoded(emby) }
                retrying = false
            }
            return
        }
        error = "Cove couldn't play this video, even converted by the server.\n(\(code))"
            + (sourceIsHDR ? "\nFor HDR videos, turn on tone mapping in the server's transcoding settings." : "")
    }

    /// What went wrong: AVPlayer couldn't play the stream (item failed, or failed part-way), or the server
    /// didn't give a stream at all (PlaybackInfo 401 / server error / no URL).
    enum FailureKind: Equatable { case player, streamRequest }
    enum FailureAction: Equatable { case retryConverted, showError }

    /// A player failure on a stream not yet converted by the server is retried once, converted; anything
    /// else (already converted, or the server refused the stream) shows the error.
    nonisolated static func failureAction(_ kind: FailureKind, alreadyConverted: Bool) -> FailureAction {
        kind == .player && !alreadyConverted ? .retryConverted : .showError
    }

    /// Plays the video again converted by the server, from the same position with the same audio and subtitles.
    func retryTranscoded(_ emby: Emby) async {
        guard let r = req else { return }
        forceTranscode = true
        let pos = player != nil && now > 1 ? now : time
        await start(emby, r, seek: pos > 1 ? pos : 0)
    }

    /// Restart the stream with new settings, keeping the playback position.
    /// The running stream is the file itself (Direct Play), not an HLS stream from the server.
    var directPlaySession: Bool { session?.method == "DirectPlay" }

    /// Servers whose HLS stream didn't carry the requested text subtitle. Kept across app launches, so the first
    /// SUBRIP after a restart doesn't cost an extra stream restart (owner). Cleared if a server ever does carry one.
    static var hlsSubsMissing: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hlsSubsMissing") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "hlsSubsMissing") }
    }

    /// The in-stream subtitle wasn't there and the running stream copies the video from mid-file: its picture can
    /// be a GOP off the clock the downloaded cues use, so restart once re-encoded (owner: SUBRIP out of sync).
    func restartForCoveDrawnSub(_ idx: Int) async {
        guard let emby = embyRef else { return }
        await restart(emby) { $0.sub = idx; $0.burnIn = false }
    }

    /// Restart at the current position (AirPlay subtitle path changes).
    func restartKeepingPosition(_ change: (inout PlayRequest) -> Void) async {
        guard let emby = embyRef else { return }
        guard airPlayActive else { await restart(emby, change); return }
        airPlayRestartInProgress = true
        airPlayRestartToken += 1
        let tok = airPlayRestartToken
        dlog("airplay: restart for the subtitle, keeping the same AVPlayer (route stays on the TV)")
        await restart(emby, change)
        // The new item needs a moment before external playback reports active again
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.airPlayEndDebounce))
            guard let self, self.airPlayRestartToken == tok else { return }
            self.airPlayRestartInProgress = false
            self.dlog("airplay: restart settled (external playback active=\(self.player?.isExternalPlaybackActive ?? false))")
            self.recheckAirPlayEnd()
        }
    }

    private func restart(_ emby: Emby, _ change: (inout PlayRequest) -> Void) async {
        guard var r = req else { return }
        change(&r)
        // While an earlier restart is still loading there is no player yet (`now` reads 0): keep its position
        await start(emby, r, seek: player != nil ? now : max(pendingSeek, time))
    }

    /// Where a stream starts: the position a restart keeps, else the request's resume point, else 0.
    nonisolated static func effectiveStart(keep: Double?, requestStart: Double?) -> Double {
        if let k = keep, k > 0 { return k }
        if let s = requestStart, s > 0 { return s }
        return 0
    }

    func isImageSub(_ idx: Int) -> Bool {
        imageSubCodecs.contains((streams.first { $0.Index == idx }?.Codec ?? "").lowercased())
    }

    enum CueStep: Equatable { case use, askAll, keep, burnIn }

    /// What to do with one subtitle download result. `piece`: it was the first part (the next minutes), not the
    /// whole track. `haveCues`: cues from an earlier part are already shown.
    nonisolated static func cueStep(_ got: [Cue]?, piece: Bool, haveCues: Bool) -> CueStep {
        if got != nil { return .use }
        if piece { return .askAll }
        return haveCues ? .keep : .burnIn
    }

    /// Downloads a text subtitle in the background; playback keeps going meanwhile. The server reads it from the
    /// start of the file up to the end asked for (each request reads it again), so: the next minutes first, so
    /// they show quickly, then the whole track.
    func loadCues(_ emby: Emby, _ itemId: String, _ sourceId: String?, _ idx: Int, from pos: Double) {
        subGen += 1
        let gen = subGen
        subTask?.cancel()
        cues = []; caption = ""; cuesUpTo = 0
        if let c = emby.cachedCues(itemId, sourceId, idx) {
            cues = c; cuesUpTo = .infinity; subFetching = false; updateCaption(now); return
        }
        subFetching = true; updateCaption(now)
        subTask = Task {
            for end in [pos + 300, nil] as [Double?] {
                let t0 = Date()
                dlog("subs \(idx): asking up to \(end.map(fmt) ?? "the end")")
                let c = await emby.subtitleCues(itemId, sourceId, idx, upTo: end)
                dlog("subs \(idx): \(c.map { "\($0.count) cues, last at \(fmt($0.last?.end ?? 0))" } ?? "nothing") in \(Int(Date().timeIntervalSince(t0)))s, cancelled \(Task.isCancelled), current \(gen == subGen)")
                guard gen == subGen, !Task.isCancelled else { return }   // another track (or film) meanwhile
                switch Self.cueStep(c, piece: end != nil, haveCues: !cues.isEmpty) {
                case .use: break
                case .askAll: continue   // nothing said yet in these minutes (or a hiccup): get it all
                case .keep:              // a later piece failing keeps what came
                    subFetching = false; updateCaption(now); return
                case .burnIn:
                    subFetching = false; updateCaption(now)
                    // Couldn't read as text: burn it in. Not from inside subTask: the restart stops playback,
                    // which cancels subTask, and the new start() would see itself cancelled and give up.
                    subTask = nil
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.subGen else { return }   // track or film changed meanwhile
                        await self.restart(emby) { $0.sub = idx; $0.burnIn = true }
                    }
                    return
                }
                guard let c else { return }
                cues = c
                cuesUpTo = end ?? .infinity
                if let end, (c.last?.end ?? 0) > end + 120 { cuesUpTo = .infinity }   // the server sent it all already
                if cuesUpTo == .infinity { subFetching = false }
                updateCaption(now)
                if !subFetching { return }
            }
        }
    }

    // (Burning an embedded text track in while it downloads doesn't work: to burn it, the server's ffmpeg first
    // reads the track from the whole file, and on a large film Emby gives up on ffmpeg after 30 s.)

    func setSub(_ emby: Emby, _ idx: Int?) async {
        guard idx != sub, let r = req else { return }
        if let sid = SeriesLang.key(r) {
            SeriesLang.set(sid, "sub", idx.flatMap { i in streams.first { $0.Index == i } }.map(subLangName) ?? "off")
        }
        // Burned in by the server: an image subtitle, or a text one that couldn't be read (burnIn). Either way
        // only a new stream can change or remove it, and the next track must not be burned in again.
        let wasBurned = (sub.map(isImageSub) ?? false) || (req?.burnIn ?? false)
        // On AirPlay a text track goes to the TV: in the stream, else burned in (start() decides)
        if airPlayActive, let idx, !isImageSub(idx) {
            sub = idx; req?.sub = idx
            if inStreamSub != nil, legibleGroup != nil, !wasBurned, cancelCues(), switchInStream(idx) {
                legible?.setNative(true); dlog("airplay: subtitle track \(idx) switched in the stream"); return
            }
            dlog("airplay: subtitle track \(idx) chosen: restarting for the TV")
            await restart(emby) { $0.sub = idx; $0.burnIn = false }
            return
        }
        if let idx {
            if isImageSub(idx) {
                await restart(emby) { $0.sub = idx; $0.burnIn = false }
            } else {
                sub = idx; req?.sub = idx
                let path = Self.subPath(streams.first { $0.Index == idx }, burnIn: false,
                                        directPlay: session?.method == "DirectPlay")
                if wasBurned { await restart(emby) { $0.sub = idx; $0.burnIn = false } }
                else if path == .inStream {
                    let how = Self.inStreamSwitch(haveOption: false, hls: session?.method != "DirectPlay",
                                                  unsupported: inStreamUnsupported)
                    // (the subtitle group is tried first: Jellyfin lists every text track in the playlist)
                    if inStreamSub != nil || legibleGroup != nil, cancelCues(), switchInStream(idx) { return }
                    if how == .restart { dlog("subs: in-stream (HLS) track \(idx): restarting the stream"); await restart(emby) { $0.sub = idx } }
                    else if ResumeStrategy.coveDrawnSwitch(streamCopiedMidFile: streamCopiedMidFile && session?.method != "DirectPlay") == .restartReencode {
                        dlog("subs: extraction (track \(idx)): restarting re-encoded (video copy started mid-file)")
                        await restart(emby) { $0.sub = idx; $0.burnIn = false }
                    }
                    else { stopInStream(); dlog("subs: extraction (track \(idx)), no restart"); loadCues(emby, r.item.id, r.sourceId, idx, from: now) }
                } else if ResumeStrategy.coveDrawnSwitch(streamCopiedMidFile: streamCopiedMidFile && session?.method != "DirectPlay") == .restartReencode {
                    // The copied video can be a GOP off the clock the cues use: restart once, re-encoded
                    dlog("subs: \(path == .file ? "external file" : "extraction") (track \(idx)): restarting re-encoded (video copy started mid-file)")
                    await restart(emby) { $0.sub = idx; $0.burnIn = false }
                } else {
                    stopInStream()
                    dlog("subs: \(path == .file ? "external file" : "extraction") (track \(idx)), no restart")
                    loadCues(emby, r.item.id, r.sourceId, idx, from: now)
                }
            }
        } else {
            stopInStream()
            subGen += 1
            subTask?.cancel(); subFetching = false
        cues = []; caption = ""; loadingSubs = false; sub = nil; req?.sub = nil; req?.noSub = true
            if wasBurned { await restart(emby) { $0.sub = nil; $0.noSub = true; $0.burnIn = false } }
        }
    }

    func setAudio(_ emby: Emby, _ idx: Int) async {
        guard idx != audio else { return }
        if let r = req, let sid = SeriesLang.key(r),
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
        // Published only when the shown second changes (the clock, the progress bar, Up next count in seconds):
        // setting it on every 0.2 s tick redrew the whole player 5 times a second. Seeks set it directly.
        if t.isFinite, Int(t) != Int(time) || abs(t - time) >= 1 { time = t }
        if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0, d != duration { duration = d }
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
        var info: [String: Any]?
        if isTranscoding { info = await emby?.sessionInfo()?["TranscodingInfo"] as? [String: Any] }
        let method = session.map { PlayMethod.classify(url: $0.url.absoluteString, transcodingInfo: info) } ?? PlayMethod.directPlay
        out.append(("Play method", PlayMethod.describe(method, container: streamContainer,
                                                       sourceVideo: streams.first { $0.`Type` == "Video" }?.Codec,
                                                       sourceAudio: streams.first { $0.Index == audio }?.Codec,
                                                       transcodingInfo: info)))
        if let v = streams.first(where: { $0.`Type` == "Video" }) {
            var s = (v.Codec ?? "?").uppercased()
            if let w = v.Width, let h = v.Height { s += " · \(w)×\(h)" }
            if let b = v.BitRate { s += " · " + mbps(Double(b)) }
            out.append(("Source video", s))
        }
        if let a = streams.first(where: { $0.Index == audio }) { out.append(("Source audio", a.DisplayTitle ?? a.Codec ?? "?")) }
        if isTranscoding, let t = info {
            var v = (t["IsVideoDirect"] as? Bool == true) ? "copied" : ((t["VideoCodec"] as? String ?? "?").uppercased())
            if let w = num(t["Width"]), let h = num(t["Height"]) { v += " · \(Int(w))×\(Int(h))" }
            out.append(("Server video", v))
            out.append(("Server audio", (t["IsAudioDirect"] as? Bool == true) ? "copied" : ((t["AudioCodec"] as? String ?? "?").uppercased())))
            if let b = num(t["Bitrate"]) { out.append(("Stream bitrate", mbps(b))) }
            if let f = num(t["Framerate"]) { out.append(("Encoder speed", String(format: "%.0f fps", f))) }
            // Only when something is really converted: a remux (video and audio copied) can still carry a
            // reason such as SubtitleCodecNotSupported for a track that isn't played (owner)
            let converted = !(t["IsVideoDirect"] as? Bool == true && t["IsAudioDirect"] as? Bool == true)
            if converted, let r = t["TranscodeReasons"] as? [String], !r.isEmpty {
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

    /// The item playing (SyncPlay)
    var currentItemId: String? { req?.item.id }

    /// Play / pause from the user (buttons, keys, media keys). In a SyncPlay group it becomes a request to the
    /// group, and happens when the group's command comes back.
    func togglePlay() {
        guard let p = player else { return }
        if emby?.syncPlay.group.intercept(p.rate > 0 ? .pause : .play) == true { return }
        localTogglePlay()
    }

    func localTogglePlay() {
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

    /// A seek from the user; in a SyncPlay group it is sent to the group instead.
    func seek(to t: Double) {
        let c = max(0, duration > 0 ? min(t, duration - 1) : t)
        if emby?.syncPlay.group.intercept(.seek(ticks: Int64(c * SyncPlayGroup.ticksPerSecond))) == true { return }
        localSeek(to: c)
    }

    func localSeek(to t: Double) {
        let c = max(0, duration > 0 ? min(t, duration - 1) : t)
        time = c
        player?.seek(to: CMTime(seconds: c, preferredTimescale: 600))
        updateCaption(c)
    }

    func skip(_ d: Double) { seek(to: now + d) }

    /// SyncPlay timing: bookkeeping localTogglePlay does on resume, for a start by setRate(_:time:atHostTime:)
    func syncTimedStartBegan() {
        pausedAt = nil
        pausedKeepAlive(false)
        debugTimer?.invalidate(); debugTimer = nil
        playing = true
    }

    /// SyncPlay timing: caption refresh after a group seek
    func localSeekCaption(_ t: Double) { updateCaption(t) }

    /// Stops a download in progress (another path takes over). Always true, so it can sit in a condition.
    private func cancelCues() -> Bool {
        subGen += 1; subTask?.cancel(); subFetching = false; cues = []; cuesUpTo = 0; loadingSubs = false
        return true
    }

    private func updateCaption(_ raw: Double) {
        // (captions read from the stream are set by the legible output)
        if inStreamSub != nil { if loadingSubs { loadingSubs = false }; return }
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
        // (a jump past the part downloaded so far waits for the whole track already coming: asking again from
        // there would make the server read the file once more)
        let waiting = subFetching && raw >= cuesUpTo
        if waiting != loadingSubs { loadingSubs = waiting }
    }

    func stop() {
        startGen += 1
        if let f = failObs { NotificationCenter.default.removeObserver(f); failObs = nil }
        if subFetching { dlog("subs: download stopped (stop)") }
        subGen += 1; loadingSubs = false          // a subtitle still downloading must not restart playback later
        subTask?.cancel(); subFetching = false
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
        airPlayObs = nil
        if airPlayActive, let p = player { Self.stashAirPlay(p) }   // next episode / restart keeps the TV
        else if !Self.airPlayHandoffFresh { AirPlaySleep.set(false) }
        legible?.detach(); legible = nil; legibleGroup = nil; inStreamSub = nil; inStreamDecided = false
        endAirPlayLocal()
        // An AirPlay subtitle restart keeps the AVPlayer playing and set (the picker keeps routing it): pausing or
        // clearing it dropped the route (owner: AirPlay started and stopped at once). start() takes it back.
        if !(airPlayRestartInProgress && airPlayActive) { player?.pause(); player = nil }
        obs = nil; caption = ""; resumeTarget = 0
        pendingSeek = 0                           // a start that was interrupted must not leak its position
    }
}
