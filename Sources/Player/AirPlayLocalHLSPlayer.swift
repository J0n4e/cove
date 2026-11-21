import AVFoundation
import Foundation

// The player side of AirPlay's local HLS (Player/AirPlayLocalHLS.swift): decide it in start(), build and serve the
// local master around the server's stream, select its WebVTT rendition, fall back to the server's burn-in once.

/// Cues that may arrive after the local HLS already started (a slow embedded-track extraction).
@MainActor
private final class LateCues { var cues: [Cue]?; var done = false; var late = false }

extension PlayerModel {
    /// Films whose local master didn't load once: burn-in from then on.
    static var airPlayLocalFailedItems: Set<String> = []

    /// The text track start() serves through the local HLS (nil: not this path).
    func airPlayLocalChoice(_ req: PlayRequest) -> Int? {
        guard let s = req.sub, !req.burnIn else { return nil }
        let c = AirPlayHLS.choice(airPlay: airPlayActive, hasSub: true, image: isImageSub(s), directPlay: false,
                                  failedBefore: Self.airPlayLocalFailedItems.contains(req.item.id))
        return c == .localHLS ? s : nil
    }

    /// Builds Cove's local master around the server stream `u` (fetched without subtitles) and serves it with the
    /// WebVTT rendition of track `s`. nil: couldn't (the caller burns it in instead).
    func airPlayLocalURL(_ emby: Emby, server u: URL, track s: Int, req: PlayRequest, gen: Int) async -> URL? {
        var r = URLRequest(url: u)
        r.timeoutInterval = 30
        guard let (d, resp) = try? await Net.session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: d, encoding: .utf8) else {
            dlog("airplay: local HLS: the server's master playlist didn't load"); return nil
        }
        guard gen == startGen else { return nil }
        var dur = Double(req.item.RunTimeTicks ?? 0) / 10_000_000
        if dur <= 0, let v = AirPlayHLS.firstVariant(text), let vu = URL(string: AirPlayHLS.absolute(v, base: u)),
           let (vd, _) = try? await Net.session.data(from: vu), let vt = String(data: vd, encoding: .utf8) {
            dur = AirPlayHLS.totalDuration(vt)
        }
        if dur <= 0 { dur = 4 * 3600 }
        let st = streams.first { $0.Index == s }
        let cues = await airPlayCues(emby, req, s, gen: gen)
        guard gen == startGen else { return nil }
        let name = st.map(subLangName) ?? "Subtitles"
        let lang = Self.normLang(st?.Language)
        let ts = AirPlayHLS.mpegts
        guard let url = await CastSubtitleServer.shared.serveHLS(
            master: { AirPlayHLS.master(text, serverURL: u, subsURI: $0, name: name, lang: lang) },
            cues: cues ?? [], duration: dur, offsetMs: subOffset, mpegts: ts) else {
            dlog("airplay: local HLS couldn't be served (no server, LAN address or master)"); return nil
        }
        guard gen == startGen else { return nil }
        airPlayLocalSub = s; airPlayLocalName = name; airPlayLocalAt = Date()
        dlog("airplay: local HLS with subtitle \(s) (\(cues?.count ?? 0) cues) at \(url.host ?? "?"):\(url.port ?? 0), \(AirPlayHLS.segmentCount(duration: dur)) segments of \(Int(AirPlayHLS.segmentLength)) s, X-TIMESTAMP-MAP MPEGTS:\(ts)")
        return url
    }

    /// The track's cues: cached, else downloaded (waiting 25 s at most; later ones are served when they come).
    private func airPlayCues(_ emby: Emby, _ req: PlayRequest, _ s: Int, gen: Int) async -> [Cue]? {
        if let c = emby.cachedCues(req.item.id, req.sourceId, s) { return c }
        let box = LateCues()
        Task { @MainActor [weak self] in
            box.cues = await emby.subtitleCues(req.item.id, req.sourceId, s)
            box.done = true
            guard box.late, let self, gen == self.startGen, self.airPlayLocalSub == s, let c = box.cues else { return }
            CastSubtitleServer.shared.updateHLSCues(c, offsetMs: self.subOffset)
            self.dlog("airplay: subtitle \(s) cues arrived late (\(c.count) cues), served now")
        }
        for _ in 0..<50 where !box.done { try? await Task.sleep(for: .milliseconds(500)) }
        if !box.done { box.late = true; dlog("airplay: subtitle \(s) still downloading: starting, cues follow") }
        return box.cues
    }

    /// The local item is ready: select its WebVTT rendition, rendered by AVPlayer (on the TV).
    func selectAirPlayLocal(_ item: AVPlayerItem, gen: Int) {
        guard let s = airPlayLocalSub else { return }
        Task { @MainActor [weak self] in
            let g = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard let self, gen == self.startGen, self.airPlayLocalSub == s else { return }
            guard let g else { self.dlog("airplay: no legible group in the local HLS"); return }
            let opts = g.options.filter { $0.mediaType != .closedCaption && !$0.displayName.localizedCaseInsensitiveContains("transcribed") }
            guard let o = opts.first(where: { $0.displayName == self.airPlayLocalName }) ?? opts.first else {
                self.dlog("airplay: the local HLS has no subtitle option"); return
            }
            item.select(o, in: g)
            self.legibleGroup = g   // "Off" deselects it (stopInStream)
            self.dlog("airplay: legible option selected ('\(o.displayName)', track \(s))")
        }
    }

    /// The local master failed to load: burn it in by the server instead, once per film. True: handled.
    func airPlayLocalFailed(gen: Int) -> Bool {
        guard let s = airPlayLocalSub, gen == startGen, let r = currentRequest,
              !isReady || Date().timeIntervalSince(airPlayLocalAt) < 10 else { return false }
        airPlayLocalSub = nil
        Self.airPlayLocalFailedItems.insert(r.item.id)
        CastSubtitleServer.shared.stopHLS()
        dlog("airplay: local HLS didn't load: falling back to the server's burn-in for track \(s) (once)")
        airPlayBurnPending = true
        Task { @MainActor [weak self] in await self?.restartKeepingPosition { $0.sub = s; $0.burnIn = true } }
        return true
    }

    /// Stops serving the local HLS (player closed, another path).
    func endAirPlayLocal() {
        guard airPlayLocalSub != nil else { return }
        airPlayLocalSub = nil
        CastSubtitleServer.shared.stopHLS()
    }
}
