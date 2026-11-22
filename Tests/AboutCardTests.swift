import XCTest
@testable import Cove

/// The detail page's Glass3D About card helpers.
final class AboutCardTests: XCTestCase {
    func testTilesHideMissingDataAndKeepOrder() {
        XCTAssertEqual(AboutCard.tiles(lastPlayed: nil, added: nil, genres: [], studios: [], hasFile: false, links: 0), [])
        XCTAssertEqual(AboutCard.tiles(lastPlayed: Date(), added: Date(), genres: ["Drama"], studios: ["A24"], hasFile: true, links: 4),
                       [.lastPlayed, .added, .genres, .studios, .file, .links])
        XCTAssertEqual(AboutCard.tiles(lastPlayed: nil, added: Date(), genres: [], studios: [], hasFile: true, links: 0), [.added, .file])
    }

    func testFileSummary() {
        let s = AboutCard.fileSummary(container: "mkv", size: 16_440_000_000, videoHeight: 1080, videoWidth: 1920)
        XCTAssertTrue(s.hasPrefix("MKV · "))
        XCTAssertTrue(s.hasSuffix(" · 1080p"))
        XCTAssertEqual(AboutCard.fileSummary(container: nil, size: nil, videoHeight: nil), "")
        XCTAssertEqual(AboutCard.fileSummary(container: "mp4", size: nil, videoHeight: nil), "MP4")
    }

    func testResolution() {
        XCTAssertEqual(AboutCard.resolution(width: 3840, height: 1600), "4K")
        XCTAssertEqual(AboutCard.resolution(width: 1920, height: 800), "1080p")   // scope film
        XCTAssertEqual(AboutCard.resolution(width: 1280, height: 720), "720p")
        XCTAssertEqual(AboutCard.resolution(width: 720, height: 576), "576p")
        XCTAssertNil(AboutCard.resolution(width: nil, height: nil))
    }

    func testMiddleTruncate() {
        XCTAssertEqual(AboutCard.middleTruncate("short", max: 10), "short")
        let t = AboutCard.middleTruncate("/mnt/filme/Some Long Folder/Movie.mkv", max: 15)
        XCTAssertEqual(t.count, 15)
        XCTAssertTrue(t.hasPrefix("/mnt/f"))
        XCTAssertTrue(t.hasSuffix("ie.mkv"))
        XCTAssertTrue(t.contains("…"))
    }

    func testLinkLabelsAndIcons() {
        XCTAssertEqual(AboutCard.linkLabel("TheMovieDb"), "TMDB")
        XCTAssertEqual(AboutCard.linkLabel("TheTVDB"), "TVDB")
        XCTAssertEqual(AboutCard.linkLabel("IMDb"), "IMDb")
        XCTAssertEqual(AboutCard.linkLabel("Trakt"), "Trakt")
        XCTAssertEqual(AboutCard.linkLabel("Other"), "Other")
        XCTAssertEqual(AboutCard.linkIcon("Unknown"), "link")
    }
}
