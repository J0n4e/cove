import Foundation

// AirPlay with a text subtitle, without the server's burn-in (owner: Emby's burn-in showed nothing for an external
// SRT and broke the stream for an embedded SUBRIP). Cove serves a tiny HLS master playlist from this Mac
// (CastSubtitleServer's /hls/ routes) that points at the server's own video variants (absolute URLs, with the key)
// and adds a WebVTT SUBTITLES rendition whose segments Cove cuts from the cues it already has. AVPlayer / the AirPlay
// receiver render that rendition on the TV. Picture subtitles stay burned in by the server.
// Pure parts below are unit-tested in Tests/AirPlayLocalHLSTests.swift.

enum AirPlayHLS {
    /// Seconds per WebVTT segment.
    nonisolated static let segmentLength: Double = 60

    /// The TS start PTS (90 kHz) the subtitle segments are mapped to (X-TIMESTAMP-MAP). Emby/Jellyfin segments
    /// usually start at 0; settable with `defaults write <bundle> airPlaySubsMpegts <ticks>` if cues are off.
    nonisolated static var mpegts: Int {
        UserDefaults.standard.object(forKey: "airPlaySubsMpegts") as? Int ?? 0
    }

    enum Choice: Equatable { case none, localHLS, burnIn }

    /// The AirPlay path for a subtitle (pure): text → Cove's local HLS with a WebVTT rendition, picture → server
    /// burn-in, nothing when no track / not on AirPlay. `failedBefore`: the local playlist didn't load once for
    /// this film, so burn-in. `directPlay`: the stream is the file itself (no HLS to wrap).
    nonisolated static func choice(airPlay: Bool, hasSub: Bool, image: Bool, directPlay: Bool, failedBefore: Bool) -> Choice {
        guard airPlay, hasSub else { return .none }
        if image || directPlay || failedBefore { return .burnIn }
        return .localHLS
    }

    /// The key query items the server's own URLs carry (copied onto variant URIs).
    nonisolated static let keyNames: Set<String> = ["api_key", "apikey", "x-emby-token", "x-mediabrowser-token"]

