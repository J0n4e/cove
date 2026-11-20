import XCTest
@testable import Cove

/// Google Cast: protobuf framing, the LOAD request, the receiver's replies, the stream URL and device records.
final class CastTests: XCTestCase {

    // MARK: Protobuf

    func testEncodeKnownBytes() {
        let m = CastMessage(source: "s", destination: "d", namespace: "n", payload: "{}")
        let expected: [UInt8] = [0x08, 0x00,             // 1 protocol_version = 0
                                 0x12, 0x01, 0x73,       // 2 source_id "s"
                                 0x1a, 0x01, 0x64,       // 3 destination_id "d"
                                 0x22, 0x01, 0x6e,       // 4 namespace "n"
                                 0x28, 0x00,             // 5 payload_type STRING
                                 0x32, 0x02, 0x7b, 0x7d] // 6 payload_utf8 "{}"
        XCTAssertEqual([UInt8](m.encoded()), expected)
        XCTAssertEqual([UInt8](m.framed()), [0, 0, 0, UInt8(expected.count)] + expected)
    }

    func testRoundTripLongPayload() {
        let long = String(repeating: "é", count: 300)   // > 127 bytes: multi-byte length varint
        let m = CastMessage.make(CastMessage.nsMedia, ["type": "LOAD", "x": long], to: "web-5")
        let back = CastMessage.decode(m.encoded())
        XCTAssertEqual(back, m)
        XCTAssertEqual(back?.type, "LOAD")
        XCTAssertEqual(back?.destination, "web-5")
    }

    func testDecodeSkipsUnknownFieldsAndRejectsGarbage() {
        var d = CastMessage(namespace: "n", payload: "p").encoded()
        d.append(contentsOf: [0x3a, 0x02, 0x01, 0x02])   // 7 payload_binary (ignored)
        XCTAssertEqual(CastMessage.decode(d)?.payload, "p")
        XCTAssertNil(CastMessage.decode(Data([0x22, 0x10, 0x41])))   // length past the end
    }

    func testVarint() {
        var d = Data()
        CastProto.varint(300, into: &d)
        XCTAssertEqual([UInt8](d), [0xac, 0x02])
        var i = 0
        XCTAssertEqual(CastProto.readVarint([UInt8](d), &i), 300)
    }

    // MARK: Framing

    func testFramerSplitAndJoinedReads() {
        let a = CastMessage.make(CastMessage.nsHeartbeat, ["type": "PING"])
        let b = CastMessage.make(CastMessage.nsReceiver, ["type": "GET_STATUS", "requestId": 1])
        let all = a.framed() + b.framed()
        var f = CastFramer()
        var got: [CastMessage] = []
        // one byte at a time
        for byte in all { got += f.append(Data([byte])) }
        XCTAssertEqual(got, [a, b])
        // both in one read
        var g = CastFramer()
        XCTAssertEqual(g.append(all), [a, b])
        // split inside the length prefix
        var h = CastFramer()
        XCTAssertEqual(h.append(all.prefix(2)), [])
        XCTAssertEqual(h.append(all.dropFirst(2)), [a, b])
        XCTAssertTrue(h.buffer.isEmpty)
    }

    func testFramerRejectsHugeLength() {
        var f = CastFramer()
        _ = f.append(Data([0x7f, 0xff, 0xff, 0xff]))
        XCTAssertTrue(f.broken)
    }

    // MARK: LOAD

