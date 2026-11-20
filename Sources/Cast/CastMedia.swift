import Foundation

// Pure Cast logic (no network, no UI), unit-tested in Tests/CastTests.swift: device TXT records, the codec profile
// per device model, the server stream URL the TV fetches, the LOAD request and the receiver's status replies.

/// A Cast device found on the network (Bonjour `_googlecast._tcp`).
struct CastDevice: Identifiable, Equatable, Hashable {
    /// The TXT `id` (stable across restarts); the Bonjour name when missing.
    let id: String
    let name: String
    let model: String
    /// Bonjour service name, used to connect (NWEndpoint.service).
    let service: String
    let domain: String

    /// Builds a device from its TXT record (fn = friendly name, md = model, id = device id).
    static func from(txt: [String: String], service: String, domain: String = "local.") -> CastDevice {
        func v(_ k: String) -> String? { txt[k].flatMap { $0.isEmpty ? nil : $0 } }
        // Bonjour names look like "Chromecast-Ultra-1a2b…": a readable fallback without the hash
        let fallback = service.split(separator: "-").dropLast().joined(separator: " ")
        return CastDevice(id: v("id") ?? service, name: v("fn") ?? (fallback.isEmpty ? service : fallback),
                          model: v("md") ?? "Cast device", service: service, domain: domain)
    }

    /// What the device can decode, guessed from its model name. Unknown models get the safe profile
    /// (every Cast device plays H.264 + AAC); the server converts the rest.
    var profile: CastProfile { CastProfile.forModel(model) }
}

struct CastProfile: Equatable {
    var hevc: Bool
    var surround: Bool   // AC3 / EAC3 pass-through

    static let basic = CastProfile(hevc: false, surround: false)

    static func forModel(_ md: String) -> CastProfile {
        let m = md.lowercased()
        let modern = m.contains("google tv") || m.contains("ultra") || m.contains("4k")
        return CastProfile(hevc: modern, surround: modern)
    }

    var videoCodecs: String { hevc ? "h264,hevc" : "h264" }
    var audioCodecs: String { surround ? "aac,ac3,eac3" : "aac" }
    var maxAudioChannels: Int { surround ? 6 : 2 }
    /// HEVC in HLS needs fMP4 segments.
    var segmentContainer: String { hevc ? "mp4" : "ts" }
}

enum CastError: Error, Equatable {
    case localServer
    case badServer

    var message: String {
        switch self {
        case .localServer: return "The TV can't reach the server at localhost. Sign in to the server with its network address (for example http://192.168.1.10:8096) to cast."
        case .badServer: return "Cove couldn't build a link to this video for the TV."
        }
    }
}

/// What to play on the TV.
struct CastRequest: Equatable {
    let itemId: String
    var sourceId: String?
    var audio: Int?
    /// The chosen subtitle track; with `subIsImage` it is burned in, else Cove serves it as a WebVTT side track.
    var sub: Int?
    var subIsImage = false
    var start: Double = 0
}

enum CastStream {
    static let receiverAppId = "CC1AD845"   // Google's Default Media Receiver

    /// True when the TV can't reach this address (it would ask itself).
    static func isLocalOnly(_ server: String) -> Bool {
        guard let h = URL(string: server)?.host?.lowercased() else { return true }
        return h == "localhost" || h == "::1" || h == "[::1]" || h.hasPrefix("127.") || h == "0.0.0.0" || h.hasSuffix(".localhost")
    }

    /// The server's HLS stream for the TV. `keyName`: api_key (Emby) / ApiKey (Jellyfin).
    static func url(server: String, token: String, keyName: String, deviceId: String, playSessionId: String,
                    req: CastRequest, profile: CastProfile) -> Result<URL, CastError> {
        if isLocalOnly(server) { return .failure(.localServer) }
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard var c = URLComponents(string: "\(base)/Videos/\(req.itemId)/master.m3u8") else { return .failure(.badServer) }
        var q: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: req.sourceId ?? req.itemId),
            .init(name: "DeviceId", value: deviceId),
            .init(name: "PlaySessionId", value: playSessionId),
            .init(name: "VideoCodec", value: profile.videoCodecs),
            .init(name: "AudioCodec", value: profile.audioCodecs),
            .init(name: "MaxAudioChannels", value: String(profile.maxAudioChannels)),
            .init(name: "TranscodingMaxAudioChannels", value: String(profile.maxAudioChannels)),
            .init(name: "SegmentContainer", value: profile.segmentContainer),
            .init(name: "BreakOnNonKeyFrames", value: "True"),
            .init(name: "AllowVideoStreamCopy", value: "true"),
            .init(name: "AllowAudioStreamCopy", value: "true"),
            .init(name: "MaxStreamingBitrate", value: "40000000"),
        ]
        if let a = req.audio { q.append(.init(name: "AudioStreamIndex", value: String(a))) }
        if let s = req.sub, req.subIsImage {
            q.append(.init(name: "SubtitleStreamIndex", value: String(s)))
            q.append(.init(name: "SubtitleMethod", value: "Encode"))
        }
        q.append(.init(name: keyName, value: token))
        c.queryItems = q
        if req.sub != nil, req.subIsImage, let s = c.string, let f = URLComponents(string: Emby.forBurnIn(s)) { c = f }
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let u = c.url else { return .failure(.badServer) }
        return .success(u)
    }

    /// A text subtitle as WebVTT (the server converts SRT/ASS/embedded tracks).
    static func subtitleURL(server: String, token: String, keyName: String, itemId: String, sourceId: String, index: Int) -> URL? {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        return URL(string: "\(base)/Videos/\(itemId)/\(sourceId)/Subtitles/\(index)/Stream.vtt?\(keyName)=\(token)")
    }

    static func imageURL(server: String, token: String, keyName: String, id: String, kind: String, width: Int = 800) -> URL? {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        return URL(string: "\(base)/Items/\(id)/Images/\(kind)?maxWidth=\(width)&quality=85&\(keyName)=\(token)")
    }
}

