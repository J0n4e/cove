import XCTest
@testable import Cove

/// Cast copied-video failures: retry with a forced transcode, the remembered decision, the first-attempt rule.
final class CastTranscodeTests: XCTestCase {
    private func video(_ codec: String = "h264", profile: String? = "High", level: Double? = 40, bits: Int? = 8,
                       interlaced: Bool? = false, height: Int = 720) -> MStream {
        var s = MStream(Index: 0, Type: "Video", DisplayTitle: nil, IsDefault: true, Language: nil,
                        Codec: codec, VideoRange: "SDR", Width: 1280, Height: height, BitRate: nil)
        s.Profile = profile; s.Level = level; s.BitDepth = bits; s.IsInterlaced = interlaced
        return s
    }

    func testOwnerErrorChain() {
        // 2 Fast 2 Furious: side track, copied video, error 10 s after LOAD → transcode with the subtitle
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 10, transcoded: false, triedNoSubs: false), .transcode)
        // the transcode fails too → without subtitles (still transcoded) → the error message
        XCTAssertEqual(CastSubtitles.retry(mode: .side, sinceLoad: 3, transcoded: true, triedNoSubs: false), .noSubs)
        XCTAssertEqual(CastSubtitles.retry(mode: .none, sinceLoad: 3, transcoded: true, triedNoSubs: true), .fail)
        // no subtitle at all: the copy still gets its transcode retry
        XCTAssertEqual(CastSubtitles.retry(mode: .none, sinceLoad: 2, transcoded: false, triedNoSubs: false), .transcode)
        XCTAssertEqual(CastSubtitles.retry(mode: .none, sinceLoad: 2, transcoded: true, triedNoSubs: false), .fail)
        XCTAssertLessThanOrEqual(10, CastSubtitles.retryWindow)
        XCTAssertEqual(CastSubtitles.retryWindow, 30)
    }

    func testMemoryPerDeviceAndItem() {
        let d = UserDefaults(suiteName: "CastTranscodeTests-\(UUID().uuidString)")!
        let m = CastCopyMemory(defaults: d)
        XCTAssertFalse(m.failed(device: "tv1", item: "film"))
        m.markFailed(device: "tv1", item: "film")
        XCTAssertTrue(m.failed(device: "tv1", item: "film"))
        XCTAssertFalse(m.failed(device: "tv2", item: "film"), "another TV may play the copy")
        XCTAssertFalse(m.failed(device: "tv1", item: "other"))
        XCTAssertTrue(CastCopyMemory(defaults: d).failed(device: "tv1", item: "film"), "persisted")
        m.markFailed(device: "tv1", item: "film")
        XCTAssertEqual(m.entries.count, 1, "no duplicates")
    }

    func testMemoryCap() {
        var l: [String] = []
        for i in 0..<250 { l = CastCopyMemory.adding("e\(i)", to: l) }
        XCTAssertEqual(l.count, CastCopyMemory.cap)
        XCTAssertEqual(l.first, "e50"); XCTAssertEqual(l.last, "e249")
        l = CastCopyMemory.adding("e50", to: l)
        XCTAssertEqual(l.last, "e50"); XCTAssertEqual(l.count, 200)
    }

    func testFirstAttemptRule() {
        XCTAssertEqual(CastTranscode.firstMode(video()).mode, .copy, "owner's 720p High L4.0 8-bit progressive")
        XCTAssertEqual(CastTranscode.firstMode(video(level: 41)).mode, .copy)
        XCTAssertEqual(CastTranscode.firstMode(video(level: 4.1)).mode, .copy)
        XCTAssertEqual(CastTranscode.firstMode(video(level: 51)).mode, .transcode)
        XCTAssertEqual(CastTranscode.firstMode(video(level: 4.2)).mode, .transcode)
        XCTAssertEqual(CastTranscode.firstMode(video(profile: "High 10")).mode, .transcode)
        XCTAssertEqual(CastTranscode.firstMode(video(profile: "High 4:2:2")).mode, .transcode)
        XCTAssertEqual(CastTranscode.firstMode(video(bits: 10)).mode, .transcode)
        XCTAssertEqual(CastTranscode.firstMode(video(interlaced: true)).mode, .transcode)
        XCTAssertEqual(CastTranscode.firstMode(video("hevc", profile: "Main 10", level: 150, bits: 10)).mode, .copy,
                       "HEVC: the server decides per device profile")
        XCTAssertEqual(CastTranscode.firstMode(nil).mode, .copy)
    }

    func testDescribe() {
        XCTAssertEqual(CastTranscode.describe(video()), "h264 High L4.0 8-bit 720p progressive")
    }

    func testHandBuiltForcedTranscode() {
        var req = CastRequest(itemId: "i", sourceId: "s", audio: 1, sub: 4, subIsImage: false, start: 0)
        req.transcode = true
        guard case .success(let u) = CastStream.url(server: "http://192.168.1.10:8096", token: "t", keyName: "ApiKey",
                                                    deviceId: "d", playSessionId: "p", req: req, profile: CastTranscode.profile) else {
            return XCTFail("no url")
        }
        var q: [String: [String]] = [:]
        for i in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name, default: []].append(i.value ?? "") }
        XCTAssertEqual(q["AllowVideoStreamCopy"], ["false"])
        XCTAssertEqual(q["EnableAutoStreamCopy"], ["false"])
        XCTAssertEqual(q["VideoCodec"], ["h264"])
        XCTAssertEqual(q["AudioCodec"], ["aac"])
        XCTAssertEqual(q["MaxAudioChannels"], ["2"])
        XCTAssertNil(q["SubtitleMethod"], "the side track stays Cove's")
        // without the flag the copy stays allowed
        req.transcode = false
        if case .success(let c) = CastStream.url(server: "http://192.168.1.10:8096", token: "t", keyName: "ApiKey",
                                                 deviceId: "d", playSessionId: "p", req: req, profile: .basic) {
            XCTAssertTrue(c.absoluteString.contains("AllowVideoStreamCopy=true"))
        }
    }

    func testEmbyProfileAndNoCopy() {
        let p = CastTranscode.embyProfile(maxBitrate: 20_000_000)
        XCTAssertEqual((p["DirectPlayProfiles"] as? [[String: Any]])?.count, 0)
        let t = (p["TranscodingProfiles"] as? [[String: Any]])?.first
        XCTAssertEqual(t?["VideoCodec"] as? String, "h264"); XCTAssertEqual(t?["AudioCodec"] as? String, "aac")
        XCTAssertEqual(t?["MaxAudioChannels"] as? String, "2")
        let q = CastTranscode.embyQuery(userId: "u", sourceId: "s", audio: 2, maxBitrate: 1)
        XCTAssertTrue(q.contains(URLQueryItem(name: "AllowVideoStreamCopy", value: "false")))
        XCTAssertTrue(q.contains(URLQueryItem(name: "EnableDirectStream", value: "false")))
        let u = CastTranscode.noCopy(URL(string: "http://h/videos/1/master.m3u8?AllowVideoStreamCopy=true&api_key=k")!)
        XCTAssertTrue(u.absoluteString.contains("AllowVideoStreamCopy=false"))
        XCTAssertTrue(u.absoluteString.contains("api_key=k"))
        XCTAssertEqual(CastTranscode.route(isJellyfin: false), .playbackInfo)
        XCTAssertEqual(CastTranscode.route(isJellyfin: true), .handBuilt)
    }
}
