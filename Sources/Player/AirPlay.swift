import AVFoundation
import CoreAudio
import Foundation
import IOKit.pwr_mgt

// AirPlay video from the player: AVPlayer's external playback (the route picker sits in the Glass3D bar).
// Cove keeps playing the item (server reports, resume, next episode, SyncPlay unchanged); the TV shows it.
// Subtitles Cove draws over the video (external SRT, extracted SUBRIP) don't reach the TV, so while AirPlay is on a
// text subtitle comes inside the HLS stream (AVPlayer renders it, on the TV) or, when the server leaves it out of
// the stream (Emby, see hlsSubsMissing), is burned in by the server. When AirPlay ends, Cove draws it again.

/// What to do with the current subtitle when AirPlay starts or ends (or the track changes during AirPlay).
enum AirPlaySubAction: Equatable {
    case keep        // nothing to change (no track, image/burned track, or already in the stream)
    case inStream    // restart with the track inside the HLS stream (SubtitleMethod=Hls), rendered by AVPlayer
    case burnIn      // restart with the track burned in by the server (SubtitleMethod=Encode)
    case coveDrawn   // AirPlay ended on a track burned in only for it: restart with Cove drawing it again
}

extension PlayerModel {
    /// The subtitle path while on AirPlay (pure, tested). `path`: how the track is shown now (SubPath with the
    /// request's burnIn). `playingInStream`: its text comes from the stream already. `burnedForAirPlay`: it was
    /// burned in only because of AirPlay. `hls`: the stream is HLS (not Direct Play). `textCodec`: the server can put
    /// the track into the HLS stream as WebVTT.
    nonisolated static func airPlaySubAction(path: SubPath, airPlay: Bool, playingInStream: Bool, burnedForAirPlay: Bool,
                                             hls: Bool, inStreamUnsupported: Bool, textCodec: Bool) -> AirPlaySubAction {
        guard airPlay else { return burnedForAirPlay ? .coveDrawn : .keep }
        switch path {
        case .none, .burnIn: return .keep
        case .inStream, .file, .extraction:
            if playingInStream { return .keep }
            return hls && !inStreamUnsupported && textCodec ? .inStream : .burnIn
        }
    }

    nonisolated static func isTextCodec(_ st: MStream?) -> Bool {
        inStreamTextCodecs.contains((st?.Codec ?? "").lowercased())
    }

    /// The decision for track `idx` in the current state.
    func airPlaySubAction(for idx: Int) -> AirPlaySubAction {
        let st = streams.first { $0.Index == idx }
        return Self.airPlaySubAction(path: Self.subPath(st, burnIn: currentRequest?.burnIn ?? false, directPlay: directPlaySession),
                                     airPlay: airPlayActive, playingInStream: inStreamSub != nil,
                                     burnedForAirPlay: airPlayBurned, hls: !directPlaySession,
                                     inStreamUnsupported: Self.airPlayNoHlsSubs(isJellyfin: embyRef?.isJellyfin ?? false,
                                                                                 known: inStreamUnsupported),
                                     textCodec: Self.isTextCodec(st))
    }

    /// Emby's HLS stream has no rendition for the chosen text track (only "CC"/"Transcribed"), so on AirPlay it goes
    /// straight to burn-in instead of an in-stream try first (pure, tested).
    nonisolated static func airPlayNoHlsSubs(isJellyfin: Bool, known: Bool) -> Bool { known || !isJellyfin }

    /// Seconds isExternalPlaybackActive must stay false before AirPlay counts as ended.
    nonisolated static let airPlayEndDebounce: TimeInterval = 4

    /// AirPlay ended for real (pure, tested): off for the whole debounce and no Cove restart running.
    nonisolated static func airPlayEnded(activeNow: Bool, offFor: TimeInterval, restartInProgress: Bool) -> Bool {
        !activeNow && !restartInProgress && offFor >= airPlayEndDebounce
    }

    // MARK: Route

