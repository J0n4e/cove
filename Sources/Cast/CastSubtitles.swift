import Foundation

// How a subtitle reaches the TV while casting, and what happens when the TV fails on it (pure parts unit-tested in
// Tests/CastSubtitleTests.swift and Tests/CastSubtitleServerTests.swift).
// Emby's /Subtitles/{i}/Stream.vtt has no CORS headers (the Default Media Receiver fails it, detailedErrorCode=100)
// and Emby's burn-in shows nothing on the TV, so Cove serves every TEXT subtitle itself (CastSubtitleServer.swift):
// the track is read exactly as the local player reads it (Emby.subtitleCues, cached whole tracks), converted to
// WebVTT and served from this Mac with CORS headers. Same path for Emby and Jellyfin. Only PICTURE subtitles
// (PGS/VOBSUB/DVB) are still burned in by the server. A receiver ERROR soon after a LOAD whose video the server
// COPIED → reload with a forced video transcode, keeping the side track (CastTranscode.swift); still failing →
// transcode without subtitles; then the error.

enum CastSubDelivery: Equatable {
    case local     // text: Cove serves it as a WebVTT side track
    case burnIn    // picture: SubtitleMethod=Encode / PlaybackInfo burn-in on the HLS stream
}

enum CastSubtitles {
    /// Seconds to wait for a whole track (an embedded one is extracted first) before the LOAD.
    nonisolated static let fullWait: TimeInterval = 20
    /// An ERROR this soon after a LOAD is blamed on the stream (copied video / subtitle) and retried.
    nonisolated static let retryWindow: TimeInterval = 30
    static let noSubsNotice = "The TV couldn't load the subtitles — playing without them."
    static let preparingNotice = "Preparing subtitles…"
    static let notReadyNotice = "The subtitles aren't ready yet — playing without them. Choose them again in a moment."

    /// Picture subtitles → burned in; every other known track (SRT, embedded SubRip, ASS, VTT, mov_text…) → local.
    nonisolated static func delivery(codec: String?, isExternal: Bool) -> CastSubDelivery {
        let c = (codec ?? "").lowercased()
        return imageSubCodecs.contains(c) ? .burnIn : .local
    }

    nonisolated static func delivery(_ st: MStream?) -> CastSubDelivery {
        guard let st else { return .burnIn }   // unknown track: the server's burn-in is the safe path
        return delivery(codec: st.Codec, isExternal: st.IsExternal ?? false)
    }

    /// The step after an IDLE(ERROR). `mode`: how the subtitle went in the failed LOAD; `transcoded`: the failed
    /// LOAD's video was already transcoded (forced transcode or a burn-in).
    enum Retry: Equatable { case transcode, noSubs, fail }
    enum Mode: Equatable { case none, side, burned }

    nonisolated static func retry(mode: Mode, sinceLoad: TimeInterval, transcoded: Bool, triedNoSubs: Bool) -> Retry {
        guard sinceLoad <= retryWindow else { return .fail }
        if !transcoded && mode != .burned { return .transcode }   // step 1: the copied video is the usual culprit
        if mode != .none && !triedNoSubs { return .noSubs }       // step 2: transcode without subtitles
        return .fail
    }

    /// Cast text style from Cove's subtitle settings (size, colour, edge).
    nonisolated static func style(size: String?, color: String?, shadow: String?, bg: String?) -> [String: Any] {
        let frac = PlayerUIModel.sizes.first { $0.0 == (size ?? "normal") }?.2 ?? 0.045
        let fg = ["yellow": "#FFFF00FF", "gray": "#CCCCCCFF", "black": "#000000FF"][color ?? ""] ?? "#FFFFFFFF"
        let edge = ["none": "NONE", "outline": "OUTLINE", "raised": "RAISED"][shadow ?? ""] ?? "DROP_SHADOW"
        let back = ["semi": "#00000080", "black": "#000000FF"][bg ?? ""] ?? "#00000000"
        return ["foregroundColor": fg, "edgeType": edge, "edgeColor": color == "black" ? "#FFFFFFFF" : "#000000FF",
                "backgroundColor": back, "fontScale": (frac / 0.045 * 100).rounded() / 100]
    }

    /// For the log: "4 (subrip, embedded, eng)".
    nonisolated static func describe(_ idx: Int, _ st: MStream?) -> String {
        "\(idx) (\(st?.Codec ?? "?"), \((st?.IsExternal ?? false) ? "external" : "embedded"), \(st?.Language ?? "no language"))"
    }
}

