import Foundation

// Copied vs transcoded video on the TV (pure parts unit-tested in Tests/CastTranscodeTests.swift).
// Without burn-in the server COPIES an H.264 video into HLS (a remux). Some files' copied segments make the
// Default Media Receiver fail with detailedErrorCode=100 (owner: Samsung S90D, an MKV 720p H.264 that played
// fine every time it was transcoded for a burn-in). So:
//  • a receiver ERROR soon after a LOAD with a copied video → reload with a FORCED video transcode, keeping the
//    Cove-served subtitle side track (CastSubtitles.retry / CastSession.retryAfterError);
//  • that failure is remembered per Cast device + item (UserDefaults, last 200), so the next LOADs of the item
//    (track switches, the next cast) start transcoded at once;
//  • risky sources start transcoded right away: H.264 above level 4.1, High 10 / 4:2:2 / 4:4:4, more than
//    8 bits, or interlaced video.
// Emby only honours "no video copy" through PlaybackInfo with a device profile (as for burn-in); Jellyfin
// takes the parameters on the hand-built master.m3u8.

enum CastVideoMode: Equatable { case copy, transcode }

enum CastTranscode {
    enum Route: Equatable { case playbackInfo, handBuilt }

    nonisolated static func route(isJellyfin: Bool) -> Route { isJellyfin ? .handBuilt : .playbackInfo }

    /// What every Cast device decodes: H.264 + stereo AAC in TS segments.
    nonisolated static let profile = CastProfile.basic

    /// H.264 level as the servers report it (40 = 4.0; some send 4.0) → tenths (40).
    nonisolated static func level10(_ l: Double?) -> Int? {
        guard let l, l > 0 else { return nil }
        return Int((l < 10 ? l * 10 : l).rounded())
    }

    /// The first LOAD's choice from the video stream's facts (nil stream: copy, the server decides).
    nonisolated static func firstMode(_ v: MStream?) -> (mode: CastVideoMode, reason: String?) {
        guard let v else { return (.copy, nil) }
        let codec = (v.Codec ?? "").lowercased()
        if v.IsInterlaced == true { return (.transcode, "interlaced") }
        guard codec == "h264" || codec == "avc" else { return (.copy, nil) }
        let p = (v.Profile ?? "").lowercased()
        if p.contains("10") || p.contains("422") || p.contains("4:2:2") || p.contains("444") || p.contains("4:4:4") {
            return (.transcode, "profile \(v.Profile ?? "?")")
        }
        if let b = v.BitDepth, b > 8 { return (.transcode, "\(b)-bit") }
        if let l = level10(v.Level), l > 41 { return (.transcode, "level \(Double(l) / 10)") }
        return (.copy, nil)
    }

    /// For the log: "h264 High L4.0 8-bit 720p progressive".
    nonisolated static func describe(_ v: MStream?) -> String {
        guard let v else { return "unknown" }
        var parts = [v.Codec ?? "?"]
        if let p = v.Profile, !p.isEmpty { parts.append(p) }
        if let l = level10(v.Level) { parts.append("L\(Double(l) / 10)") }
        parts.append(v.BitDepth.map { "\($0)-bit" } ?? "?-bit")
        if let h = v.Height { parts.append("\(h)p") }
        parts.append(v.IsInterlaced == true ? "interlaced" : (v.IsInterlaced == false ? "progressive" : "scan ?"))
        return parts.joined(separator: " ")
    }

    /// The hand-built master.m3u8 query with the video copy switched off (H.264 High ≤ 4.1, ≤ 1080p, stereo AAC).
    nonisolated static func forceTranscode(_ q: [URLQueryItem]) -> [URLQueryItem] {
        let set: [(String, String)] = [
            ("VideoCodec", "h264"), ("AudioCodec", "aac"), ("MaxAudioChannels", "2"), ("TranscodingMaxAudioChannels", "2"),
            ("SegmentContainer", "ts"), ("AllowVideoStreamCopy", "false"), ("EnableAutoStreamCopy", "false"),
            ("AllowAudioStreamCopy", "false"), ("h264-profile", "high,main,baseline"), ("h264-level", "41"),
            ("MaxWidth", "1920"), ("MaxHeight", "1080"),
        ]
        let names = Set(set.map { $0.0.lowercased() })
        return q.filter { !names.contains($0.name.lowercased()) } + set.map { URLQueryItem(name: $0.0, value: $0.1) }
    }

