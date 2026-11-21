import XCTest
@testable import Cove

/// Cove's own Cast subtitle server: cues → WebVTT, HTTP parsing and responses (CORS, OPTIONS, 404), the LAN
/// address the TV gets, and text → local server / picture → burn-in.
final class CastSubtitleServerTests: XCTestCase {

    func testStampsOverAnHour() {
        XCTAssertEqual(CastVTT.stamp(0), "00:00:00.000")
        XCTAssertEqual(CastVTT.stamp(61.5), "00:01:01.500")
        XCTAssertEqual(CastVTT.stamp(3723.042), "01:02:03.042")
        XCTAssertEqual(CastVTT.stamp(36000), "10:00:00.000")
        XCTAssertEqual(CastVTT.stamp(-2), "00:00:00.000")
    }

    func testVTTFromSRT() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\nworld\r\n\r\n2\r\n01:10:00,000 --> 01:10:01,000\r\nTom & Jerry <3\r\n"
        let v = CastVTT.make(Cue.parseSRT(srt))
        XCTAssertTrue(v.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(v.contains("00:00:01.000 --> 00:00:02.500\nHello\nworld\n\n"))
        XCTAssertTrue(v.contains("01:10:00.000 --> 01:10:01.000\nTom &amp; Jerry &lt;3\n"))
    }

    func testCleanStripsAssAndEscapes() {
        XCTAssertEqual(CastVTT.clean("{\\an8}{\\i1}Top\\Nline{\\i0}"), "Top\nline")
        XCTAssertEqual(CastVTT.clean("a > b"), "a &gt; b")
        XCTAssertEqual(CastVTT.clean("x\n\n y "), "x\ny", "no blank line inside a cue")
    }

    func testOffset() {
        let c = [Cue(start: 10, end: 12, text: "A"), Cue(start: 0.2, end: 0.4, text: "gone")]
        let later = CastVTT.make(c, offsetMs: 1500)
        XCTAssertTrue(later.contains("00:00:11.500 --> 00:00:13.500\nA"))
        let earlier = CastVTT.make(c, offsetMs: -500)
        XCTAssertTrue(earlier.contains("00:00:09.500 --> 00:00:11.500"))
        XCTAssertFalse(earlier.contains("gone"), "a cue that ends before 0 is dropped")
    }

    func testParseRequest() {
        XCTAssertEqual(CastHTTP.parse(Data("GET /sub/abc.vtt?x=1 HTTP/1.1\r\nHost: a\r\n\r\n".utf8)),
                       CastHTTP.Request(method: "GET", path: "/sub/abc.vtt"))
        XCTAssertEqual(CastHTTP.parse(Data("options /sub/abc.vtt HTTP/1.1\r\n".utf8))?.method, "OPTIONS")
        XCTAssertNil(CastHTTP.parse(Data("GET /sub".utf8)), "first line not complete yet")
        XCTAssertTrue(CastHTTP.headComplete(Data("GET / HTTP/1.1\r\nA: b\r\n\r\n".utf8)))
        XCTAssertFalse(CastHTTP.headComplete(Data("GET / HTTP/1.1\r\nA: b\r\n".utf8)))
    }

