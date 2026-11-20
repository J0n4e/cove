import XCTest
@testable import Cove

/// Cast burn-in forcing a video conversion, Emby → always burned in on Cast, the side-track failure memory, and the
/// AirPlay end debounce / Emby straight-to-burn-in decision.
final class TvBurnInAirPlayTests: XCTestCase {
    private func query(_ s: String) -> [String: String] {
        var d: [String: String] = [:]
        for i in URLComponents(string: s)?.queryItems ?? [] { d[i.name] = i.value ?? "" }
        return d
    }

    func testForBurnInDisablesVideoCopy() {
        let u = Emby.forBurnIn("https://s/Videos/1/master.m3u8?AllowVideoStreamCopy=true&SubtitleStreamIndex=4&SubtitleMethod=Encode&api_key=T")
        let q = query(u)
        XCTAssertEqual(q["AllowVideoStreamCopy"], "false")
        XCTAssertEqual(q["EnableAutoStreamCopy"], "false")
        XCTAssertEqual(q["VideoCodec"], "h264")
        XCTAssertEqual(q["SubtitleStreamIndex"], "4")
        XCTAssertEqual(u.components(separatedBy: "AllowVideoStreamCopy").count, 2)   // only once
    }

    func testForBurnInKeepsCodec() {
        XCTAssertEqual(query(Emby.forBurnIn("https://s/a?VideoCodec=h264,hevc"))["VideoCodec"], "h264,hevc")
    }

    func testBurnInLogHasNoToken() {
        let l = Emby.burnInLog("https://s/a?SubtitleStreamIndex=4&SubtitleMethod=Encode&AllowVideoStreamCopy=false&api_key=SECRET")
        XCTAssertFalse(l.contains("SECRET"))
        XCTAssertTrue(l.contains("SubtitleMethod=Encode"))
    }

    func testCastBurnedURLForcesConversion() throws {
        let req = CastRequest(itemId: "i", sourceId: "s", audio: nil, sub: 4, subIsImage: true, start: 0)
        let u = try CastStream.url(server: "https://emby.example", token: "T", keyName: "api_key", deviceId: "d",
                                   playSessionId: "p", req: req, profile: .basic).get()
        let q = query(u.absoluteString)
        XCTAssertEqual(q["AllowVideoStreamCopy"], "false")
        XCTAssertEqual(q["EnableAutoStreamCopy"], "false")
        XCTAssertEqual(q["SubtitleMethod"], "Encode")
        XCTAssertEqual(q["SubtitleStreamIndex"], "4")
        XCTAssertEqual(q["api_key"], "T")
    }

    func testCastSideTrackURLKeepsCopy() throws {
        let req = CastRequest(itemId: "i", sourceId: "s", audio: nil, sub: 4, subIsImage: false, start: 0)
        let u = try CastStream.url(server: "https://emby.example", token: "T", keyName: "api_key", deviceId: "d",
                                   playSessionId: "p", req: req, profile: .basic).get()
        XCTAssertEqual(query(u.absoluteString)["AllowVideoStreamCopy"], "true")
    }

    func testEmbyAlwaysBurnsInOnCast() {
        XCTAssertEqual(CastSubtitles.decide(.sideTrack, isJellyfin: false, sideFailedBefore: false), .burnIn)
        XCTAssertEqual(CastSubtitles.decide(.warmThenSide, isJellyfin: false, sideFailedBefore: false), .burnIn)
    }

    func testJellyfinKeepsSideTrackUntilItFailed() {
        XCTAssertEqual(CastSubtitles.decide(.sideTrack, isJellyfin: true, sideFailedBefore: false), .sideTrack)
        XCTAssertEqual(CastSubtitles.decide(.warmThenSide, isJellyfin: true, sideFailedBefore: false), .warmThenSide)
        XCTAssertEqual(CastSubtitles.decide(.sideTrack, isJellyfin: true, sideFailedBefore: true), .burnIn)
        XCTAssertEqual(CastSubtitles.decide(.burnIn, isJellyfin: true, sideFailedBefore: false), .burnIn)
    }

    func testSideFailedKey() {
        XCTAssertEqual(CastSubtitles.key(item: "abc", index: 4), "abc#4")
        XCTAssertNotEqual(CastSubtitles.key(item: "abc", index: 4), CastSubtitles.key(item: "abc", index: 5))
    }

    func testAirPlayEndDebounce() {
        XCTAssertFalse(PlayerModel.airPlayEnded(activeNow: false, offFor: 0.5, restartInProgress: false))
        XCTAssertFalse(PlayerModel.airPlayEnded(activeNow: false, offFor: 10, restartInProgress: true))
        XCTAssertFalse(PlayerModel.airPlayEnded(activeNow: true, offFor: 10, restartInProgress: false))
        XCTAssertTrue(PlayerModel.airPlayEnded(activeNow: false, offFor: PlayerModel.airPlayEndDebounce, restartInProgress: false))
    }

    func testEmbyAirPlayGoesStraightToBurnIn() {
        XCTAssertTrue(PlayerModel.airPlayNoHlsSubs(isJellyfin: false, known: false))
        XCTAssertFalse(PlayerModel.airPlayNoHlsSubs(isJellyfin: true, known: false))
        XCTAssertTrue(PlayerModel.airPlayNoHlsSubs(isJellyfin: true, known: true))
        let unsupported = PlayerModel.airPlayNoHlsSubs(isJellyfin: false, known: false)
        XCTAssertEqual(PlayerModel.airPlaySubAction(path: .file, airPlay: true, playingInStream: false, burnedForAirPlay: false,
                                                    hls: true, inStreamUnsupported: unsupported, textCodec: true), .burnIn)
    }
}
