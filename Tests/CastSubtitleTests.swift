import XCTest
@testable import Cove

/// Cast subtitles: served by Cove vs burn-in, the retry chain after a receiver ERROR, and the
/// AirPlay menu's open window.
final class CastSubtitleTests: XCTestCase {

    func testPictureSubsAlwaysBurnIn() {
        for c in ["pgssub", "PGS", "hdmv_pgs_subtitle", "dvdsub", "vobsub", "dvbsub"] {
            XCTAssertEqual(CastSubtitles.delivery(codec: c, isExternal: false), .burnIn, c)
            XCTAssertEqual(CastSubtitles.delivery(codec: c, isExternal: true), .burnIn, c)
        }
    }

    func testAllTextIsServedByCove() {
        for (c, ext) in [("srt", true), ("subrip", true), ("vtt", true), ("subrip", false), ("mov_text", false), ("ass", true), ("SSA", false)] {
            XCTAssertEqual(CastSubtitles.delivery(codec: c, isExternal: ext), .local, c)
        }
    }

    func testUnknownTrackBurnsIn() {
        XCTAssertEqual(CastSubtitles.delivery(nil), .burnIn)
    }

    func testRetryChain() {
        // A failed side track or burn-in soon after LOAD → once without subtitles → the old error
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 7, triedNoSubs: false), .noSubs)
        XCTAssertEqual(CastSubtitles.retry(mode: .burned, sinceLoad: 5, triedNoSubs: false), .noSubs)
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 5, triedNoSubs: true), .fail)
        XCTAssertEqual(CastSubtitles.retry(mode: .none, sinceLoad: 5, triedNoSubs: false), .fail, "no subtitle: nothing to blame")
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 25, triedNoSubs: false), .fail)
    }

    func testErrorDetails() {
        let j: [String: Any] = ["type": "MEDIA_STATUS", "status": [["playerState": "IDLE", "idleReason": "ERROR",
                                                                     "detailedErrorCode": 104, "mediaSessionId": 2]]]
        XCTAssertEqual(CastSession.errorDetails(j), "detailedErrorCode=104")
        XCTAssertEqual(CastSession.errorDetails(["type": "ERROR", "reason": "TIMEOUT"]), "reason=TIMEOUT")
        XCTAssertEqual(CastSession.errorDetails(["type": "MEDIA_STATUS"]), "no details")
    }

    func testAirPlayMenuWindow() {
        let t = Date()
        XCTAssertFalse(AirPlayMenu.isOpen(openedAt: nil, now: t))
        XCTAssertTrue(AirPlayMenu.isOpen(openedAt: t, now: t.addingTimeInterval(10)))
        XCTAssertFalse(AirPlayMenu.isOpen(openedAt: t, now: t.addingTimeInterval(61)))
    }
}
