import XCTest
@testable import Cove

/// AirPlay text subtitles through Cove's local HLS: master rewrite, subtitle playlist, WebVTT windows, decision.
final class AirPlayLocalHLSTests: XCTestCase {
    let serverURL = URL(string: "https://emby.example:8920/emby/videos/42/master.m3u8?MediaSourceId=abc&api_key=KEY")!
    let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="old",NAME="CC",URI="subs_old.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080
    main.m3u8?MediaSourceId=abc&PlaySessionId=p1
    #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
    https://other.example/x.m3u8
    """

    func testMasterRewrite() throws {
        let m = try XCTUnwrap(AirPlayHLS.master(master, serverURL: serverURL, subsURI: "http://10.0.0.2:5000/hls/t/subs.m3u8",
                                                name: "Romanian", lang: "ro"))
        let lines = m.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertFalse(m.contains("subs_old"))
        XCTAssertTrue(m.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"Romanian\",LANGUAGE=\"ro\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"http://10.0.0.2:5000/hls/t/subs.m3u8\""))
        let infs = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF") }
        XCTAssertEqual(infs.count, 2)
        XCTAssertTrue(infs.allSatisfy { $0.hasSuffix(",SUBTITLES=\"subs\"") })
        XCTAssertTrue(infs[0].contains("CODECS=\"avc1.640028,mp4a.40.2\"") && infs[0].contains("RESOLUTION=1920x1080") && infs[0].contains("BANDWIDTH=5000000"))
        XCTAssertTrue(m.contains("https://emby.example:8920/emby/videos/42/main.m3u8?MediaSourceId=abc&PlaySessionId=p1&api_key=KEY"))
        XCTAssertTrue(m.contains("\nhttps://other.example/x.m3u8\n"), "other origin: no key")
        XCTAssertLessThan(m.range(of: "GROUP-ID=\"subs\"")!.lowerBound, m.range(of: "#EXT-X-STREAM-INF")!.lowerBound)
    }

    func testKeyNotDuplicatedAndNotMaster() {
        XCTAssertEqual(AirPlayHLS.absolute("main.m3u8?api_key=KEY", base: serverURL),
                       "https://emby.example:8920/emby/videos/42/main.m3u8?api_key=KEY")
        XCTAssertNil(AirPlayHLS.master("#EXTM3U\n#EXTINF:3,\na.ts\n", serverURL: serverURL, subsURI: "x", name: "a", lang: nil))
    }

    func testSubsPlaylist() {
        let p = AirPlayHLS.subsPlaylist(duration: 150) { "http://h/hls/t/sub_\($0).vtt" }
        XCTAssertTrue(p.contains("#EXT-X-PLAYLIST-TYPE:VOD") && p.contains("#EXT-X-TARGETDURATION:60") && p.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(p.hasSuffix("#EXT-X-ENDLIST\n"))
        let infs = p.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") }
        XCTAssertEqual(infs, ["#EXTINF:60.000,", "#EXTINF:60.000,", "#EXTINF:30.000,"])
        XCTAssertTrue(p.contains("sub_2.vtt") && !p.contains("sub_3.vtt"))
        XCTAssertEqual(AirPlayHLS.segmentCount(duration: 120), 2)
        XCTAssertEqual(AirPlayHLS.totalDuration("#EXTINF:3.5,\na\n#EXTINF:2,\nb\n"), 5.5)
        XCTAssertEqual(AirPlayHLS.firstVariant(master), "main.m3u8?MediaSourceId=abc&PlaySessionId=p1")
    }

    func testSegmentWindowing() {
        let cues = [Cue(start: 10, end: 12, text: "a"), Cue(start: 59, end: 61, text: "across"),
                    Cue(start: 70, end: 72, text: "b"), Cue(start: 130, end: 131, text: "c")]
        let s0 = AirPlayHLS.segment(cues, index: 0, mpegts: 126000)
        XCTAssertTrue(s0.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\n\n"))
        XCTAssertTrue(s0.contains("00:00:10.000 --> 00:00:12.000\na") && s0.contains("across") && !s0.contains("\nb\n"))
        let s1 = AirPlayHLS.segment(cues, index: 1)
        XCTAssertTrue(s1.contains("00:00:59.000 --> 00:01:01.000\nacross") && s1.contains("00:01:10.000 --> 00:01:12.000\nb"))
        XCTAssertFalse(s1.contains("\na\n") || s1.contains("\nc\n"))
        XCTAssertTrue(AirPlayHLS.segment(cues, index: 1, offsetMs: 1000).contains("00:01:11.000 --> 00:01:13.000"))
    }

    func testRoutes() {
        let r = { (p: String) in AirPlayHLS.route(p, token: "tok", master: "M", subs: "S") { "V\($0)" } }
        XCTAssertEqual(r("/hls/tok/master.m3u8")?.1, "M")
        XCTAssertEqual(r("/hls/tok/master.m3u8")?.0, "application/vnd.apple.mpegurl")
        XCTAssertEqual(r("/hls/tok/subs.m3u8")?.1, "S")
        XCTAssertEqual(r("/hls/tok/sub_7.vtt")?.1, "V7")
        XCTAssertEqual(r("/hls/tok/sub_7.vtt")?.0, "text/vtt; charset=utf-8")
        XCTAssertNil(r("/hls/other/master.m3u8"))
        XCTAssertNil(AirPlayHLS.route("/hls//master.m3u8", token: "", master: "M", subs: "S") { _ in nil })
        XCTAssertEqual(AirPlayHLS.fetchName("/hls/tok/sub_3.vtt"), "segment 3")
    }

    func testDecision() {
        XCTAssertEqual(AirPlayHLS.choice(airPlay: true, hasSub: true, image: false, directPlay: false, failedBefore: false), .localHLS)
        XCTAssertEqual(AirPlayHLS.choice(airPlay: true, hasSub: true, image: true, directPlay: false, failedBefore: false), .burnIn)
        XCTAssertEqual(AirPlayHLS.choice(airPlay: true, hasSub: true, image: false, directPlay: false, failedBefore: true), .burnIn)
        XCTAssertEqual(AirPlayHLS.choice(airPlay: true, hasSub: true, image: false, directPlay: true, failedBefore: false), .burnIn)
        XCTAssertEqual(AirPlayHLS.choice(airPlay: false, hasSub: true, image: false, directPlay: false, failedBefore: false), .none)
        XCTAssertEqual(AirPlayHLS.choice(airPlay: true, hasSub: false, image: false, directPlay: false, failedBefore: false), .none)
    }
}
