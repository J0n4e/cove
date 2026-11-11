import Foundation
import Network

// Picture in picture shows only the video, not the subtitles the app draws over it, and the server will neither burn
// a subtitle in nor send it as a track for this stream. So for PiP the app serves the stream's playlist itself, from
// a tiny web server on this Mac, with one addition: a WebVTT subtitle track made from the subtitle lines the app
// already has. macOS draws that track itself, also in the PiP window. Video and audio still come from the server.

final class PiPSubtitleServer {
    static let shared = PiPSubtitleServer()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var files: [String: (Data, String)] = [:]   // path → (body, content type)
    private let queue = DispatchQueue(label: "cove.pipsubs")

    /// The stream's master playlist with the subtitle track added, served locally; nil if anything fails.
    /// macOS shows a track like this about 1.5 s later than the app draws the same lines (the stream's own
    /// timestamps start a little after zero), so the lines move this much earlier.
    static let lead: Double = 1.5

    /// `shift`: seconds to move every line (the user's subtitle offset; positive = later).
    func playlist(for master: URL, cues: [Cue], duration: Double, shift: Double = 0) async -> URL? {
        guard let (data, _) = try? await Net.session.data(from: master),
              let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U"),
              let p = await start() else { return nil }
        let len = max(duration, (cues.last?.end ?? 0) + 10)
        let vtt = "WEBVTT\n\n" + cues.enumerated().map { i, c in
            "\(i + 1)\n\(Self.ts(c.start + shift - Self.lead)) --> \(Self.ts(c.end + shift - Self.lead))\n\(c.text)\n"
        }.joined(separator: "\n")
        let subsList = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(len.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", len)),
        subs.vtt
        #EXT-X-ENDLIST

        """
        // Every address in the server's playlist made absolute (it is now loaded from here), and the subtitle
        // group added to the stream
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var l = raw
            if l.hasPrefix("#EXT-X-STREAM-INF") { l += ",SUBTITLES=\"cove\"" }
            else if !l.isEmpty && !l.hasPrefix("#") { l = URL(string: l, relativeTo: master)?.absoluteString ?? l }
            else if let r = l.range(of: "URI=\""), let end = l[r.upperBound...].firstIndex(of: "\"") {
                let uri = String(l[r.upperBound..<end])
                l.replaceSubrange(r.upperBound..<end, with: URL(string: uri, relativeTo: master)?.absoluteString ?? uri)
            }
            lines.append(l)
            if l.hasPrefix("#EXTM3U") {
                lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"cove\",NAME=\"Cove\",LANGUAGE=\"und\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"subs.m3u8\"")
            }
        }
        let id = UUID().uuidString.prefix(8)
        queue.sync {
            files = ["/\(id)/master.m3u8": (Data(lines.joined(separator: "\n").utf8), "application/vnd.apple.mpegurl"),
                     "/\(id)/subs.m3u8": (Data(subsList.utf8), "application/vnd.apple.mpegurl"),
                     "/\(id)/subs.vtt": (Data(vtt.utf8), "text/vtt")]
        }
        return URL(string: "http://127.0.0.1:\(p)/\(id)/master.m3u8")
    }

    /// "00:01:02.345"
    private static func ts(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Starts the local server once (this Mac only), returns its port.
    private func start() async -> UInt16? {
        if listener != nil, port != 0 { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        return await withCheckedContinuation { cont in
            var done = false
            l.stateUpdateHandler = { [weak self] s in
                guard !done else { return }
                switch s {
                case .ready: done = true; self?.port = l.port?.rawValue ?? 0; cont.resume(returning: self?.port)
                case .failed, .cancelled: done = true; self?.listener = nil; cont.resume(returning: nil)
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.components(separatedBy: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
            let found = self.files[path]
            let body = found?.0 ?? Data()
            let head = "HTTP/1.1 \(found == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(found?.1 ?? "text/plain")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
