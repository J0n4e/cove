import XCTest
@testable import Cove

final class BurnInPlaybackInfoTests: XCTestCase {
    private func q(_ items: [URLQueryItem]) -> [String: String] {
        Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
    private func q(_ url: URL?) -> [String: String] { q(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []) }

    func testQueryForcesEncodeAndNoDirect() {
        let m = q(Emby.burnInQuery(userId: "U", sourceId: "S", sub: 4, audio: 1, start: 10, maxBitrate: 40_000_000))
        XCTAssertEqual(m["UserId"], "U")
        XCTAssertEqual(m["MediaSourceId"], "S")
        XCTAssertEqual(m["SubtitleStreamIndex"], "4")
        XCTAssertEqual(m["AudioStreamIndex"], "1")
        XCTAssertEqual(m["StartTimeTicks"], "100000000")
        XCTAssertEqual(m["MaxStreamingBitrate"], "40000000")
        XCTAssertEqual(m["EnableDirectPlay"], "false")
        XCTAssertEqual(m["EnableDirectStream"], "false")
        XCTAssertEqual(m["AllowVideoStreamCopy"], "false")
        XCTAssertEqual(m["AllowAudioStreamCopy"], "true")
        XCTAssertEqual(m["IsPlayback"], "true")
        XCTAssertEqual(m["AutoOpenLiveStream"], "true")
    }

    func testQueryOmitsOptionals() {
        let m = q(Emby.burnInQuery(userId: "U", sourceId: nil, sub: 2, audio: nil, start: nil, maxBitrate: 1))
        XCTAssertNil(m["MediaSourceId"]); XCTAssertNil(m["AudioStreamIndex"]); XCTAssertNil(m["StartTimeTicks"])
    }

    func testProfileSubtitlesAllEncodeNoDirectPlay() throws {
        let p = Emby.burnInProfile(name: "x", audioCodecs: "aac", maxBitrate: 40_000_000)
        // survives JSON (it's the request body)
        let data = try JSONSerialization.data(withJSONObject: ["DeviceProfile": p])
        let j = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["DeviceProfile"] as? [String: Any])
        XCTAssertEqual((j["DirectPlayProfiles"] as? [Any])?.count, 0)
        let subs = try XCTUnwrap(j["SubtitleProfiles"] as? [[String: Any]])
        XCTAssertFalse(subs.isEmpty)
        XCTAssertTrue(subs.allSatisfy { $0["Method"] as? String == "Encode" })
        let formats = Set(subs.compactMap { $0["Format"] as? String })
        for f in ["srt", "subrip", "ass", "ssa", "vtt", "pgssub", "dvdsub"] { XCTAssertTrue(formats.contains(f), f) }
        let tp = try XCTUnwrap((j["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(tp["Container"] as? String, "ts")
        XCTAssertEqual(tp["VideoCodec"] as? String, "h264")
        XCTAssertEqual(tp["AudioCodec"] as? String, "aac")
        XCTAssertEqual(tp["Protocol"] as? String, "hls")
        XCTAssertEqual(tp["Context"] as? String, "Streaming")
        XCTAssertEqual(tp["BreakOnNonKeyFrames"] as? Bool, true)
        let air = Emby.burnInProfile(name: "x", audioCodecs: "aac,ac3,eac3", maxBitrate: 1)
        XCTAssertEqual((air["TranscodingProfiles"] as? [[String: Any]])?.first?["AudioCodec"] as? String, "aac,ac3,eac3")
    }

    func testRelativeTranscodingUrlGetsServerAndKey() {
        let u = Emby.burnInStreamURL("/videos/1/master.m3u8?SubtitleMethod=Encode&PlaySessionId=P",
                                     server: "http://192.168.1.10:8096/", keyName: "api_key", token: "T",
                                     addKey: true, playSessionId: "Q")
        XCTAssertEqual(u?.host, "192.168.1.10"); XCTAssertEqual(u?.port, 8096)
        XCTAssertEqual(u?.path, "/videos/1/master.m3u8")
        let m = q(u)
        XCTAssertEqual(m["api_key"], "T")
        XCTAssertEqual(m["PlaySessionId"], "P")   // the server's own one is kept
        XCTAssertEqual(m["SubtitleMethod"], "Encode")
    }

    func testNoKeyWhenNotWantedOrPresentOrForeign() {
        let a = Emby.burnInStreamURL("/v/m.m3u8?x=1", server: "http://s:8096", keyName: "api_key", token: "T",
                                     addKey: false, playSessionId: "Q")
        XCTAssertNil(q(a)["api_key"]); XCTAssertEqual(q(a)["PlaySessionId"], "Q")
        let b = Emby.burnInStreamURL("/v/m.m3u8?api_key=OLD", server: "http://s:8096", keyName: "api_key", token: "T",
                                     addKey: true, playSessionId: nil)
        XCTAssertEqual(q(b)["api_key"], "OLD")
        let c = Emby.burnInStreamURL("https://evil.example/m.m3u8", server: "http://s:8096", keyName: "api_key", token: "T",
                                     addKey: true, playSessionId: nil)
        XCTAssertNil(q(c)["api_key"])
    }

    func testRouteByServer() {
        XCTAssertEqual(Emby.burnInRoute(isJellyfin: false), .playbackInfo)
        XCTAssertEqual(Emby.burnInRoute(isJellyfin: true), .handBuilt)
    }

    func testLogLineHasNoTokenAndWarnsOnCopy() {
        let ok = Emby.burnInInfoLog("/v/m.m3u8?SubtitleMethod=Encode&TranscodeReasons=SubtitleCodecNotSupported&api_key=SECRET")
        XCTAssertTrue(ok.contains("SubtitleMethod=Encode=yes"))
        XCTAssertTrue(ok.contains("TranscodeReasons=SubtitleCodecNotSupported"))
        XCTAssertFalse(ok.contains("SECRET")); XCTAssertFalse(ok.contains("WARNING"))
        let bad = Emby.burnInInfoLog("/v/m.m3u8?AllowVideoStreamCopy=true")
        XCTAssertTrue(bad.contains("SubtitleMethod=Encode=no")); XCTAssertTrue(bad.contains("WARNING"))
    }
}
