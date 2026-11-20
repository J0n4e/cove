import XCTest
@testable import Cove

final class ReportIssueTests: XCTestCase {
    private func info(server: String? = "Jellyfin") -> ReportIssue.Info {
        .init(version: "1.18.12 (412)", server: server, serverVersion: "10.10.3", macOS: "27.3 (26C5047e)",
              environment: "Mac14,2 · Text size: Default · Debug log: on")
    }

    func testURLFieldsAndEncoding() {
        let u = ReportIssue.url(info()).absoluteString
        XCTAssertTrue(u.hasPrefix("https://github.com/J0n4e/cove/issues/new?template=bug_report.yml&title=%5BBug%5D%20&"))
        XCTAssertTrue(u.contains("&version=1.18.12%20%28412%29"))
        XCTAssertTrue(u.contains("&server=Jellyfin&"))
        XCTAssertTrue(u.contains("&server-version=10.10.3&"))
        XCTAssertTrue(u.contains("&macos=27.3%20%2826C5047e%29&"))
        XCTAssertFalse(u.contains("theme="), "one look: no theme field any more")
        XCTAssertTrue(u.contains("&environment=Mac14%2C2%20%C2%B7%20Text%20size%3A%20Default%20%C2%B7%20Debug%20log%3A%20on"))
        let c = URLComponents(string: u)!
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["environment"], "Mac14,2 · Text size: Default · Debug log: on")
        XCTAssertEqual(q["title"], "[Bug] ")
        XCTAssertLessThan(u.count, 8000)
    }

    func testURLEscapesReservedCharacters() {
        var i = info(); i.version = "a&b=c+d#e"
        XCTAssertTrue(ReportIssue.url(i).absoluteString.contains("version=a%26b%3Dc%2Bd%23e"))
    }

    func testURLSkipsUnknownServer() {
        var i = info(server: nil); i.serverVersion = nil
        let u = ReportIssue.url(i).absoluteString
        XCTAssertFalse(u.contains("server="))
        XCTAssertFalse(u.contains("server-version="))
    }

    func testShortMacOS() {
        XCTAssertEqual(ReportIssue.shortMacOS("Version 27.3 (Build 26C5047e)"), "27.3 (26C5047e)")
    }

    func testEnvironment() {
        XCTAssertEqual(ReportIssue.environment(model: "Mac14,2", textSize: "large", debugLog: false),
                       "Mac14,2 · Text size: Large · Debug log: off")
    }

    func testLastLines() {
        let t = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let l = ReportIssue.lastLines(t, 300).components(separatedBy: "\n")
        XCTAssertEqual(l.count, 300)
        XCTAssertEqual(l.first, "line 201")
        XCTAssertEqual(l.last, "line 500")
        XCTAssertEqual(ReportIssue.lastLines("a\nb", 10), "a\nb")
        XCTAssertEqual(ReportIssue.lastLines("", 10), "")
    }

    // MARK: Sanitiser

    func testQueryTokens() {
        let s = ReportIssue.sanitise("2026-11-18T10:00:00Z play https://media.example.com:8920/Videos/abc123/stream.mkv?Static=true&api_key=0123456789abcdef&PlaySessionId=ff00aa&DeviceId=TWFjMTQ&MediaSourceId=abc123",
                                     server: "https://media.example.com:8920")
        XCTAssertFalse(s.contains("0123456789abcdef"))
        XCTAssertFalse(s.contains("ff00aa"))
        XCTAssertFalse(s.contains("TWFjMTQ"))
        XCTAssertFalse(s.contains("media.example.com"))
        XCTAssertTrue(s.contains("/Videos/abc123/stream.mkv"))
        XCTAssertTrue(s.contains("MediaSourceId=abc123"))
        XCTAssertTrue(s.contains("Static=true"))
    }

    func testJellyfinApiKeyAndTokenParam() {
        let s = ReportIssue.sanitise("GET http://jelly.lan/Items/9f?ApiKey=SECRETKEY1 ws wss://jelly.lan/socket?token=SECRETKEY2&deviceId=DEV9")
        for x in ["SECRETKEY1", "SECRETKEY2", "DEV9", "jelly.lan"] { XCTAssertFalse(s.contains(x), x) }
        XCTAssertTrue(s.contains("/Items/9f"))
    }

    func testHeaders() {
        let s = ReportIssue.sanitise("""
        X-Emby-Token: abcdefSECRET
        X-MediaBrowser-Token: mbSECRET
        Authorization: MediaBrowser Client="Cove", Device="Jonas MacBook", DeviceId="DEVSECRET", Version="1.18", Token="tokSECRET"
        AccessToken=atSECRET
        """)
        for x in ["abcdefSECRET", "mbSECRET", "DEVSECRET", "tokSECRET", "atSECRET", "Jonas MacBook"] { XCTAssertFalse(s.contains(x), x) }
        XCTAssertTrue(s.contains("X-Emby-Token: <redacted>"))
    }

    func testJSONFields() {
        let s = ReportIssue.sanitise(#"{"AccessToken":"jsSECRET","UserId":"u1SECRET","PlaySessionId":"psSECRET","ItemId":"keep42"}"#)
        for x in ["jsSECRET", "u1SECRET", "psSECRET"] { XCTAssertFalse(s.contains(x), x) }
        XCTAssertTrue(s.contains("keep42"))
    }

    func testUserIdInPath() {
        let s = ReportIssue.sanitise("GET /Users/0123456789abcdef0123456789abcdef/Items/777")
        XCTAssertTrue(s.contains("/Users/<user>/Items/777"))
    }

    func testIPAddresses() {
        let s = ReportIssue.sanitise("connect 192.168.1.20:8096 failed, fallback http://10.0.0.5:8096/ and [2001:db8::1] fe80::1ff:fe23:4567:890a")
        for x in ["192.168.1.20", "10.0.0.5", "2001:db8::1", "fe80::1ff:fe23:4567:890a"] { XCTAssertFalse(s.contains(x), x) }
        XCTAssertTrue(s.contains("<ip>:8096"))
    }

    func testHostWithoutScheme() {
        let s = ReportIssue.sanitise("socket error host=emby.home.example.org code=-1004", server: "https://emby.home.example.org")
        XCTAssertFalse(s.contains("emby.home.example.org"))
        XCTAssertTrue(s.contains("code=-1004"))
    }

    func testKeepsNormalText() {
        let t = "2026-11-18T10:00:00Z player: direct play h264 1920x1080, audio eac3 5.1, position 12:34.5, version 1.18.12"
        XCTAssertEqual(ReportIssue.sanitise(t), t)
    }
}
