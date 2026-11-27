import XCTest
@testable import Cove
import SwiftUI

/// Glass3D polish round 3: the Liquid lens hover option.
final class Glass3DRound3Tests: XCTestCase {
    func testHoverOptionsAndNames() {
        XCTAssertEqual(Array(HoverStyle.options.map(\.0).prefix(3)), ["fog", "glow", "glass"])
        XCTAssertEqual(Array(HoverStyle.options.map(\.1).prefix(3)), ["Fogged mirror", "Soft glow", "Liquid lens"])
    }

    func testSavedGlassPillMigratesToLiquidLens() {
        // The old "Glass pill" was stored as "glass": it stays valid and is now the Liquid lens
        XCTAssertEqual(HoverStyle.normalized("glass"), "glass")
        XCTAssertEqual(HoverStyle.normalized("fog"), "fog")
        XCTAssertEqual(HoverStyle.normalized("glow"), "glow")
        XCTAssertEqual(HoverStyle.normalized(nil), "fog")
        XCTAssertEqual(HoverStyle.normalized("pill"), "fog")
    }

    func testLensScale() {
        XCTAssertEqual(HoverStyle.lensScale(shown: false, reduceMotion: false), 0.9)
        XCTAssertEqual(HoverStyle.lensScale(shown: true, reduceMotion: false), 1)
        XCTAssertEqual(HoverStyle.lensScale(shown: false, reduceMotion: true), 1)   // Reduce Motion: fade only
    }

    // MARK: Track labels

    func stream(_ index: Int, type: String = "Subtitle", display: String? = nil, title: String? = nil,
                codec: String? = nil, layout: String? = nil) -> MStream {
        var o: [String: Any] = ["Index": index, "Type": type]
        if let display { o["DisplayTitle"] = display }
        if let title { o["Title"] = title }
        if let codec { o["Codec"] = codec }
        if let layout { o["ChannelLayout"] = layout }
        let data = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(MStream.self, from: data)
    }

    func testCodecNames() {
        XCTAssertEqual(Glass3DTrackLabel.codecName("SUBRIP"), "SubRip")
        XCTAssertEqual(Glass3DTrackLabel.codecName("subrip"), "SubRip")
        XCTAssertEqual(Glass3DTrackLabel.codecName("ASS"), "ASS")
        XCTAssertEqual(Glass3DTrackLabel.codecName("PGSSUB"), "PGS")
        XCTAssertEqual(Glass3DTrackLabel.codecName("DVDSUB"), "VobSub")
        XCTAssertEqual(Glass3DTrackLabel.codecName("WEBVTT"), "WebVTT")
        XCTAssertEqual(Glass3DTrackLabel.codecName("MOV_TEXT"), "Text")
        XCTAssertEqual(Glass3DTrackLabel.codecName("xsub"), "Xsub")
        XCTAssertNil(Glass3DTrackLabel.codecName(nil))
        XCTAssertNil(Glass3DTrackLabel.codecName(" "))
    }

    func testUnnamedSubtitleReadsTrackAndCodec() {
        let l = Glass3DTrackLabel.subtitle(position: 2, title: nil, displayTitle: "(SUBRIP)", codec: "subrip", sameNameElsewhere: false)
        XCTAssertEqual(l.title, "Track 2 · SubRip")
        XCTAssertNil(l.detail)
        XCTAssertEqual(Glass3DTrackLabel.subtitle(position: 1, title: nil, displayTitle: "Und - SUBRIP", codec: "subrip",
                                                  sameNameElsewhere: false).title, "Track 1 · SubRip")
        XCTAssertEqual(Glass3DTrackLabel.subtitle(position: 3, title: nil, displayTitle: nil, codec: "PGSSUB",
                                                  sameNameElsewhere: false).title, "Track 3 · PGS")
        XCTAssertEqual(Glass3DTrackLabel.subtitle(position: 4, title: nil, displayTitle: nil, codec: nil,
                                                  sameNameElsewhere: false).title, "Track 4")
    }