    func testLoadBodyEpisodeWithSubtitle() throws {
        let u = URL(string: "http://10.0.0.2:8096/Videos/1/master.m3u8?api_key=t")!
        let sub = URL(string: "http://10.0.0.2:8096/Videos/1/s/Subtitles/3/Stream.vtt?api_key=t")!
        let meta = CastMeta(title: "Pilot", seriesTitle: "Show", season: 1, episode: 2,
                            images: [URL(string: "http://10.0.0.2:8096/Items/9/Images/Primary")!], duration: 3000)
        let b = CastLoad.body(url: u, hls: true, meta: meta, start: 125.5, subtitle: (sub, "English", "eng"), hevc: false, requestId: 7)
        XCTAssertEqual(b["type"] as? String, "LOAD")
        XCTAssertEqual(b["requestId"] as? Int, 7)
        XCTAssertEqual(b["autoplay"] as? Bool, true)
        XCTAssertEqual(b["currentTime"] as? Double, 125.5)
        XCTAssertEqual(b["activeTrackIds"] as? [Int], [1])
        let media = try XCTUnwrap(b["media"] as? [String: Any])
        XCTAssertEqual(media["contentId"] as? String, u.absoluteString)
        XCTAssertEqual(media["contentType"] as? String, "application/x-mpegURL")
        XCTAssertEqual(media["streamType"] as? String, "BUFFERED")
        XCTAssertEqual(media["hlsSegmentFormat"] as? String, "ts")
        let md = try XCTUnwrap(media["metadata"] as? [String: Any])
        XCTAssertEqual(md["metadataType"] as? Int, 2)
        XCTAssertEqual(md["seriesTitle"] as? String, "Show")
        XCTAssertEqual(md["season"] as? Int, 1)
        XCTAssertEqual(md["episode"] as? Int, 2)
        XCTAssertEqual((md["images"] as? [[String: String]])?.first?["url"], "http://10.0.0.2:8096/Items/9/Images/Primary")
        let track = try XCTUnwrap((media["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(track["trackId"] as? Int, 1)
        XCTAssertEqual(track["type"] as? String, "TEXT")
        XCTAssertEqual(track["trackContentType"] as? String, "text/vtt")
        XCTAssertEqual(track["trackContentId"] as? String, sub.absoluteString)
        XCTAssertEqual(track["language"] as? String, "eng")
        // valid JSON
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))
    }

    func testLoadBodyMovieNoSubtitle() throws {
        let u = URL(string: "http://h/x.m3u8")!
        let b = CastLoad.body(url: u, hls: true, meta: CastMeta(title: "Film"), start: -3, subtitle: nil, hevc: true, requestId: 1)
        XCTAssertEqual(b["currentTime"] as? Double, 0)
        XCTAssertNil(b["activeTrackIds"])
        let media = try XCTUnwrap(b["media"] as? [String: Any])
        XCTAssertNil(media["tracks"])
        XCTAssertEqual(media["hlsSegmentFormat"] as? String, "fmp4")
        XCTAssertEqual((media["metadata"] as? [String: Any])?["metadataType"] as? Int, 1)
    }

    // MARK: Status

    func testMediaStatusParsing() {
        let j: [String: Any] = ["type": "MEDIA_STATUS", "status": [[
            "mediaSessionId": 4, "playerState": "PAUSED", "currentTime": 61.25,
            "media": ["duration": 5400.0], "volume": ["level": 0.5]]]]
        XCTAssertEqual(CastMediaStatus.parse(j),
                       CastMediaStatus(mediaSessionId: 4, playerState: "PAUSED", currentTime: 61.25, idleReason: nil, duration: 5400, volume: 0.5))
        let idle: [String: Any] = ["type": "MEDIA_STATUS", "status": [["mediaSessionId": 4, "playerState": "IDLE", "idleReason": "FINISHED"]]]
        XCTAssertEqual(CastMediaStatus.parse(idle)?.idleReason, "FINISHED")
        XCTAssertNil(CastMediaStatus.parse(["type": "MEDIA_STATUS", "status": [Any]()]))
        XCTAssertNil(CastMediaStatus.parse(["type": "RECEIVER_STATUS"]))
    }

    func testMediaStatusFromWireJSON() {
        let raw = #"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":1,"playerState":"PLAYING","currentTime":12}],"requestId":0}"#
        let m = CastMessage(source: "web-1", destination: "*", namespace: CastMessage.nsMedia, payload: raw)
        XCTAssertEqual(CastMediaStatus.parse(m.json ?? [:])?.currentTime, 12)
    }

    func testReceiverStatus() {
        let j: [String: Any] = ["type": "RECEIVER_STATUS", "status": [
            "applications": [["appId": "CC1AD845", "transportId": "web-7", "sessionId": "abc", "displayName": "Default Media Receiver"]],
            "volume": ["level": 0.3, "muted": false]]]
        let s = CastReceiverStatus.parse(j)
        XCTAssertEqual(s?.transportId, "web-7")
        XCTAssertEqual(s?.sessionId, "abc")
        XCTAssertEqual(s?.volume, 0.3)
        let other: [String: Any] = ["type": "RECEIVER_STATUS", "status": ["applications": [["appId": "233637DE", "displayName": "YouTube"]]]]
        XCTAssertNil(CastReceiverStatus.parse(other)?.transportId)
        XCTAssertEqual(CastReceiverStatus.parse(other)?.otherApp, "YouTube")
    }

    // MARK: Stream URL

    private func query(_ u: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testStreamURLBasicProfile() throws {
        let r = CastStream.url(server: "http://192.168.1.10:8096", token: "tok", keyName: "api_key", deviceId: "dev", playSessionId: "ps",
                               req: CastRequest(itemId: "42", sourceId: "src", audio: 2, sub: 5, subIsImage: false),
                               profile: CastProfile.forModel("Chromecast"))
        let u = try r.get()
        XCTAssertEqual(u.path, "/Videos/42/master.m3u8")
        let q = query(u)
        XCTAssertEqual(q["VideoCodec"], "h264")
        XCTAssertEqual(q["AudioCodec"], "aac")
        XCTAssertEqual(q["MaxAudioChannels"], "2")
        XCTAssertEqual(q["SegmentContainer"], "ts")
        XCTAssertEqual(q["AudioStreamIndex"], "2")
        XCTAssertNil(q["SubtitleStreamIndex"])   // text subtitles go as a side track
        XCTAssertEqual(q["api_key"], "tok")
        XCTAssertEqual(q["DeviceId"], "dev")
        XCTAssertEqual(q["PlaySessionId"], "ps")
        XCTAssertEqual(q["MediaSourceId"], "src")
    }

    func testStreamURLModernProfileAndBurnIn() throws {
        let u = try CastStream.url(server: "https://media.example.com/", token: "t", keyName: "ApiKey", deviceId: "d", playSessionId: "p",
                                   req: CastRequest(itemId: "1", sourceId: nil, audio: nil, sub: 7, subIsImage: true),
                                   profile: CastProfile.forModel("Chromecast with Google TV (4K)")).get()
        let q = query(u)
        XCTAssertEqual(u.absoluteString.hasPrefix("https://media.example.com/Videos/1/master.m3u8"), true)
        XCTAssertEqual(q["VideoCodec"], "h264,hevc")
        XCTAssertEqual(q["AudioCodec"], "aac,ac3,eac3")
        XCTAssertEqual(q["SegmentContainer"], "mp4")
        XCTAssertEqual(q["SubtitleStreamIndex"], "7")
        XCTAssertEqual(q["SubtitleMethod"], "Encode")
        XCTAssertEqual(q["ApiKey"], "t")
        XCTAssertEqual(q["MediaSourceId"], "1")
    }

    func testLocalhostServerIsRefused() {
        for s in ["http://localhost:8096", "http://127.0.0.1:8096", "http://[::1]:8096", "garbage"] {
            let r = CastStream.url(server: s, token: "t", keyName: "api_key", deviceId: "d", playSessionId: "p",
                                   req: CastRequest(itemId: "1"), profile: .basic)
            XCTAssertEqual(r, .failure(.localServer), s)
        }
        XCTAssertFalse(CastStream.isLocalOnly("http://192.168.1.5:8096"))
        XCTAssertTrue(CastError.localServer.message.contains("localhost"))
    }

    func testProfiles() {
        XCTAssertEqual(CastProfile.forModel("Chromecast"), .basic)
        XCTAssertEqual(CastProfile.forModel("Chromecast Ultra"), CastProfile(hevc: true, surround: true))
        XCTAssertEqual(CastProfile.forModel("Google TV Streamer").hevc, true)
        XCTAssertEqual(CastProfile.forModel("Nest Hub"), .basic)
    }

    func testSubtitleURL() {
        XCTAssertEqual(CastStream.subtitleURL(server: "http://h:1", token: "t", keyName: "api_key", itemId: "i", sourceId: "s", index: 3)?.absoluteString,
                       "http://h:1/Videos/i/s/Subtitles/3/Stream.vtt?api_key=t")
    }

    // MARK: Devices

    func testDeviceFromTXT() {
        let d = CastDevice.from(txt: ["fn": "Living Room TV", "md": "Chromecast Ultra", "id": "abc123"], service: "Chromecast-Ultra-abc123")
        XCTAssertEqual(d.name, "Living Room TV")
        XCTAssertEqual(d.model, "Chromecast Ultra")
        XCTAssertEqual(d.id, "abc123")
        XCTAssertTrue(d.profile.hevc)
        let bare = CastDevice.from(txt: [:], service: "Google-TV-0f1e2d")
        XCTAssertEqual(bare.name, "Google TV")
        XCTAssertEqual(bare.id, "Google-TV-0f1e2d")
        XCTAssertEqual(bare.model, "Cast device")
    }

    func testDeviceSortLastUsedFirst() {
        let a = CastDevice.from(txt: ["fn": "Bedroom", "id": "1"], service: "a")
        let b = CastDevice.from(txt: ["fn": "attic", "id": "2"], service: "b")
        let c = CastDevice.from(txt: ["fn": "Kitchen", "id": "3"], service: "c")
        XCTAssertEqual(CastDeviceStore.sorted([a, b, c], last: "3").map(\.id), ["3", "2", "1"])
        XCTAssertEqual(CastDeviceStore.sorted([c, a, b], last: nil).map(\.id), ["2", "1", "3"])
    }
}
