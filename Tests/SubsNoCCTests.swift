import XCTest
@testable import Cove

final class SubsNoCCTests: XCTestCase {
    /// Owner's Emby log: the Romanian SUBRIP track wasn't in the stream; only 'CC' and macOS's transcription were.
    func testNeverPicksClosedCaptionsOrTranscription() {
        let opts: [(name: String, lang: String?)] = [("CC", nil), ("English (US) Transcribed", "en-US")]
        XCTAssertNil(PlayerModel.pickLegible(opts, title: "Romanian (SUBRIP)", lang: "rum", requested: true,
                                             defaultIndex: 0, usable: [false, false]))
    }
    func testStillPicksTheRealTrack() {
        let opts: [(name: String, lang: String?)] = [("CC", nil), ("Romanian", "ro")]
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "Romanian (SUBRIP)", lang: "rum", requested: true,
                                               usable: [false, true]), 1)
    }
}
