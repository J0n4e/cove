import Foundation

// The subtitle offset while casting. Cove serves text subtitles to the TV itself (CastSubtitleServer.swift), so the
// player's offset is applied by shifting every cue of the served WebVTT (CastVTT.shift, tested in
// Tests/CastSubOffsetTests.swift). Changing it during a cast re-serves the shifted track at a new link and reloads
// at the current position (the Default Media Receiver keeps a side track's text once loaded). Burned-in (picture)
// subtitles are drawn into the video by the server and can't be moved: the remote's menu says so instead.

enum CastSubOffset {
    nonisolated static let step = 100
    nonisolated static let burnedInHint = "Burned-in subtitles can't be shifted"

    /// "+0.3 s" / "−1.2 s" / "No offset" for the remote's menu.
    nonisolated static func label(_ ms: Int) -> String {
        guard ms != 0 else { return "No offset" }
        let s = String(format: "%.1f", Double(abs(ms)) / 1000)
        return (ms > 0 ? "+" : "\u{2212}") + s + " s"
    }

    /// Whether the offset can be changed for the current subtitle (only a served text track).
    nonisolated static func adjustable(hasSub: Bool, isImage: Bool) -> Bool { hasSub && !isImage }
}

extension CastSession {
    var subIsBurnedIn: Bool { request?.sub != nil && request?.subIsImage == true }

    /// New offset (ms): re-serves the shifted track and reloads at the current position, after a short pause so
    /// several clicks make one reload.
    func setSubOffset(_ ms: Int) {
        subOffset = ms
        guard let cues = subCues, request?.sub != nil, request?.subIsImage == false, transportId != nil else { return }
        offsetTask?.cancel()
        offsetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.subOffset == ms, self.subCues != nil else { return }
            self.subVTT = CastVTT.make(cues, offsetMs: ms)
            self.subURL = nil   // sendLoad publishes the new VTT at a fresh link
            DebugLog.write("cast: subtitle offset \(ms) ms → re-serving the track")
            self.request?.start = self.time
            self.reload { _ in }
        }
    }
}
