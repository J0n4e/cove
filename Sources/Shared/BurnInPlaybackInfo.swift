import Foundation

// Subtitle burn-in the way Emby's own clients ask for it. Emby 4.10 ignores hand-built burn-in parameters on
// master.m3u8 (SubtitleMethod=Encode, AllowVideoStreamCopy=false): it copies the h264 video and the subtitle never
// appears (owner: Cast showed no subtitles, AirPlay's server session ran at 2083 fps = a video copy). It only burns
// in when PlaybackInfo is told by the device profile that the subtitle can't be played any other way; the
// TranscodingUrl it returns then carries the server's own subtitle/encode parameters.
//
// Jellyfin keeps the hand-built URL: its DynamicHls honours SubtitleMethod=Encode on master.m3u8 (proven in use).
// The Mac player's PlaybackInfo call uses this profile on both servers (it already went through PlaybackInfo).

extension Emby {
    enum BurnInRoute: Equatable { case playbackInfo, handBuilt }

    /// Cast / AirPlay burn-in: Emby needs PlaybackInfo, Jellyfin's hand-built master.m3u8 works.
    nonisolated static func burnInRoute(isJellyfin: Bool) -> BurnInRoute { isJellyfin ? .handBuilt : .playbackInfo }

    /// Every subtitle format, offered ONLY as Encode (no Hls/External/Embed), so the server has to burn it in.
    nonisolated static let burnInSubtitleFormats = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "pgs", "pgssub",
                                                    "dvdsub", "dvbsub", "vobsub", "sub", "smi", "ttml", "mov_text"]

    nonisolated static func burnInSubtitleProfiles() -> [[String: Any]] {
        burnInSubtitleFormats.map { ["Format": $0, "Method": "Encode"] }
    }

    /// The device profile for a burn-in: no direct play, one H.264 HLS transcoding profile, Encode-only subtitles.
    /// `audioCodecs`: "aac" for a basic Cast device, "aac,ac3,eac3" for AirPlay / surround Cast.
    nonisolated static func burnInProfile(name: String, audioCodecs: String, maxBitrate: Int,
                                          maxAudioChannels: Int = 6) -> [String: Any] {
        [
            "Name": name,
            "MaxStreamingBitrate": maxBitrate,
            "DirectPlayProfiles": [[String: Any]](),
            "TranscodingProfiles": [[
                "Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": audioCodecs,
                "Protocol": "hls", "Context": "Streaming", "BreakOnNonKeyFrames": true,
                "MinSegments": "1", "MaxAudioChannels": String(maxAudioChannels),
            ]],
            "SubtitleProfiles": burnInSubtitleProfiles(),
        ]
    }

    /// The PlaybackInfo query of a burn-in.
    nonisolated static func burnInQuery(userId: String, sourceId: String?, sub: Int, audio: Int?, start: Double?,
                                        maxBitrate: Int) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "UserId", value: userId)]
        if let s = sourceId { q.append(URLQueryItem(name: "MediaSourceId", value: s)) }
        q.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(sub)))
        if let a = audio { q.append(URLQueryItem(name: "AudioStreamIndex", value: String(a))) }
        if let t = start, t > 0 { q.append(URLQueryItem(name: "StartTimeTicks", value: String(Int64(t * 10_000_000)))) }
        q += [URLQueryItem(name: "MaxStreamingBitrate", value: String(maxBitrate)),
              URLQueryItem(name: "EnableDirectPlay", value: "false"),
              URLQueryItem(name: "EnableDirectStream", value: "false"),
              URLQueryItem(name: "AllowVideoStreamCopy", value: "false"),
              URLQueryItem(name: "AllowAudioStreamCopy", value: "true"),
              URLQueryItem(name: "IsPlayback", value: "true"),
              URLQueryItem(name: "AutoOpenLiveStream", value: "true")]
        return q
    }

    /// The returned TranscodingUrl as an absolute URL. The key is added only for our own server and only when
    /// `addKey` (Cast: the TV fetches it without our headers) and the URL has none. A missing PlaySessionId is
    /// filled from the reply so reports and the stop reach the server's transcode.
    nonisolated static func burnInStreamURL(_ transcodingUrl: String, server: String, keyName: String, token: String,
                                            addKey: Bool, playSessionId: String?) -> URL? {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        let s = transcodingUrl.hasPrefix("http") ? transcodingUrl
            : base + (transcodingUrl.hasPrefix("/") ? transcodingUrl : "/" + transcodingUrl)
        guard var c = URLComponents(string: s) else { return nil }
        var q = c.queryItems ?? []
        let names = Set(q.map { $0.name.lowercased() })
        if let ps = playSessionId, !ps.isEmpty, !names.contains("playsessionid") {
            q.append(URLQueryItem(name: "PlaySessionId", value: ps))
        }
        let ours = URL(string: s).flatMap { u in URL(string: base).map { sameOriginStatic(u, $0) } } ?? false
        if addKey, ours, !names.contains("api_key"), !names.contains("apikey") {
            q.append(URLQueryItem(name: keyName, value: token))
        }
        c.queryItems = q
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    private nonisolated static func sameOriginStatic(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }

    /// The log line for a burn-in TranscodingUrl (never the token).
    nonisolated static func burnInInfoLog(_ url: String) -> String {
        var q: [String: String] = [:]
        for i in URLComponents(string: url)?.queryItems ?? [] { q[i.name.lowercased()] = i.value ?? "" }
        let enc = q["subtitlemethod"]?.lowercased() == "encode" ? "yes" : "no"
        var line = "burn-in via PlaybackInfo: TranscodingUrl has SubtitleMethod=Encode=\(enc), TranscodeReasons=\(q["transcodereasons"] ?? "none")"
        if burnInMayCopyVideo(url) { line += " — WARNING: the URL still allows a video copy, subtitles may be missing" }
        return line
    }

    /// The URL lets the server copy the video (no burn-in possible).
    nonisolated static func burnInMayCopyVideo(_ url: String) -> Bool {
        let q = URLComponents(string: url)?.queryItems ?? []
        return q.first { $0.name.lowercased() == "allowvideostreamcopy" }?.value?.lowercased() == "true"
    }

    /// Asks the server for a burned-in stream (see the top of the file). Nil when the server gives no
    /// TranscodingUrl; the caller keeps its old URL then.
    func burnInPlaybackInfo(itemId: String, sourceId: String?, sub: Int, audio: Int?, start: Double?,
                            maxBitrate: Int, audioCodecs: String, addKey: Bool) async -> (url: URL, playSessionId: String?)? {
        guard var c = URLComponents(string: "\(server)/Items/\(itemId)/PlaybackInfo") else { return nil }
        c.queryItems = Self.burnInQuery(userId: userId, sourceId: sourceId, sub: sub, audio: audio, start: start, maxBitrate: maxBitrate)
        guard let pu = c.url else { return nil }
        var r = URLRequest(url: pu)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&r)
        let profile = Self.burnInProfile(name: "Cove Burn-in", audioCodecs: audioCodecs, maxBitrate: maxBitrate)
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["DeviceProfile": profile])
        guard let (data, resp) = try? await Net.session.data(for: r),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["MediaSources"] as? [[String: Any]],
              let src = list.first(where: { ($0["Id"] as? String) == sourceId }) ?? list.first,
              let t = src["TranscodingUrl"] as? String else {
            DebugLog.write("burn-in via PlaybackInfo: no TranscodingUrl in the reply, keeping the built URL")
            return nil
        }
        DebugLog.write(Self.burnInInfoLog(t))
        let ps = j["PlaySessionId"] as? String
        guard let u = Self.burnInStreamURL(t, server: server, keyName: keyName, token: token, addKey: addKey, playSessionId: ps) else { return nil }
        return (u, ps)
    }
}
