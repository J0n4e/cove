import XCTest
@testable import Cove

/// Direct Stream: the real play method, audio pass-through in the HLS profiles, caps only on purpose.
final class DirectStreamTests: XCTestCase {
    // MARK: Classifier

    func testStaticFileIsDirectPlay() {
        let u = "https://s/Videos/1/stream.mp4?Static=true&MediaSourceId=a"
        XCTAssertEqual(PlayMethod.guess(url: u), "DirectPlay")
        XCTAssertEqual(PlayMethod.classify(url: u, transcodingInfo: ["IsVideoDirect": false]), "DirectPlay")
    }

    func testGuessFromURL() {
        let base = "https://s/videos/1/master.m3u8?PlaySessionId=p&VideoCodec=h264&AudioCodec=aac"
        XCTAssertEqual(PlayMethod.guess(url: base), "DirectStream")
        XCTAssertEqual(PlayMethod.guess(url: base + "&TranscodeReasons=ContainerNotSupported"), "DirectStream")
        XCTAssertEqual(PlayMethod.guess(url: base + "&TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported"), "Transcode")
        XCTAssertEqual(PlayMethod.guess(url: base + "&AllowVideoStreamCopy=false"), "Transcode")
        XCTAssertEqual(PlayMethod.guess(url: base + "&SubtitleStreamIndex=3&SubtitleMethod=Encode"), "Transcode")
        // a text track carried in the stream doesn't force a re-encode
        XCTAssertEqual(PlayMethod.guess(url: base + "&SubtitleStreamIndex=3&SubtitleMethod=Hls"), "DirectStream")
    }

    func testClassifyFromTranscodingInfo() {
        let u = "https://s/videos/1/master.m3u8?PlaySessionId=p"
        XCTAssertEqual(PlayMethod.classify(url: u, transcodingInfo: ["IsVideoDirect": true, "IsAudioDirect": true]), "DirectStream")
        XCTAssertEqual(PlayMethod.classify(url: u, transcodingInfo: ["IsVideoDirect": true, "IsAudioDirect": false]), "Transcode")
        XCTAssertEqual(PlayMethod.classify(url: u, transcodingInfo: ["IsVideoDirect": false, "IsAudioDirect": true]), "Transcode")
        XCTAssertEqual(PlayMethod.classify(url: u, transcodingInfo: ["IsVideoDirect": true]), "DirectStream")   // no audio
        // no info yet: keep the URL guess
        XCTAssertEqual(PlayMethod.classify(url: u, transcodingInfo: nil), "DirectStream")
        XCTAssertEqual(PlayMethod.classify(url: u + "&AllowVideoStreamCopy=false", transcodingInfo: [:]), "Transcode")
        // the server's answer wins over the guess
        XCTAssertEqual(PlayMethod.classify(url: u + "&AllowVideoStreamCopy=false",
                                           transcodingInfo: ["IsVideoDirect": true, "IsAudioDirect": true]), "DirectStream")
    }

    func testDescribe() {
        XCTAssertEqual(PlayMethod.describe("DirectPlay", container: "mp4", sourceVideo: "h264", sourceAudio: "aac", transcodingInfo: nil),
                       "Direct play")
        XCTAssertEqual(PlayMethod.describe("DirectStream", container: "mkv", sourceVideo: "h264", sourceAudio: "ac3", transcodingInfo: nil),
                       "Direct stream (container: mkv → hls)")
        let t: [String: Any] = ["IsVideoDirect": false, "IsAudioDirect": false, "VideoCodec": "h264", "AudioCodec": "eac3",
                                "TranscodeReasons": ["AudioCodecNotSupported"]]
        XCTAssertEqual(PlayMethod.describe("Transcode", container: "mkv", sourceVideo: "HEVC", sourceAudio: "dts", transcodingInfo: t),
                       "Transcode (video: hevc→h264, audio: dts→eac3; reason: AudioCodecNotSupported)")
        XCTAssertEqual(PlayMethod.describe("Transcode", container: nil, sourceVideo: nil, sourceAudio: nil, transcodingInfo: nil), "Transcode")
    }

