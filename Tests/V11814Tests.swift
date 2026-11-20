import XCTest
@testable import Cove

/// v1.18.14 Glass3D polish: player bar order, subtitle source labels, banner navigation setting.
final class V11814Tests: XCTestCase {
    private func sub(_ i: Int, _ codec: String, ext: Bool, display: String? = "Romanian") -> MStream {
        var s = MStream(Index: i, Type: "Subtitle", DisplayTitle: display, IsDefault: false, Language: "rum",
                        Codec: codec, VideoRange: nil, Width: nil, Height: nil, BitRate: nil)
        s.IsExternal = ext
        return s
    }

    private func item(_ id: String) -> Glass3DBarItem { Glass3DBarItem(id: id, icon: "x", help: id) }

    func testBarOrder() {
        XCTAssertEqual(Glass3DBarItem.order,
                       ["episodes", "chapters", "subtitles", "audio", "quality", "syncplay", "info", "pip", "cast", "airplay", "fullscreen"])
        let shuffled = ["fullscreen", "airplay", "quality", "cast", "info", "subtitles", "episodes", "pip", "audio", "syncplay", "chapters"]
        XCTAssertEqual(Glass3DBarItem.ordered(shuffled.map(item)).map(\.id), Glass3DBarItem.order)
        // Missing items keep the order of the rest
        XCTAssertEqual(Glass3DBarItem.ordered(["info", "subtitles", "quality"].map(item)).map(\.id),
                       ["subtitles", "quality", "info"])
    }

    func testQualityAndSpeedMenu() {
        let o = Glass3DBarMenus.qualitySpeedOptions()
        let q = PlayerUIModel.qualities.count
        XCTAssertEqual(o.first, "Quality")
        XCTAssertEqual(o[q + 1], "Speed")
        XCTAssertEqual(o.last, "2×")
        XCTAssertEqual(Glass3DBarMenus.qualitySpeedHeaders, [0, q + 1])
        XCTAssertEqual(Glass3DBarMenus.qualitySpeedPick(1), .quality(0))
        XCTAssertEqual(Glass3DBarMenus.qualitySpeedPick(q + 2), .speed(0.5))
        XCTAssertEqual(Glass3DBarMenus.qualitySpeedPick(0), .nothing)
        let c = Glass3DBarMenus.qualitySpeedChecked(quality: 0, speed: 1)
        XCTAssertTrue(c.contains(1))
        XCTAssertTrue(c.contains(q + 2 + PlayerUIModel.speeds.firstIndex(of: 1)!))
        XCTAssertEqual(c.count, 2)
    }

    func testSubtitleSourceLabels() {
        XCTAssertEqual(Glass3DTrackLabel.sourcedSubtitles([sub(6, "srt", ext: true)]), ["Romanian · SRT (file)"])
        XCTAssertEqual(Glass3DTrackLabel.sourcedSubtitles([sub(4, "subrip", ext: false)]), ["Romanian · SubRip (embedded)"])
        XCTAssertEqual(Glass3DTrackLabel.sourcedSubtitles([sub(3, "PGSSUB", ext: false, display: "English (PGSSUB)")]),
                       ["English · PGS (embedded)"])
        XCTAssertEqual(Glass3DTrackLabel.sourcedSubtitles([sub(2, "subrip", ext: true, display: "Romanian External (SUBRIP)")]),
                       ["Romanian · SRT (file)"])
        XCTAssertEqual(Glass3DTrackLabel.sourcedSubtitles([sub(1, "ass", ext: true, display: nil)]), ["Track 1 · ASS (file)"])
    }

    func testBannerNavigationDefault() {
        XCTAssertEqual(Glass3DBannerNav.key, "classicBannerNav")
        XCTAssertEqual(Glass3DBannerNav.defaultValue, "deck")
        XCTAssertEqual(Glass3DBannerNav.options.map(\.1), ["Cards", "Bullets"])
    }
}
