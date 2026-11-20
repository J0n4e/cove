import XCTest
@testable import Cove

/// Cast subtitles: side track vs burn-in, the warm-up verdict, the retry chain after a receiver ERROR, and the
/// AirPlay menu's open window.
final class CastSubtitleTests: XCTestCase {

    func testPictureSubsAlwaysBurnIn() {
        for c in ["pgssub", "PGS", "hdmv_pgs_subtitle", "dvdsub", "vobsub", "dvbsub"] {
            XCTAssertEqual(CastSubtitles.delivery(codec: c, isExternal: false), .burnIn, c)
            XCTAssertEqual(CastSubtitles.delivery(codec: c, isExternal: true), .burnIn, c)
        }
    }

    func testStyledTextBurnsIn() {
        XCTAssertEqual(CastSubtitles.delivery(codec: "ass", isExternal: true), .burnIn)
        XCTAssertEqual(CastSubtitles.delivery(codec: "SSA", isExternal: false), .burnIn)
    }

    func testExternalTextIsSideTrack() {
        XCTAssertEqual(CastSubtitles.delivery(codec: "srt", isExternal: true), .sideTrack)
        XCTAssertEqual(CastSubtitles.delivery(codec: "subrip", isExternal: true), .sideTrack)
        XCTAssertEqual(CastSubtitles.delivery(codec: "vtt", isExternal: true), .sideTrack)
    }

    func testEmbeddedTextIsWarmedFirst() {
        XCTAssertEqual(CastSubtitles.delivery(codec: "subrip", isExternal: false), .warmThenSide)
        XCTAssertEqual(CastSubtitles.delivery(codec: "mov_text", isExternal: false), .warmThenSide)
    }

    func testUnknownBurnsIn() {
        XCTAssertEqual(CastSubtitles.delivery(codec: nil, isExternal: false), .burnIn)
        XCTAssertEqual(CastSubtitles.delivery(codec: "weird", isExternal: true), .burnIn)
        XCTAssertEqual(CastSubtitles.delivery(nil), .burnIn)
    }

    func testWarmVerdict() {
        let vtt = Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHi".utf8)
        XCTAssertTrue(CastSubtitles.warmOK(status: 200, body: vtt, elapsed: 1))
        XCTAssertTrue(CastSubtitles.warmOK(status: 200, body: Data("\u{FEFF}WEBVTT\n".utf8), elapsed: 1))
        XCTAssertFalse(CastSubtitles.warmOK(status: 200, body: vtt, elapsed: 9), "too slow")
        XCTAssertFalse(CastSubtitles.warmOK(status: 404, body: vtt, elapsed: 1))
        XCTAssertFalse(CastSubtitles.warmOK(status: 500, body: nil, elapsed: 1))
        XCTAssertFalse(CastSubtitles.warmOK(status: nil, body: nil, elapsed: 8))
        XCTAssertFalse(CastSubtitles.warmOK(status: 200, body: Data("1\n00:00:00,000 --> ".utf8), elapsed: 1), "SRT, not WebVTT")
    }

    func testRetryChain() {
        // Side track failed soon after LOAD → burned in → without subtitles → the old error
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 7, triedNoSubs: false), .burnIn)
        XCTAssertEqual(CastSubtitles.retry(mode: .burned, sinceLoad: 5, triedNoSubs: false), .noSubs)
        XCTAssertEqual(CastSubtitles.retry(mode: .none, sinceLoad: 5, triedNoSubs: true), .fail)
        XCTAssertEqual(CastSubtitles.retry(mode: .burned, sinceLoad: 5, triedNoSubs: true), .fail)
    }

    func testRetryOnlySoonAfterLoad() {
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 20, triedNoSubs: false), .burnIn)
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 25, triedNoSubs: false), .fail)
        XCTAssertEqual(CastSubtitles.retry(mode: .none, sinceLoad: 1, triedNoSubs: false), .fail, "no subtitle: nothing to blame")
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
