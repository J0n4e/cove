import AppKit
import XCTest
@testable import Cove

/// Embedded text subtitles inside the HLS stream (SubtitleMethod=Hls) instead of the server's extraction.
@MainActor
final class EmbeddedSubsTests: XCTestCase {
    func sub(_ index: Int, codec: String, external: Bool? = nil, title: String? = nil) -> MStream {
        var json = "{\"Index\":\(index),\"Type\":\"Subtitle\",\"Codec\":\"\(codec)\""
        if let external { json += ",\"IsExternal\":\(external)" }
        if let title { json += ",\"DisplayTitle\":\"\(title)\"" }
        return try! JSONDecoder().decode(MStream.self, from: Data((json + "}").utf8))
    }

    func item() -> Item {
        try! JSONDecoder().decode(Item.self, from: Data("{\"Id\":\"i\",\"Name\":\"n\",\"Type\":\"Movie\"}".utf8))
    }

    func query(_ url: String) -> [String: String] {
        Dictionary((URLComponents(string: url)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    let base = "/videos/i/master.m3u8?MediaSourceId=s&SubtitleStreamIndex=1&SubtitleMethod=Encode&VideoCodec=h264"

    // MARK: URL building

    func testEmbeddedTextAsksForHls() {
        var r = PlayRequest(item: item(), sourceId: "s", audio: nil, sub: nil, maxBitrate: nil)
        r.hlsSub = 3
        let q = query(Emby.subtitleURL(base, r))
        XCTAssertEqual(q["SubtitleStreamIndex"], "3")
        XCTAssertEqual(q["SubtitleMethod"], "Hls")
        XCTAssertFalse(r.transcode, "an in-stream track must not force a conversion")
    }

    func testImageSubIsEncoded() {
        let r = PlayRequest(item: item(), sourceId: "s", audio: nil, sub: 4, maxBitrate: nil)
        let q = query(Emby.subtitleURL(base, r))
        XCTAssertEqual(q["SubtitleStreamIndex"], "4")
        XCTAssertEqual(q["SubtitleMethod"], "Encode")
    }

    func testExternalOrNoneAsksForNothing() {
        let r = PlayRequest(item: item(), sourceId: "s", audio: nil, sub: nil, maxBitrate: nil)
        let q = query(Emby.subtitleURL(base, r))
        XCTAssertNil(q["SubtitleStreamIndex"])
        XCTAssertNil(q["SubtitleMethod"])
        XCTAssertEqual(q["VideoCodec"], "h264")
    }

    func testFixSubtitleDefaultStaysEncode() {
        XCTAssertEqual(query(Emby.fixSubtitle(base, 2))["SubtitleMethod"], "Encode")
    }

    // MARK: Path decision

    func testPathDecision() {
        XCTAssertEqual(PlayerModel.subPath(sub(3, codec: "subrip", external: false), burnIn: false, directPlay: false), .inStream)
        XCTAssertEqual(PlayerModel.subPath(sub(3, codec: "ass"), burnIn: false, directPlay: false), .inStream)
        XCTAssertEqual(PlayerModel.subPath(sub(3, codec: "subrip", external: true), burnIn: false, directPlay: false), .file)
        XCTAssertEqual(PlayerModel.subPath(sub(3, codec: "mov_text", external: false), burnIn: false, directPlay: true), .extraction)
        XCTAssertEqual(PlayerModel.subPath(sub(3, codec: "pgssub"), burnIn: false, directPlay: false), .burnIn)
        XCTAssertEqual(PlayerModel.subPath(sub(3, codec: "subrip"), burnIn: true, directPlay: false), .burnIn)
        XCTAssertEqual(PlayerModel.subPath(nil, burnIn: false, directPlay: false), .none)
    }

    func testSwitchDecision() {
        XCTAssertEqual(PlayerModel.inStreamSwitch(haveOption: true, hls: true, unsupported: false), .select)
        XCTAssertEqual(PlayerModel.inStreamSwitch(haveOption: false, hls: true, unsupported: false), .restart)
        XCTAssertEqual(PlayerModel.inStreamSwitch(haveOption: false, hls: true, unsupported: true), .extract)
        XCTAssertEqual(PlayerModel.inStreamSwitch(haveOption: false, hls: false, unsupported: false), .extract)
    }

    func testPickLegible() {
        let opts: [(name: String, lang: String?)] = [("English - SUBRIP", "en"), ("Romanian - SUBRIP", "ro"), ("Romanian - ASS", "ro")]
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "Romanian - ASS", lang: "rum"), 2)
        XCTAssertEqual(PlayerModel.pickLegible(opts, title: "x", lang: "en"), 0)
        XCTAssertNil(PlayerModel.pickLegible(opts, title: "x", lang: "ro"), "two Romanian renditions: ambiguous")
        XCTAssertEqual(PlayerModel.pickLegible([("Other", nil)], title: "x", lang: nil, requested: true), 0)
        XCTAssertNil(PlayerModel.pickLegible([("Other", nil)], title: "x", lang: nil))
    }

    // MARK: Caption text

    func testAttributedToPlainCaption() {
        let a = NSMutableAttributedString(string: "  <i>Hello</i>\r\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        a.append(NSAttributedString(string: "world\u{2028}again "))
        XCTAssertEqual(LegibleText.plain([a]), "Hello\nworld\nagain")
        XCTAssertEqual(LegibleText.plain([NSAttributedString(string: "A"), NSAttributedString(string: " "), NSAttributedString(string: "B")]), "A\nB")
        XCTAssertEqual(LegibleText.plain([]), "")
    }
}
