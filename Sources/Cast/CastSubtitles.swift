import Foundation

// How a subtitle reaches the TV while casting, and what happens when the TV fails on it (pure parts unit-tested in
// Tests/CastSubtitleTests.swift).
// Google's Default Media Receiver fails the WHOLE media (IDLE, ERROR, "The TV couldn't play this video") when a
// WebVTT side track can't be fetched or parsed: an embedded SubRip/ASS the server has to extract first (slow → the
// receiver times out), a 404/500, or non-WebVTT content. So only text that's ready fast goes as a side track; ASS/SSA
// and picture subtitles are burned in by the server, and an embedded text track is fetched once first (warm-up,
// ~8 s): a slow or bad answer → burned in. A side track that still fails is retried burned in, then without subtitles.

enum CastSubDelivery: Equatable {
    case sideTrack       // WebVTT side track (the TV fetches /Subtitles/{index}/Stream.vtt)
    case warmThenSide    // embedded text: fetch the VTT first; ok → side track, else burn in
    case burnIn          // SubtitleMethod=Encode on the HLS stream
}

enum CastSubtitles {
    /// Text codecs the server converts to WebVTT quickly enough to be a side track.
    nonisolated static let sideTrackCodecs: Set<String> = ["srt", "subrip", "vtt", "webvtt", "text", "mov_text", "tx3g"]
    /// Styled text the receiver shows badly or the server converts slowly: burned in.
    nonisolated static let styledCodecs: Set<String> = ["ass", "ssa"]
    /// Seconds the warm-up fetch may take.
    nonisolated static let warmTimeout: TimeInterval = 8
    /// An ERROR this soon after a LOAD is blamed on the subtitle.
    nonisolated static let retryWindow: TimeInterval = 20
    static let noSubsNotice = "The TV couldn't show these subtitles — playing without them."

    /// The delivery for a subtitle track (nil stream: unknown → burned in, the safe path).
    nonisolated static func delivery(codec: String?, isExternal: Bool) -> CastSubDelivery {
        let c = (codec ?? "").lowercased()
        if imageSubCodecs.contains(c) || styledCodecs.contains(c) { return .burnIn }
        guard sideTrackCodecs.contains(c) else { return .burnIn }
        return isExternal ? .sideTrack : .warmThenSide
    }

    nonisolated static func delivery(_ st: MStream?) -> CastSubDelivery {
        guard let st else { return .burnIn }
        return delivery(codec: st.Codec, isExternal: st.IsExternal ?? false)
    }

    /// The final delivery (pure, tested). Emby's /Subtitles/{i}/Stream.vtt has no CORS headers for the Cast
    /// receiver, so the Default Media Receiver fails even an external SRT side track there (owner log: error 100,
    /// IDLE(ERROR)): on Emby every subtitle is burned in. Jellyfin sends CORS: side track, with the retry chain. A
    /// track whose side track already failed this session goes straight to burn-in (a seek reload must not retry it).
    nonisolated static func decide(_ base: CastSubDelivery, isJellyfin: Bool, sideFailedBefore: Bool) -> CastSubDelivery {
        if base == .burnIn || !isJellyfin || sideFailedBefore { return .burnIn }
        return base
    }

    /// Item + track whose side track failed on the TV in this app session.
    @MainActor static var sideFailed: Set<String> = []
    nonisolated static func key(item: String, index: Int) -> String { "\(item)#\(index)" }