/// Text shown on the TV and in the remote.
struct CastMeta: Equatable {
    var title: String
    var seriesTitle: String?
    var season: Int?
    var episode: Int?
    var images: [URL] = []
    var duration: Double?
}

enum CastLoad {
    static let subtitleTrackId = 1

    /// The media namespace LOAD request body.
    static func body(url: URL, hls: Bool, meta: CastMeta, start: Double, subtitle: (url: URL, name: String, lang: String?)?,
                     hevc: Bool, requestId: Int, textStyle: [String: Any]? = nil) -> [String: Any] {
        var md: [String: Any] = ["title": meta.title,
                                 "images": meta.images.map { ["url": $0.absoluteString] }]
        if let s = meta.seriesTitle {
            md["metadataType"] = 2   // TV_SHOW
            md["seriesTitle"] = s
            if let n = meta.season { md["season"] = n }
            if let n = meta.episode { md["episode"] = n }
        } else {
            md["metadataType"] = 1   // MOVIE
        }
        var media: [String: Any] = ["contentId": url.absoluteString, "contentUrl": url.absoluteString,
                                    "contentType": hls ? "application/x-mpegURL" : "video/mp4",
                                    "streamType": "BUFFERED", "metadata": md]
        if hls {
            media["hlsSegmentFormat"] = hevc ? "fmp4" : "ts"
            media["hlsVideoSegmentFormat"] = hevc ? "fmp4" : "mpeg2_ts"
        }
        if let d = meta.duration, d > 0 { media["duration"] = d }
        var b: [String: Any] = ["type": "LOAD", "requestId": requestId, "media": media,
                                "autoplay": true, "currentTime": max(0, start)]
        if let s = subtitle {
            var t: [String: Any] = ["trackId": subtitleTrackId, "type": "TEXT", "subtype": "SUBTITLES",
                                    "trackContentId": s.url.absoluteString, "trackContentType": "text/vtt", "name": s.name]
            if let l = s.lang { t["language"] = l }
            media["tracks"] = [t]
            media["textTrackStyle"] = textStyle ?? ["backgroundColor": "#00000000", "edgeType": "DROP_SHADOW", "edgeColor": "#000000FF",
                                                    "foregroundColor": "#FFFFFFFF", "fontScale": 1.0]
            b["media"] = media
            b["activeTrackIds"] = [subtitleTrackId]
        }
        return b
    }
}

/// The parts of the receiver's replies Cove uses.
struct CastMediaStatus: Equatable {
    var mediaSessionId: Int
    var playerState: String      // IDLE | PLAYING | PAUSED | BUFFERING
    var currentTime: Double
    var idleReason: String?      // FINISHED | CANCELLED | INTERRUPTED | ERROR
    var duration: Double?
    var volume: Double?
    /// The loaded stream's URL (carries our PlaySessionId): tells our media from another sender's after a reconnect
    var contentId: String? = nil

    /// From a MEDIA_STATUS payload; nil when it carries no session (nothing loaded).
    static func parse(_ j: [String: Any]) -> CastMediaStatus? {
        guard (j["type"] as? String) == "MEDIA_STATUS", let s = (j["status"] as? [[String: Any]])?.first,
              let id = (s["mediaSessionId"] as? NSNumber)?.intValue else { return nil }
        let media = s["media"] as? [String: Any]
        return CastMediaStatus(mediaSessionId: id, playerState: s["playerState"] as? String ?? "IDLE",
                               currentTime: (s["currentTime"] as? NSNumber)?.doubleValue ?? 0,
                               idleReason: s["idleReason"] as? String,
                               duration: (media?["duration"] as? NSNumber)?.doubleValue,
                               volume: ((s["volume"] as? [String: Any])?["level"] as? NSNumber)?.doubleValue,
                               contentId: media?["contentId"] as? String)
    }
}

struct CastReceiverStatus: Equatable {
    var transportId: String?     // our app's, when it runs
    var sessionId: String?
    var otherApp: String?        // something else runs (YouTube…)
    var volume: Double?
    var muted: Bool?

    static func parse(_ j: [String: Any], appId: String = CastStream.receiverAppId) -> CastReceiverStatus? {
        guard (j["type"] as? String) == "RECEIVER_STATUS", let s = j["status"] as? [String: Any] else { return nil }
        let apps = s["applications"] as? [[String: Any]] ?? []
        let ours = apps.first { ($0["appId"] as? String) == appId }
        let vol = s["volume"] as? [String: Any]
        return CastReceiverStatus(transportId: ours?["transportId"] as? String, sessionId: ours?["sessionId"] as? String,
                                  otherApp: ours == nil ? apps.first?["displayName"] as? String : nil,
                                  volume: (vol?["level"] as? NSNumber)?.doubleValue, muted: vol?["muted"] as? Bool)
    }
}
