import Foundation

/// The real play method of a stream, as Emby/Jellyfin count it (PlayState.PlayMethod, Playback Reporting):
/// - DirectPlay: the file itself is streamed (Static=true).
/// - DirectStream: HLS where the server copies both video and audio (a remux, e.g. MKV → HLS).
/// - Transcode: the server re-encodes the video or the audio.
enum PlayMethod {
    static let directPlay = "DirectPlay", directStream = "DirectStream", transcode = "Transcode"

    /// Reasons that only concern the container: the server still copies the streams.
    static let containerOnlyReasons: Set<String> = ["ContainerNotSupported", "ContainerBitrateExceedsLimit"]

    /// Reasons about the subtitle only: they force a conversion only when the track is burned in (Encode).
    static let subtitleOnlyReasons: Set<String> = ["SubtitleCodecNotSupported", "SubtitleFormatNotSupported"]

    private static func query(_ url: String) -> [String: String] {
        var out: [String: String] = [:]
        for q in URLComponents(string: url)?.queryItems ?? [] { out[q.name.lowercased()] = q.value ?? "" }
        return out
    }

    /// First guess from the stream URL alone (used for the start report, corrected once the server says).
    /// A URL that forces a re-encode (no video copy, burned-in subtitle) or whose TranscodeReasons name a
    /// codec/stream problem is a Transcode; any other HLS URL is taken as a Direct Stream.
    /// `sourceAudio`: the codec of the audio track played; when it isn't among the URL's AudioCodec list
    /// (DTS/TrueHD) the server converts it, so it's a Transcode.
    static func guess(url: String, sourceAudio: String? = nil) -> String {
        if url.contains("Static=true") { return directPlay }
        let q = query(url)
        if q["allowvideostreamcopy"]?.lowercased() == "false" { return transcode }
        if q["allowaudiostreamcopy"]?.lowercased() == "false" { return transcode }
        if q["subtitlemethod"]?.lowercased() == "encode", !(q["subtitlestreamindex"] ?? "").isEmpty { return transcode }
        if let a = sourceAudio?.lowercased(), !a.isEmpty, let list = q["audiocodec"], !list.isEmpty {
            let allowed = Set(list.lowercased().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            if !allowed.contains(a) { return transcode }
        }
        let burnIn = q["subtitlemethod"]?.lowercased() == "encode"
        let reasons = (q["transcodereasons"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if reasons.contains(where: { !containerOnlyReasons.contains($0) && (burnIn || !subtitleOnlyReasons.contains($0)) }) {
            return transcode
        }
        return directStream
    }

    /// The method from the server's session TranscodingInfo (`GET /Sessions?DeviceId=…`). Nil info on an HLS
    /// stream (the server hasn't started yet): keep the URL guess.
    static func classify(url: String, transcodingInfo t: [String: Any]?, sourceAudio: String? = nil) -> String {
        if url.contains("Static=true") { return directPlay }
        guard let t, !t.isEmpty else { return guess(url: url, sourceAudio: sourceAudio) }
        let v = t["IsVideoDirect"] as? Bool, a = t["IsAudioDirect"] as? Bool
        guard v != nil || a != nil else { return guess(url: url, sourceAudio: sourceAudio) }
        // A stream without audio has nothing to convert there (IsAudioDirect may be missing)
        return (v ?? false) && (a ?? true) ? directStream : transcode
    }

    static func reasons(_ t: [String: Any]?) -> [String] {
        if let r = t?["TranscodeReasons"] as? [String] { return r }
        if let s = t?["TranscodeReasons"] as? String { return s.split(separator: ",").map(String.init) }
        return []
    }

    /// The overlay text: "Direct play" / "Direct stream (container: mkv → hls)" /
    /// "Transcode (video: hevc→h264, audio: dts→eac3; reason: AudioCodecNotSupported)".
    static func describe(_ method: String, container: String?, sourceVideo: String?, sourceAudio: String?,
                         transcodingInfo t: [String: Any]?) -> String {
        switch method {
        case directPlay: return "Direct play"
        case directStream:
            let c = (container ?? "").lowercased().split(separator: ",").first.map(String.init) ?? ""
            return c.isEmpty ? "Direct stream (remux → hls)" : "Direct stream (container: \(c) → hls)"
        default:
            var parts: [String] = []
            if let t {
                func lc(_ s: String?) -> String { (s ?? "?").lowercased() }
                if t["IsVideoDirect"] as? Bool == false {
                    parts.append("video: \(lc(sourceVideo))→\(lc(t["VideoCodec"] as? String))")
                }
                if t["IsAudioDirect"] as? Bool == false {
                    parts.append("audio: \(lc(sourceAudio))→\(lc(t["AudioCodec"] as? String))")
                }
            }
            var s = parts.joined(separator: ", ")
            let r = reasons(t)
            if !r.isEmpty { s += (s.isEmpty ? "" : "; ") + "reason: " + r.joined(separator: ", ") }
            return s.isEmpty ? "Transcode" : "Transcode (\(s))"
        }
    }
}