    func testGetServesVTTWithCORS() {
        let body = Data("WEBVTT\n\n".utf8)
        let r = CastHTTP.respond(.init(method: "GET", path: "/sub/tok.vtt"), token: "tok", vtt: body)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body, body)
        XCTAssertEqual(r.header("Content-Type"), "text/vtt; charset=utf-8")
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), "*")
        XCTAssertEqual(r.header("Access-Control-Allow-Methods"), "GET, OPTIONS")
        XCTAssertEqual(r.header("Access-Control-Allow-Headers"), "*")
        XCTAssertEqual(r.header("Cache-Control"), "no-cache")
        XCTAssertEqual(r.header("Connection"), "close")
        XCTAssertEqual(r.header("Content-Length"), String(body.count))
        let raw = String(decoding: r.data, as: UTF8.self)
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(raw.hasSuffix("\r\n\r\nWEBVTT\n\n"))
    }

    func testOptionsPreflight() {
        let r = CastHTTP.respond(.init(method: "OPTIONS", path: "/sub/tok.vtt"), token: "tok", vtt: Data("x".utf8))
        XCTAssertEqual(r.status, 204)
        XCTAssertTrue(r.body.isEmpty)
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), "*")
        XCTAssertEqual(r.header("Access-Control-Allow-Methods"), "GET, OPTIONS")
        XCTAssertEqual(r.header("Content-Length"), "0")
    }

    func testWrongPath404() {
        let v = Data("WEBVTT".utf8)
        XCTAssertEqual(CastHTTP.respond(.init(method: "GET", path: "/sub/other.vtt"), token: "tok", vtt: v).status, 404)
        XCTAssertEqual(CastHTTP.respond(.init(method: "GET", path: "/"), token: "tok", vtt: v).status, 404)
        XCTAssertEqual(CastHTTP.respond(nil, token: "tok", vtt: v).status, 404)
        XCTAssertEqual(CastHTTP.respond(.init(method: "GET", path: "/sub/.vtt"), token: "", vtt: v).status, 404, "nothing served")
        XCTAssertEqual(CastHTTP.respond(.init(method: "POST", path: "/sub/tok.vtt"), token: "tok", vtt: v).status, 405)
    }

    func testTokenIsUnguessable() {
        let a = CastHTTP.newToken(), b = CastHTTP.newToken()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testLANAddressInTheTVsSubnet() {
        let ifs = [CastLAN.Interface(name: "lo0", ip: "127.0.0.1", mask: "255.0.0.0"),
                   CastLAN.Interface(name: "en0", ip: "10.0.0.5", mask: "255.255.255.0"),
                   CastLAN.Interface(name: "en1", ip: "192.168.1.20", mask: "255.255.255.0"),
                   CastLAN.Interface(name: "utun3", ip: "100.64.0.2", mask: "255.192.0.0")]
        XCTAssertEqual(CastLAN.pick(tv: "192.168.1.77", ifs), "192.168.1.20")
        XCTAssertEqual(CastLAN.pick(tv: "10.0.0.200", ifs), "10.0.0.5")
        XCTAssertEqual(CastLAN.pick(tv: "172.16.0.9", ifs), "10.0.0.5", "no match: first en*")
        XCTAssertEqual(CastLAN.pick(tv: nil, ifs), "10.0.0.5")
        XCTAssertNil(CastLAN.pick(tv: "1.2.3.4", [ifs[0]]), "loopback only: nothing the TV can reach")
        XCTAssertEqual(CastLAN.pick(tv: nil, [CastLAN.Interface(name: "en0", ip: "169.254.1.2", mask: "255.255.0.0"),
                                              CastLAN.Interface(name: "en5", ip: "192.168.2.2", mask: "255.255.255.0")]), "192.168.2.2")
    }

    func testTextServedPictureBurnedIn() {
        XCTAssertEqual(CastSubtitles.delivery(codec: "subrip", isExternal: true), .local)
        XCTAssertEqual(CastSubtitles.delivery(codec: "subrip", isExternal: false), .local)
        XCTAssertEqual(CastSubtitles.delivery(codec: "pgssub", isExternal: false), .burnIn)
        XCTAssertEqual(CastSubtitles.delivery(codec: "dvd_subtitle", isExternal: false), .burnIn)
    }

    func testLoadCarriesStyleAndTrack() {
        let st = CastSubtitles.style(size: "large", color: "yellow", shadow: "outline", bg: nil)
        XCTAssertEqual(st["edgeType"] as? String, "OUTLINE")
        XCTAssertEqual(st["foregroundColor"] as? String, "#FFFF00FF")
        XCTAssertEqual(st["backgroundColor"] as? String, "#00000000")
        XCTAssertEqual(st["fontScale"] as? Double ?? 0, 1.22, accuracy: 0.01)
        XCTAssertEqual(CastSubtitles.style(size: nil, color: nil, shadow: nil, bg: nil)["edgeType"] as? String, "DROP_SHADOW")
        let sub = URL(string: "http://192.168.1.20:5000/sub/t.vtt")!
        let b = CastLoad.body(url: URL(string: "http://s/v.m3u8")!, hls: true, meta: CastMeta(title: "F"), start: 0,
                              subtitle: (sub, "English", "eng"), hevc: false, requestId: 1, textStyle: st)
        let media = b["media"] as? [String: Any]
        let t = (media?["tracks"] as? [[String: Any]])?.first
        XCTAssertEqual(t?["trackContentId"] as? String, sub.absoluteString)
        XCTAssertEqual(t?["trackContentType"] as? String, "text/vtt")
        XCTAssertEqual(t?["subtype"] as? String, "SUBTITLES")
        XCTAssertEqual(b["activeTrackIds"] as? [Int], [1])
        XCTAssertEqual((media?["textTrackStyle"] as? [String: Any])?["edgeType"] as? String, "OUTLINE")
        XCTAssertFalse((media?["contentId"] as? String ?? "").contains("SubtitleMethod"))
    }
}