    func testSessionKeepsKillingTheServerJobForDirectStream() {
        let u = URL(string: "https://s/videos/1/master.m3u8?PlaySessionId=p")!
        let ps = Emby.PlaySession(itemId: "1", sourceId: nil, method: PlayMethod.guess(url: u.absoluteString), url: u,
                                  server: "https://s", token: "t")
        XCTAssertEqual(ps.method, "DirectStream")
        XCTAssertTrue(ps.hls)
    }

    // MARK: Profiles

    private func codecs(_ p: [String: Any], _ k: String) -> [String] {
        (p[k] as? String ?? "").split(separator: ",").map(String.init)
    }

    func testAudioPassThroughPerContainer() {
        let f = Emby.transcodingProfile(hevc: true)
        XCTAssertEqual(f["Container"] as? String, "mp4")
        XCTAssertEqual(Set(codecs(f, "AudioCodec")), ["aac", "ac3", "eac3", "flac", "alac", "mp3"])
        let t = Emby.transcodingProfile(hevc: false)
        XCTAssertEqual(t["Container"] as? String, "ts")
        XCTAssertEqual(Set(codecs(t, "AudioCodec")), ["aac", "ac3", "eac3", "mp3"])   // no FLAC/ALAC in TS
        for p in [f, t] {
            XCTAssertEqual(p["MaxAudioChannels"] as? String, "8")
            XCTAssertEqual(codecs(p, "AudioCodec").first, "eac3")    // conversion target for DTS/TrueHD
            XCTAssertFalse(codecs(p, "AudioCodec").contains { ["dts", "dca", "truehd"].contains($0) })
        }
        // video lists unchanged
        XCTAssertEqual(f["VideoCodec"] as? String, "h264,hevc")
        XCTAssertEqual(t["VideoCodec"] as? String, "h264")
    }

    func testRetryProfileIsStereoAAC() {
        let r = Emby.transcodingProfile(hevc: false, safeAudio: true)
        XCTAssertEqual(r["AudioCodec"] as? String, "aac")
        XCTAssertEqual(r["MaxAudioChannels"] as? String, "2")
    }

    func testCodecProfiles() {
        let c = Emby.codecProfiles()
        XCTAssertTrue(c.contains { $0["Type"] as? String == "Video" && $0["Codec"] as? String == "h264" })
        let a = c.first { $0["Type"] as? String == "VideoAudio" }
        XCTAssertEqual(a?["Codec"] as? String, "ac3,eac3")
        let cond = (a?["Conditions"] as? [[String: Any]])?.first
        XCTAssertEqual(cond?["Property"] as? String, "AudioChannels")
        XCTAssertEqual(cond?["Value"] as? String, "6")
    }

    // MARK: Caps

    private func q(_ s: String) -> [String: String] {
        var o: [String: String] = [:]
        for i in URLComponents(string: s)?.queryItems ?? [] { o[i.name] = i.value }
        return o
    }

    func testNoCapsWithOriginal() {
        let u = "https://s/videos/1/master.m3u8?PlaySessionId=p"
        for b in [nil, 0] as [Int?] {
            XCTAssertFalse(Emby.shouldCap(maxBitrate: b, forcedConversion: false))
            let out = q(Emby.capIfWanted(u, maxWidth: 2560, maxBitrate: b, forcedConversion: false))
            XCTAssertNil(out["MaxWidth"]); XCTAssertNil(out["VideoBitrate"])
        }
    }

    func testCapsWithChosenQuality() {
        let u = "https://s/videos/1/master.m3u8?PlaySessionId=p"
        let out = q(Emby.capIfWanted(u, maxWidth: 2560, maxBitrate: 4_000_000, forcedConversion: false))
        XCTAssertEqual(out["VideoBitrate"], "4000000"); XCTAssertEqual(out["MaxWidth"], "2560")
    }

    func testDefaultCapOnlyForForcedConversion() {
        let u = "https://s/videos/1/master.m3u8?PlaySessionId=p"
        let out = q(Emby.capIfWanted(u, maxWidth: 1920, maxBitrate: nil, forcedConversion: true))
        XCTAssertEqual(out["VideoBitrate"], String(Emby.defaultConversionBitrate)); XCTAssertEqual(out["MaxWidth"], "1920")
    }
}