    func testNamedSubtitleKeepsItsName() {
        XCTAssertEqual(Glass3DTrackLabel.name(title: nil, displayTitle: "English (SUBRIP)", codec: "subrip"), "English")
        XCTAssertEqual(Glass3DTrackLabel.name(title: nil, displayTitle: "English - Default - SUBRIP", codec: "subrip"), "English")
        XCTAssertEqual(Glass3DTrackLabel.name(title: "Commentary", displayTitle: "English (SUBRIP)", codec: "subrip"), "Commentary")
        XCTAssertEqual(Glass3DTrackLabel.name(title: nil, displayTitle: "English (Forced)", codec: "subrip"), "English (Forced)")
        let l = Glass3DTrackLabel.subtitle(position: 1, title: nil, displayTitle: "English (SUBRIP)", codec: "subrip", sameNameElsewhere: false)
        XCTAssertEqual(l.title, "English")
        XCTAssertNil(l.detail)   // the codec only when it tells two tracks apart
    }

    func testSubtitleListNumbersByPositionAndSeparatesSameNames() {
        let labels = Glass3DTrackLabel.subtitles([
            stream(3, display: "English (SUBRIP)", codec: "subrip"),
            stream(4, display: "English (PGSSUB)", codec: "PGSSUB"),
            stream(5, display: "(SUBRIP)", codec: "subrip"),
        ])
        XCTAssertEqual(labels.map(\.title), ["English", "English", "Track 3 · SubRip"])
        XCTAssertEqual(labels.map(\.detail), ["SubRip", "PGS", nil])
    }

    func testAudioLabels() {
        let a = Glass3DTrackLabel.audios([
            stream(1, type: "Audio", title: "Director's commentary with the whole cast", codec: "aac", layout: "stereo"),
            stream(2, type: "Audio", display: "English - Dolby Digital - 5.1 - Default", codec: "ac3", layout: "5.1"),
            stream(3, type: "Audio", codec: "eac3"),
        ])
        XCTAssertEqual(a[0].title, "Director's commentary with the whole cast")
        XCTAssertEqual(a[0].detail, "AAC · Stereo")
        XCTAssertEqual(a[1].title, "English - Dolby Digital - 5.1")
        XCTAssertNil(a[1].detail)   // the name already says it
        XCTAssertEqual(a[2].title, "Track 3")
        XCTAssertEqual(a[2].detail, "E-AC3")
    }

    func testOffsetText() {
        XCTAssertEqual(Glass3DTrackLabel.offsetText(0), "0 ms")
        XCTAssertEqual(Glass3DTrackLabel.offsetText(200), "+200 ms")
        XCTAssertEqual(Glass3DTrackLabel.offsetText(-100), "−100 ms")
    }

    func testEpisodeFraction() {
        XCTAssertEqual(Glass3DTrackLabel.episodeFraction(position: 600, runtimeTicks: 24_000_000_000, played: false), 0.25, accuracy: 0.0001)
        XCTAssertEqual(Glass3DTrackLabel.episodeFraction(position: 600, runtimeTicks: 24_000_000_000, played: true), 0)
        XCTAssertEqual(Glass3DTrackLabel.episodeFraction(position: 0, runtimeTicks: 24_000_000_000, played: false), 0)
        XCTAssertEqual(Glass3DTrackLabel.episodeFraction(position: 600, runtimeTicks: nil, played: false), 0)
    }

    // MARK: Tooltip placement

    func testTipStaysInsideWindowAtRightEdge() {
        let p = TipPlacement.position(anchor: CGRect(x: 980, y: 700, width: 20, height: 20),
                                      bubble: CGSize(width: 240, height: 28), container: CGSize(width: 1000, height: 800))
        XCTAssertEqual(p.x + 120, 1000 - TipPlacement.margin)   // right edge clamped
        XCTAssertEqual(p.y, 700 + 20 + 8 + 14)                   // room below
    }

    func testTipGoesAboveAtBottomAndClampsLeft() {
        let p = TipPlacement.position(anchor: CGRect(x: 0, y: 770, width: 20, height: 20),
                                      bubble: CGSize(width: 200, height: 28), container: CGSize(width: 1000, height: 800))
        XCTAssertEqual(p.x - 100, TipPlacement.margin)
        XCTAssertEqual(p.y, 770 - 8 - 14)
    }

    func testTipCentredWhenRoom() {
        let p = TipPlacement.position(anchor: CGRect(x: 490, y: 100, width: 20, height: 20),
                                      bubble: CGSize(width: 100, height: 28), container: CGSize(width: 1000, height: 800))
        XCTAssertEqual(p.x, 500)
    }
}
