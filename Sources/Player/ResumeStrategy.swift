import Foundation

/// How a resume (start part-way through the file) gets its stream.
///
/// Before, a resume asked the server to re-encode the video (AllowVideoStreamCopy=false): a copied video can only
/// be cut at keyframes, and the fear was that the stream would begin a few seconds before the position the player
/// assumes, putting subtitles out of sync. But Cove never sends StartTimeTicks: it loads the server's whole-file
/// HLS playlist and seeks the AVPlayerItem to the resume point before playback. The segments carry the source
/// timestamps, so the player's clock is the real media time whether the video is copied or converted; in-stream
/// WebVTT is timed by the player, and downloaded/external cues and progress reports use `now`, the same clock.
/// That holds for the picture and audio, but not for subtitles Cove draws itself (external files and extracted
/// cues): with copied video Emby restarts its remux at the seek point snapped to a keyframe while the playlist
/// claims the requested time, so the picture runs up to a GOP off the clock the cues use. So a mid-file start
/// re-encodes (exact timeline, as before) when a Cove-drawn text subtitle is on, and copies otherwise.
/// In-stream (HLS WebVTT) subtitles are timed by the player with the segments and don't need it.
enum ResumeStrategy {
    static let name = "whole-file playlist + seek"

    /// Whether the server must re-encode the video (AllowVideoStreamCopy=false). `coveDrawnSub`: an external or
    /// extracted text subtitle drawn by Cove is on (not in-stream, not burned in).
    static func reencode(resuming: Bool, forceTranscode: Bool, coveDrawnSub: Bool = false) -> Bool {
        forceTranscode || (resuming && coveDrawnSub)
    }

    enum SubSwitch: Equatable { case loadCues, restartReencode }

    /// Turning a Cove-drawn subtitle on during playback: just load its cues, unless the running stream copies the
    /// video and started mid-file (its picture may be off by up to a GOP), then restart once re-encoded.
    static func coveDrawnSwitch(streamCopiedMidFile: Bool) -> SubSwitch {
        streamCopiedMidFile ? .restartReencode : .loadCues
    }

    static func logLine(reencode: Bool, forceTranscode: Bool, coveDrawnSub: Bool) -> String {
        if forceTranscode { return "re-encode (retry)" }
        return reencode ? "re-encode (Cove-drawn subtitle on)" : "video copy (no Cove-drawn subtitle)"
    }

    /// Distance between where the player landed and the requested resume point (logged; 0 when exact).
    static func offset(requested: Double, playerAt: Double) -> Double { playerAt - requested }
}