extension CastSession {
    /// Text subtitle → reads its cues (waiting up to 20 s for the whole track) and serves it from this Mac;
    /// picture → burned in. Sets request.subIsImage / subURL.
    func prepareSubtitle() async {
        subURL = nil; subVTT = nil; subCues = nil
        guard let s = request?.sub else { stopSubtitleServer(); return }
        let st = streams.first { $0.Index == s }
        let d = CastSubtitles.delivery(st)
        if d == .burnIn {
            request?.subIsImage = true
            stopSubtitleServer()
            DebugLog.write("cast: subtitle \(CastSubtitles.describe(s, st)) → burned in (picture subtitle)")
            return
        }
        request?.subIsImage = false
        guard let emby, let item else { return }
        let itemId = item.id, sid = request?.sourceId
        var cues = emby.cachedCues(itemId, sid, s)
        if cues == nil {
            notice = CastSubtitles.preparingNotice
            let full = Task { await emby.subtitleCues(itemId, sid, s) }   // keeps going after the timeout: fills the cache
            cues = await Self.within(CastSubtitles.fullWait) { await full.value }
            if cues == nil {
                // Not whole yet: what the server can give for the next minutes
                let from = request?.start ?? 0
                cues = await Self.within(10) { await emby.subtitleCues(itemId, sid, s, upTo: from + 900) }
            }
            if notice == CastSubtitles.preparingNotice { notice = nil }
        }
        guard request?.sub == s, self.item?.id == itemId else { return }
        guard let cues, !cues.isEmpty else {
            DebugLog.write("cast: subtitle \(CastSubtitles.describe(s, st)) not ready → LOAD without it")
            request?.sub = nil; sub = nil
            show(notice: CastSubtitles.notReadyNotice)
            stopSubtitleServer()
            return
        }
        subCues = cues
        subVTT = CastVTT.make(cues, offsetMs: subOffset)
        DebugLog.write("cast: serving subtitle \(CastSubtitles.describe(s, st)) (\(cues.count) cues)")
    }

    /// Puts the prepared VTT on the local server (needs the connection to the TV for the right address);
    /// false when it can't be served (the LOAD then goes without subtitles).
    func publishSubtitle() async -> Bool {
        guard let vtt = subVTT else { return false }
        guard let u = await CastSubtitleServer.shared.serve(vtt, tv: channel?.remoteIP, local: channel?.localIP) else {
            DebugLog.write("cast: subtitle server unavailable → LOAD without subtitles")
            request?.sub = nil; sub = nil; subVTT = nil
            show(notice: CastSubtitles.noSubsNotice)
            return false
        }
        subURL = u
        CastSubAwake.set(true)
        return true
    }

    func stopSubtitleServer() {
        subURL = nil; subVTT = nil; subCues = nil
        CastSubtitleServer.shared.stop()
        CastSubAwake.set(false)
    }

    /// `work`'s result, or nil after `seconds` (the work isn't cancelled).
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await work() }
            g.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    /// IDLE(ERROR) soon after a LOAD: 1) reload with a forced video transcode (side track kept, remembered per
    /// device + item), 2) transcode without subtitles; true when a retry was sent.
    func retryAfterError() -> Bool {
        guard var r = request, transportId != nil else { return false }
        let mode: CastSubtitles.Mode = r.sub == nil ? .none : (r.subIsImage ? .burned : .side)
        let step = CastSubtitles.retry(mode: mode, sinceLoad: Date().timeIntervalSince(loadAt), transcoded: r.transcode,
                                       triedNoSubs: subRetryNoSubs)
        if step == .fail { return false }
        if step == .transcode {
            DebugLog.write("cast: retry with video transcode")
            if let d = device { CastCopyMemory.shared.markFailed(device: d.id, item: r.itemId) }
            r.transcode = true
            request = r
            statusTime = time; statusDate = Date()
            playerState = "BUFFERING"
            reportStop()
            sendLoad()
            return true
        }
        DebugLog.write("cast: retry without subtitles (video transcoded)")
        r.sub = nil; r.subIsImage = false; r.transcode = true
        subRetryNoSubs = true
        sub = nil
        stopSubtitleServer()
        show(notice: CastSubtitles.noSubsNotice)
        request = r
        playerState = "BUFFERING"
        reportStop()
        sendLoad()
        return true
    }

    /// Fields the receiver gives about an error (MEDIA_STATUS / ERROR message), for the log.
    nonisolated static func errorDetails(_ j: [String: Any]) -> String {
        var parts: [String] = []
        let s = (j["status"] as? [[String: Any]])?.first ?? j
        for k in ["detailedErrorCode", "reason", "extendedStatus", "itemId"] {
            if let v = s[k] ?? j[k] { parts.append("\(k)=\(v)") }
        }
        return parts.isEmpty ? "no details" : parts.joined(separator: ", ")
    }
}