    /// Warm-up verdict: the answer must be fast, 2xx and WebVTT.
    nonisolated static func warmOK(status: Int?, body: Data?, elapsed: TimeInterval) -> Bool {
        guard let status, (200..<300).contains(status), elapsed < warmTimeout, let body else { return false }
        let head = String(decoding: body.prefix(16), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        return head.hasPrefix("WEBVTT")
    }

    /// The step after an IDLE(ERROR). `mode`: how the subtitle went in the failed LOAD.
    enum Retry: Equatable { case burnIn, noSubs, fail }
    enum Mode: Equatable { case none, side, burned }

    nonisolated static func retry(mode: Mode, sinceLoad: TimeInterval, triedNoSubs: Bool) -> Retry {
        guard sinceLoad <= retryWindow, !triedNoSubs else { return .fail }
        switch mode {
        case .none: return .fail
        case .side: return .burnIn
        case .burned: return .noSubs
        }
    }

    /// For the log: "4 (subrip, embedded, eng)".
    nonisolated static func describe(_ idx: Int, _ st: MStream?) -> String {
        "\(idx) (\(st?.Codec ?? "?"), \((st?.IsExternal ?? false) ? "external" : "embedded"), \(st?.Language ?? "no language"))"
    }
}

extension CastSession {
    /// Decides side track vs burn-in for the request's subtitle (warming an embedded track's VTT first).
    func prepareSubtitle() async {
        guard let s = request?.sub else { return }
        let st = streams.first { $0.Index == s }
        let jf = emby?.isJellyfin ?? false
        let failed = item.map { CastSubtitles.sideFailed.contains(CastSubtitles.key(item: $0.id, index: s)) } ?? false
        var d = CastSubtitles.decide(CastSubtitles.delivery(st), isJellyfin: jf, sideFailedBefore: failed)
        if d == .burnIn, CastSubtitles.delivery(st) != .burnIn {
            DebugLog.write("cast: subtitle \(s) burned in (\(failed ? "its side track failed earlier" : "Emby: no CORS on side tracks"))")
        }
        if d == .warmThenSide {
            d = await warm(s) ? .sideTrack : .burnIn
        }
        guard request?.sub == s else { return }
        request?.subIsImage = d == .burnIn
        DebugLog.write("cast: subtitle \(CastSubtitles.describe(s, st)) → \(d == .burnIn ? "burned in" : "side track")")
    }

    private func warm(_ idx: Int) async -> Bool {
        guard let emby, let item, let sid = request?.sourceId,
              let u = CastStream.subtitleURL(server: emby.server, token: emby.token, keyName: emby.keyName,
                                             itemId: item.id, sourceId: sid, index: idx) else { return false }
        var r = URLRequest(url: u)
        r.timeoutInterval = CastSubtitles.warmTimeout
        let t0 = Date()
        let res = try? await URLSession.shared.data(for: r)
        let el = Date().timeIntervalSince(t0)
        let code = (res?.1 as? HTTPURLResponse)?.statusCode
        let ok = CastSubtitles.warmOK(status: code, body: res?.0, elapsed: el)
        DebugLog.write("cast: subtitle \(idx) warm-up \(code.map(String.init) ?? "no answer") in \(String(format: "%.1f", el)) s → \(ok ? "ok" : "not usable")")
        return ok
    }

    /// IDLE(ERROR): retry once burned in, then once without subtitles; true when a retry was sent.
    func retrySubtitleAfterError() -> Bool {
        guard var r = request, transportId != nil else { return false }
        let mode: CastSubtitles.Mode = r.sub == nil ? .none : (r.subIsImage ? .burned : .side)
        let step = CastSubtitles.retry(mode: mode, sinceLoad: Date().timeIntervalSince(loadAt), triedNoSubs: subRetryNoSubs)
        switch step {
        case .fail: return false
        case .burnIn:
            DebugLog.write("cast: retry with burned-in subtitle (remembered for this item/track)")
            if let it = item, let s = r.sub { CastSubtitles.sideFailed.insert(CastSubtitles.key(item: it.id, index: s)) }
            r.subIsImage = true
        case .noSubs:
            DebugLog.write("cast: retry without subtitles")
            r.sub = nil; r.subIsImage = false
            subRetryNoSubs = true
            sub = nil
            show(notice: CastSubtitles.noSubsNotice)
        }
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
