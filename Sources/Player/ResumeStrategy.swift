import Foundation

/// How a resume (start part-way through the file) gets its stream.
///
/// Before, a resume asked the server to re-encode the video (AllowVideoStreamCopy=false): a copied video can only
/// be cut at keyframes, and the fear was that the stream would begin a few seconds before the position the player
/// assumes, putting subtitles out of sync. But Cove never sends StartTimeTicks: it loads the server's whole-file
/// HLS playlist and seeks the AVPlayerItem to the resume point before playback. The segments carry the source
/// timestamps, so the player's clock is the real media time whether the video is copied or converted; in-stream
/// WebVTT is timed by the player, and downloaded/external cues and progress reports use `now`, the same clock.
/// So the re-encode only cost CPU and quality. It stays for the retry after a playback error.
enum ResumeStrategy {
    static let name = "whole-file playlist + seek"

    /// Whether the server must re-encode the video (AllowVideoStreamCopy=false). A resume alone never does.
    static func reencode(resuming: Bool, forceTranscode: Bool) -> Bool { forceTranscode }

    /// Distance between where the player landed and the requested resume point (logged; 0 when exact).
    static func offset(requested: Double, playerAt: Double) -> Double { playerAt - requested }
}
