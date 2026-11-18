import XCTest
@testable import Cove

/// In-stream subtitle rendition matching (Emby names/langs) and the first play-method guess.
final class SubsMatchGuessTests: XCTestCase {
    typealias Opt = (name: String, lang: String?)

    func testLangNormalised() {
        XCTAssertEqual(PlayerModel.normLang("rum"), "ro")
        XCTAssertEqual(PlayerModel.normLang("ron"), "ro")
        XCTAssertEqual(PlayerModel.normLang("ro-RO"), "ro")
        XCTAssertEqual(PlayerModel.normLang("ger"), "de")
        XCTAssertEqual(PlayerModel.normLang("fre"), "fr")
        XCTAssertNil(PlayerModel.normLang("und"))
        XCTAssertNil(PlayerModel.normLang(nil))
    }

    func testEmbyRenditionsByLanguage() {
        let opts: [Opt] = [("English", "en"), ("Romanian", "ro")]
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "Rum - SUBRIP", lang: "rum", requested: true), 1)
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "Eng", lang: "eng"), 0)
    }

    func testSameLanguagePickedByTitle() {
        let opts: [Opt] = [("Romanian Forced", "ron"), ("Romanian Full", "ron")]
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "Romanian Full (SUBRIP)", lang: "rum", trackTitle: "Romanian Full"), 1)
    }

    func testRequestedDefaultRendition() {
        let opts: [Opt] = [("Track 1", nil), ("Track 2", nil)]
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "x", lang: "rum", requested: true, defaultIndex: 1), 1)
        XCTAssertNil(PlayerModel.pickLegible(opts, title: "x", lang: "rum", requested: false, defaultIndex: 1))
        XCTAssertEqual(PlayerModel.pickLegible([("Whatever", "und")], title: "x", lang: "rum", requested: true), 0)
        XCTAssertNil(PlayerModel.pickLegible(opts, title: "x", lang: "rum", requested: true))
    }

    let hls = "/videos/i/master.m3u8?MediaSourceId=s&VideoCodec=h264&AudioCodec=eac3,ac3,aac,mp3"

    func testSubtitleReasonDoesNotForceTranscode() {
        let u = hls + "&TranscodeReasons=SubtitleCodecNotSupported&SubtitleStreamIndex=3&SubtitleMethod=Hls"
        XCTAssertEqual(PlayMethod.guess(url: u, sourceAudio: "ac3"), "DirectStream")
        XCTAssertEqual(PlayMethod.guess(url: hls + "&TranscodeReasons=SubtitleCodecNotSupported&SubtitleStreamIndex=3&SubtitleMethod=Encode",
                                        sourceAudio: "ac3"), "Transcode")
    }

    func testAudioNotCopyableIsTranscode() {
        XCTAssertEqual(PlayMethod.guess(url: hls, sourceAudio: "dts"), "Transcode")
        XCTAssertEqual(PlayMethod.guess(url: hls, sourceAudio: "truehd"), "Transcode")
        XCTAssertEqual(PlayMethod.guess(url: hls, sourceAudio: "EAC3"), "DirectStream")
        XCTAssertEqual(PlayMethod.classify(url: hls, transcodingInfo: nil, sourceAudio: "dts"), "Transcode")
        XCTAssertEqual(PlayMethod.classify(url: hls, transcodingInfo: ["IsVideoDirect": true, "IsAudioDirect": true],
                                           sourceAudio: "dts"), "DirectStream")
    }
}