    /// Emby device profile: no direct play, one H.264 HLS transcode (High ≤ 4.1, ≤ 1080p, 8-bit), stereo AAC,
    /// text subtitles External (Cove serves them; nothing burned in).
    nonisolated static func embyProfile(maxBitrate: Int) -> [String: Any] {
        [
            "Name": "Cove Cast Transcode",
            "MaxStreamingBitrate": maxBitrate,
            "DirectPlayProfiles": [[String: Any]](),
            "TranscodingProfiles": [[
                "Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac",
                "Protocol": "hls", "Context": "Streaming", "BreakOnNonKeyFrames": true,
                "MinSegments": "1", "MaxAudioChannels": "2",
            ]],
            "CodecProfiles": [[
                "Type": "Video", "Codec": "h264",
                "Conditions": [
                    ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "high|main|baseline|constrained baseline", "IsRequired": false],
                    ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "41", "IsRequired": false],
                    ["Condition": "LessThanEqual", "Property": "Height", "Value": "1080", "IsRequired": false],
                    ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": false],
                ],
            ]],
            "SubtitleProfiles": [["Format": "vtt", "Method": "External"], ["Format": "srt", "Method": "External"]],
        ]
    }

    nonisolated static func embyQuery(userId: String, sourceId: String?, audio: Int?, maxBitrate: Int) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "UserId", value: userId)]
        if let s = sourceId { q.append(URLQueryItem(name: "MediaSourceId", value: s)) }
        if let a = audio { q.append(URLQueryItem(name: "AudioStreamIndex", value: String(a))) }
        q += [URLQueryItem(name: "SubtitleStreamIndex", value: "-1"),
              URLQueryItem(name: "MaxStreamingBitrate", value: String(maxBitrate)),
              URLQueryItem(name: "EnableDirectPlay", value: "false"),
              URLQueryItem(name: "EnableDirectStream", value: "false"),
              URLQueryItem(name: "AllowVideoStreamCopy", value: "false"),
              URLQueryItem(name: "AllowAudioStreamCopy", value: "false"),
              URLQueryItem(name: "IsPlayback", value: "true"),
              URLQueryItem(name: "AutoOpenLiveStream", value: "true")]
        return q
    }

    /// A TranscodingUrl that still allows a video copy gets it switched off (and the subtitle left out).
    nonisolated static func noCopy(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var q = c.queryItems ?? []
        for (i, it) in q.enumerated() where ["allowvideostreamcopy", "enableautostreamcopy"].contains(it.name.lowercased()) {
            q[i] = URLQueryItem(name: it.name, value: "false")
        }
        if !q.contains(where: { $0.name.lowercased() == "allowvideostreamcopy" }) {
            q.append(URLQueryItem(name: "AllowVideoStreamCopy", value: "false"))
        }
        c.queryItems = q
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url ?? url
    }
}

/// "The copied video failed on this TV" per Cast device + item, kept across launches (last `cap` entries).
final class CastCopyMemory: @unchecked Sendable {
    static let shared = CastCopyMemory()
    static let key = "castCopyFailed"
    static let cap = 200
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    nonisolated static func entry(device: String, item: String) -> String { "\(device)|\(item)" }

    /// `list` with `e` moved to the end, oldest dropped beyond `cap`.
    nonisolated static func adding(_ e: String, to list: [String], cap: Int = cap) -> [String] {
        var l = list.filter { $0 != e }
        l.append(e)
        return Array(l.suffix(cap))
    }

    var entries: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func failed(device: String, item: String) -> Bool { entries.contains(Self.entry(device: device, item: item)) }

    func markFailed(device: String, item: String) {
        defaults.set(Self.adding(Self.entry(device: device, item: item), to: entries), forKey: Self.key)
    }
}

extension CastSession {
    /// Before the first LOAD of a cast: transcode when this TV failed the item's copy before or the source is risky.
    func chooseVideoMode(device: String) {
        guard let r = request else { return }
        let v = streams.first { ($0.Type ?? "").lowercased() == "video" }
        let remembered = CastCopyMemory.shared.failed(device: device, item: r.itemId)
        let first = CastTranscode.firstMode(v)
        let mode: CastVideoMode = remembered ? .transcode : first.mode
        request?.transcode = mode == .transcode
        let why = remembered ? " (copy failed on this TV before)" : first.reason.map { " (\($0))" } ?? ""
        DebugLog.write("cast: source video \(CastTranscode.describe(v)) → \(mode == .transcode ? "transcode" : "copy")\(why)")
    }
}

extension Emby {
    /// Emby: a forced video transcode via PlaybackInfo (CastTranscode.embyProfile); nil → keep the built URL.
    func castTranscodePlaybackInfo(itemId: String, sourceId: String?, audio: Int?, maxBitrate: Int = 20_000_000) async -> URL? {
        guard var c = URLComponents(string: "\(server)/Items/\(itemId)/PlaybackInfo") else { return nil }
        c.queryItems = CastTranscode.embyQuery(userId: userId, sourceId: sourceId, audio: audio, maxBitrate: maxBitrate)
        guard let pu = c.url else { return nil }
        var r = URLRequest(url: pu)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&r)
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["DeviceProfile": CastTranscode.embyProfile(maxBitrate: maxBitrate)])
        guard let (data, resp) = try? await Net.session.data(for: r),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["MediaSources"] as? [[String: Any]],
              let src = list.first(where: { ($0["Id"] as? String) == sourceId }) ?? list.first,
              let t = src["TranscodingUrl"] as? String else {
            DebugLog.write("cast: transcode via PlaybackInfo: no TranscodingUrl in the reply, keeping the built URL")
            return nil
        }
        if Emby.burnInMayCopyVideo(t) { DebugLog.write("cast: transcode via PlaybackInfo: the URL allowed a video copy → switched off") }
        let ps = j["PlaySessionId"] as? String
        guard let u = Emby.burnInStreamURL(t, server: server, keyName: keyName, token: token, addKey: true, playSessionId: ps) else { return nil }
        return CastTranscode.noCopy(u)
    }
}