    /// A server URI made absolute against `base`, with the key from `base` appended when it is the same origin
    /// and has none.
    nonisolated static func absolute(_ uri: String, base: URL) -> String {
        guard let u = URL(string: uri, relativeTo: base)?.absoluteURL else { return uri }
        guard u.scheme == base.scheme, u.host == base.host, u.port == base.port,
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u.absoluteString }
        let have = (c.queryItems ?? []).contains { keyNames.contains($0.name.lowercased()) }
        let key = URLComponents(url: base, resolvingAgainstBaseURL: false)?.queryItems?
            .first { keyNames.contains($0.name.lowercased()) }
        if !have, let key { c.queryItems = (c.queryItems ?? []) + [key] }
        return c.url?.absoluteString ?? u.absoluteString
    }

    /// Quotes for an HLS attribute value.
    nonisolated static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// Sets (or replaces) attribute `name` in an `#EXT-X-…:` tag line.
    nonisolated static func setAttr(_ line: String, _ name: String, _ value: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line + ":\(name)=\(value)" }
        let tag = line[..<colon], attrs = splitAttrs(String(line[line.index(after: colon)...]))
        var out = attrs.filter { !$0.hasPrefix(name + "=") }
        out.append("\(name)=\(value)")
        return String(tag) + ":" + out.joined(separator: ",")
    }

    /// Splits an attribute list at commas outside quotes.
    nonisolated static func splitAttrs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in s {
            if ch == "\"" { q.toggle() }
            if ch == ",", !q { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    nonisolated static func attr(_ line: String, _ name: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        for a in splitAttrs(String(line[line.index(after: colon)...])) where a.hasPrefix(name + "=") {
            return String(a.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// The local master: the server's variants (absolute, keyed) with SUBTITLES="subs" and Cove's WebVTT rendition.
    /// The server's own subtitle renditions are dropped. nil: not a master playlist (no EXT-X-STREAM-INF).
    nonisolated static func master(_ server: String, serverURL: URL, subsURI: String, name: String, lang: String?) -> String? {
        let lines = server.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }
        var media = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\(quoted(name.isEmpty ? "Subtitles" : name))"
        if let lang, !lang.isEmpty { media += ",LANGUAGE=\(quoted(lang))" }
        media += ",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\(quoted(subsURI))"
        var out = ["#EXTM3U"], inserted = false, nextIsURI = false
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l == "#EXTM3U" { continue }
            if nextIsURI, !l.hasPrefix("#") { out.append(absolute(l, base: serverURL)); nextIsURI = false; continue }
            if l.hasPrefix("#EXT-X-MEDIA:") {
                if attr(l, "TYPE") == "SUBTITLES" { continue }
                if let u = attr(l, "URI") { out.append(setAttr(l, "URI", quoted(absolute(u, base: serverURL)))) } else { out.append(l) }
                continue
            }
            if l.hasPrefix("#EXT-X-STREAM-INF") {
                if !inserted { out.append(media); inserted = true }
                out.append(setAttr(l, "SUBTITLES", "\"subs\"")); nextIsURI = true; continue
            }
            if l.hasPrefix("#EXT-X-I-FRAME-STREAM-INF"), let u = attr(l, "URI") {
                out.append(setAttr(l, "URI", quoted(absolute(u, base: serverURL)))); continue
            }
            out.append(l)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The first variant's URI in a master playlist (to read the film's length from it).
    nonisolated static func firstVariant(_ master: String) -> String? {
        let lines = master.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }
        return lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }?
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sum of a media playlist's EXTINF durations.
    nonisolated static func totalDuration(_ media: String) -> Double {
        media.components(separatedBy: "\n").reduce(0) { s, l in
            guard l.hasPrefix("#EXTINF:") else { return s }
            return s + (Double(l.dropFirst(8).split(separator: ",").first.map(String.init) ?? "") ?? 0)
        }
    }

    nonisolated static func segmentCount(duration: Double, length: Double = segmentLength) -> Int {
        max(1, Int((max(0, duration) / length).rounded(.up)))
    }

    /// The subtitle media playlist: fixed-length WebVTT segments up to `duration` (the last one shorter).
    nonisolated static func subsPlaylist(duration: Double, length: Double = segmentLength, uri: (Int) -> String) -> String {
        let n = segmentCount(duration: duration, length: length)
        var out = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:\(Int(length.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for i in 0..<n {
            let d = i == n - 1 && duration > 0 ? max(0.001, duration - Double(i) * length) : length
            out += "#EXTINF:\(String(format: "%.3f", d)),\n\(uri(i))\n"
        }
        return out + "#EXT-X-ENDLIST\n"
    }

    /// WebVTT segment `i`: the cues overlapping its window (times absolute from the film's start, `offsetMs` as the
    /// player's subtitle offset), with the X-TIMESTAMP-MAP header.
    nonisolated static func segment(_ cues: [Cue], index i: Int, length: Double = segmentLength, mpegts: Int = 0, offsetMs: Int = 0) -> String {
        let a = Double(i) * length, b = a + length, off = Double(offsetMs) / 1000
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(mpegts),LOCAL:00:00:00.000\n\n"
        for c in cues {
            let s = c.start + off, e = c.end + off
            guard e > s, e > a, s < b, e > 0 else { continue }
            let text = CastVTT.clean(c.text)
            guard !text.isEmpty else { continue }
            out += "\(CastVTT.stamp(s)) --> \(CastVTT.stamp(e))\n\(text)\n\n"
        }
        return out
    }

    /// The routes under /hls/<token>/ (path without query) → (content type, body); nil: not ours.
    nonisolated static func route(_ path: String, token: String, master: String, subs: String, segment: (Int) -> String?) -> (String, String)? {
        guard !token.isEmpty else { return nil }
        let p = "/hls/\(token)/"
        guard path.hasPrefix(p) else { return nil }
        let rest = String(path.dropFirst(p.count))
        let m3u8 = "application/vnd.apple.mpegurl"
        if rest == "master.m3u8" { return (m3u8, master) }
        if rest == "subs.m3u8" { return (m3u8, subs) }
        if rest.hasPrefix("sub_"), rest.hasSuffix(".vtt"), let i = Int(rest.dropFirst(4).dropLast(4)), let s = segment(i) {
            return ("text/vtt; charset=utf-8", s)
        }
        return nil
    }

    /// What the log names a fetch ("master", "subs", "segment 3").
    nonisolated static func fetchName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last == "master.m3u8" { return "master" }
        if last == "subs.m3u8" { return "subs" }
        if last.hasPrefix("sub_") { return "segment \(last.dropFirst(4).dropLast(4))" }
        return last
    }
}
