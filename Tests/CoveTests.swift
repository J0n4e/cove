import XCTest
@testable import Cove

/// Checks for the parts that don't need a server or the UI.
@MainActor
final class CoveTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Emby.normalize("  myserver:8096/ "), "http://myserver:8096")
        XCTAssertEqual(Emby.normalize("https://a.b//"), "https://a.b")
        XCTAssertEqual(Emby.normalize("HTTP://A.B"), "HTTP://A.B")
    }

    func testSameOrigin() {
        let u = { (s: String) in URL(string: s)! }
        XCTAssertTrue(Net.sameOrigin(u("http://Host:8096/a"), u("http://host:8096/b")))
        XCTAssertTrue(Net.sameOrigin(u("https://host/a"), u("https://host:443")))
        XCTAssertFalse(Net.sameOrigin(u("http://host/a"), u("https://host/a")))
        XCTAssertFalse(Net.sameOrigin(u("http://host:8096"), u("http://other:8096")))
    }

    func testWithoutVideoCopy() {
        let s = Emby.withoutVideoCopy("http://h/v.mp4?a=1&allowvideostreamcopy=true")
        XCTAssertTrue(s.contains("a=1"))
        XCTAssertTrue(s.contains("AllowVideoStreamCopy=false"))
        XCTAssertFalse(s.contains("allowvideostreamcopy=true"))
    }

    func testSavedServerRoundTrip() throws {
        let a = [SavedServer(url: "http://Host:8096", name: "Home", user: "me", token: "t", userId: "u")]
        let b = try JSONDecoder().decode([SavedServer].self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, b)
        XCTAssertEqual(b[0].id, "http://host:8096")
    }

    /// Lists saved by older versions (no token / user id) must still load.
    func testSavedServerOldFormat() throws {
        let old = #"[{"url":"http://h","name":"n","user":"x"}]"#.data(using: .utf8)!
        let b = try JSONDecoder().decode([SavedServer].self, from: old)
        XCTAssertNil(b[0].token)
    }

    func testNavOrder() {
        let f = NavOrder.favorites, n = NavOrder.nowPlaying
        // Nothing saved: both sections in their usual place
        XCTAssertEqual(NavOrder.rows("", libIds: ["a", "b"]), [f, n, "a", "b"])
        // Saved after a library, kept there even when the libraries are reordered
        let r = NavOrder.rows("a,\(f),b,\(n)", libIds: ["b", "a"])
        XCTAssertEqual(r, ["b", n, "a", f])
        XCTAssertEqual(NavOrder.top(r), [])
        XCTAssertEqual(NavOrder.after("a", r), [f])
        // The library it followed is gone: back to the usual place
        XCTAssertEqual(NavOrder.rows("x,\(f),\(n)", libIds: ["a"]), [f, n, "a"])
    }

    func testIsPrivate() {
        for h in ["localhost", "nas", "nas.local", "192.168.1.10", "10.0.0.5", "172.20.1.1", "100.64.0.1", "fd00::1", "[::1]"] {
            XCTAssertTrue(ConnectionSecurity.isPrivate(h), h)
        }
        // Look-alikes and disguised numbers are not the home network
        for h in ["", "134744072", "0x7f000001", "010.0.0.1", "192.168.1.1.nip.io", "10.0.0.1.evil.com", "8.8.8.8", "example.com"] {
            XCTAssertFalse(ConnectionSecurity.isPrivate(h), h)
        }
    }

    func testSafeLink() {
        XCTAssertNotNil(SafeLink.url("https://www.imdb.com/title/tt0111161"))
        XCTAssertNotNil(SafeLink.url(" http://example.com "))
        for s in ["file:///etc/passwd", "smb://server/share", "javascript:alert(1)", "vnc://host", "https://", ""] {
            XCTAssertNil(SafeLink.url(s), s)
        }
    }

    func testInternalPrefs() {
        for k in ["servers", "token", "did", "jellyfin-http://nas:8096", "imageCacheNoHeaders"] { XCTAssertTrue(InternalPrefs.contains(k), k) }
        for k in ["accent", "subLang", "playerVolume", "libs-abc"] { XCTAssertFalse(InternalPrefs.contains(k), k) }
    }

    func testParseSRT() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\n\r\n2\n00:00:03,000 --> 00:00:04,000\nTwo\nlines\n"
        let c = Cue.parseSRT(srt)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.first?.start ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(c.first?.end ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(c.last?.text, "Two\nlines")
    }

    func testTranscodingProfile() {
        // HEVC must come in fMP4 (AVPlayer rejects HEVC in MPEG-TS); conversion stays H.264 (listed first)
        let h = Emby.transcodingProfile(hevc: true)
        XCTAssertEqual(h["Container"] as? String, "mp4")
        XCTAssertEqual(h["VideoCodec"] as? String, "h264,hevc")
        let t = Emby.transcodingProfile(hevc: false)
        XCTAssertEqual(t["Container"] as? String, "ts")
        XCTAssertEqual(t["VideoCodec"] as? String, "h264")
    }

    func testCapConversion() {
        let u = "https://s/videos/1/master.m3u8?VideoBitrate=96000000&MaxWidth=3840&x=1"
        let c = URLComponents(string: Emby.capConversion(u, maxWidth: 2560, maxBitrate: 40_000_000))!
        func v(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        XCTAssertEqual(v("VideoBitrate"), "40000000")
        XCTAssertEqual(v("MaxWidth"), "2560")
        XCTAssertEqual(v("x"), "1")
        // a lower value already asked for is kept
        let d = URLComponents(string: Emby.capConversion("https://s/a?VideoBitrate=8000000", maxWidth: nil, maxBitrate: 40_000_000))!
        XCTAssertEqual(d.queryItems?.first { $0.name == "VideoBitrate" }?.value, "8000000")
        XCTAssertNil(d.queryItems?.first { $0.name == "MaxWidth" })
    }
}