    /// Watches the player's external playback (AirPlay video).
    func observeAirPlay(_ p: AVPlayer, gen: Int) {
        p.allowsExternalPlayback = true
        // (usesExternalPlaybackWhileExternalScreenIsActive is iOS/tvOS only)
        airPlayObs = p.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] p, _ in
            let on = p.isExternalPlaybackActive
            Task { @MainActor in self?.airPlayChanged(on, gen: gen) }
        }
    }

    private func airPlayChanged(_ on: Bool, gen: Int) {
        guard gen == startGen else { return }
        if !on, airPlayActive {
            // A brief false (new item on the same player, Cove's own restart) must not end AirPlay: check again later
            airPlayOffSince = airPlayOffSince ?? Date()
            dlog("airplay: external playback active=false\(airPlayRestartInProgress ? " during Cove's restart" : ""): waiting \(Int(Self.airPlayEndDebounce)) s before ending")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.airPlayEndDebounce + 0.1))
                self?.recheckAirPlayEnd()
            }
            return
        }
        if on { airPlayOffSince = nil }
        applyAirPlayRoute(on)
    }

    /// Ends AirPlay once the route has really stayed off (see airPlayEnded).
    func recheckAirPlayEnd() {
        guard airPlayActive, let since = airPlayOffSince else { return }
        let activeNow = player?.isExternalPlaybackActive ?? false
        if activeNow { airPlayOffSince = nil; dlog("airplay: route still active, not ended"); return }
        guard Self.airPlayEnded(activeNow: activeNow, offFor: Date().timeIntervalSince(since),
                                restartInProgress: airPlayRestartInProgress) else { return }
        airPlayOffSince = nil
        applyAirPlayRoute(false)
    }

    private func applyAirPlayRoute(_ on: Bool) {
        legible?.setNative(on)
        AirPlaySleep.set(on)
        guard on != airPlayActive else { return }
        airPlayActive = on
        if on { airPlayDevice = AirPlayRoute.deviceName() ?? "AirPlay device" }
        dlog("airplay: \(on ? "route picked, external playback active=true on '\(airPlayDevice)'" : "ended, back on the Mac (external playback active=false)")")
        if on { AirPlayMenu.closed("menu closed (route active)") }
        Task { await applyAirPlaySubs() }
    }

    /// Brings the current subtitle onto the right path for AirPlay on/off (one restart at the position at most).
    func applyAirPlaySubs() async {
        guard let idx = sub, !isImageSub(idx) else { airPlayBurned = airPlayActive && airPlayBurned; return }
        let action = airPlaySubAction(for: idx)
        dlog("airplay: subtitle track \(idx) → \(action)")
        if action == .coveDrawn, airPlayRestartInProgress {   // no flip back during Cove's own AirPlay restart
            dlog("airplay: restart in progress, not switching back to Cove-drawn subtitles"); return
        }
        switch action {
        case .keep: legible?.setNative(airPlayActive)
        case .inStream: await restartKeepingPosition { $0.sub = idx; $0.burnIn = false }
        case .burnIn:
            if let e = embyRef, !e.isJellyfin { Self.hlsSubsMissing.insert(e.server) }
            airPlayBurnPending = true
            await restartKeepingPosition { $0.sub = idx; $0.burnIn = true }
        case .coveDrawn:
            airPlayBurned = false
            await restartKeepingPosition { $0.sub = idx; $0.burnIn = false }
        }
    }

    // MARK: Next episode keeps the route

    /// The AirPlaying AVPlayer, handed from a player that stopped to the next start (next episode, a restart):
    /// the route belongs to the AVPlayer, so a new one would drop back to the Mac.
    static var airPlayHandoff: (player: AVPlayer, at: Date)?

    static func stashAirPlay(_ p: AVPlayer) {
        let at = Date()
        airPlayHandoff = (p, at)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard let h = airPlayHandoff, h.at == at else { return }
            // Nobody took it: the player was closed. Stop the TV and let the Mac sleep again.
            airPlayHandoff = nil
            h.player.replaceCurrentItem(with: nil)
            AirPlaySleep.set(false)
            DebugLog.write("airplay: player closed, route released")
        }
    }

    static var airPlayHandoffFresh: Bool {
        airPlayHandoff.map { Date().timeIntervalSince($0.at) < 8 } ?? false
    }

    static func takeAirPlayHandoff() -> AVPlayer? {
        guard airPlayHandoffFresh, let h = airPlayHandoff else { airPlayHandoff = nil; return nil }
        airPlayHandoff = nil
        return h.player
    }
}

/// No idle sleep while AirPlay plays (the Mac feeds the TV); the display may sleep.
@MainActor
enum AirPlaySleep {
    private static var id: IOPMAssertionID = 0
    private(set) static var held = false

    static func set(_ on: Bool) {
        TvRouteState.setAirPlay(on)   // Settings locks the TV choice while AirPlay runs (TvTarget.swift)
        if on == held { return }
        if on {
            var a: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Cove AirPlay" as CFString, &a)
            guard r == kIOReturnSuccess else { DebugLog.write("airplay: sleep assertion failed (\(r))"); return }
            id = a; held = true
            DebugLog.write("airplay: Mac sleep prevented")
        } else {
            IOPMAssertionRelease(id)
            id = 0; held = false
            DebugLog.write("airplay: Mac sleep allowed again")
        }
    }
}

/// The AirPlay device's name. macOS has no AVAudioSession route; while AirPlaying the system audio output is
/// usually the AirPlay device, so its name is read from CoreAudio when its transport type is AirPlay.
enum AirPlayRoute {
    static func deviceName() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAirPlay else { return nil }
        var name: CFString? = nil
        size = UInt32(MemoryLayout<CFString?>.size)
        addr.mSelector = kAudioObjectPropertyName
        let r = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        guard r == noErr, let n = name.map({ $0 as String }), !n.isEmpty else { return nil }
        return n
    }
}
