import XCTest
@testable import Cove

final class HomeWideCardTests: XCTestCase {
    private func home() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Classic/ClassicHome.swift"), encoding: .utf8)
    }
    private func resumeCard() throws -> Substring {
        let s = try home()
        let a = try XCTUnwrap(s.range(of: "struct ClassicResumeCard"))
        let rest = s[a.upperBound...]
        let b = rest.range(of: "\nstruct ")?.lowerBound ?? rest.range(of: "\nenum ")?.lowerBound ?? rest.endIndex
        return rest[..<b]
    }

    func testBothRowsUseTheWideCard() throws {
        XCTAssertTrue(HomeCardText.isWideRow(.resume))
        XCTAssertTrue(HomeCardText.isWideRow(.nextUp))
        XCTAssertFalse(HomeCardText.isWideRow(nil))
        XCTAssertTrue(try home().contains("let wide = HomeCardText.isWideRow(row.feed)"))
    }

    func testCardIsTheGridEpisodeCard() throws {
        let c = try resumeCard()
        XCTAssertTrue(c.contains(".modifier(EpisodeGridPanel(active: true))"))
        XCTAssertTrue(c.contains(".classicHoverLift(lift: false)"))
        XCTAssertTrue(c.contains("ZoomInsideOnHover()"))
        XCTAssertTrue(c.contains("cornerRadius: Glass3DTokens.Radius.card"))
        XCTAssertTrue(c.contains(".lineLimit(1).truncationMode(.tail)"))
    }

    func testNoTextOverlayOnThePicture() throws {
        let c = try resumeCard()
        XCTAssertFalse(c.contains("ThumbnailScrim"))
        XCTAssertFalse(c.contains("classicBlackOutline"))
        XCTAssertFalse(c.contains(".overlay(alignment: .bottomLeading)"))
        XCTAssertFalse(c.contains(".overlay(alignment: .topLeading)"))
    }

    func testEpisodeLine() {
        XCTAssertEqual(HomeCardText.subtitle(isEpisode: true, season: 2, episode: 3, name: "Pilot", timeLeft: "23m left", year: 2020),
                       "S2·E3 · Pilot · 23m left")
        // Up Next, not started: no "left"
        XCTAssertEqual(HomeCardText.subtitle(isEpisode: true, season: 2, episode: 3, name: "Pilot", timeLeft: nil, year: nil),
                       "S2·E3 · Pilot")
        XCTAssertEqual(HomeCardText.subtitle(isEpisode: true, season: nil, episode: nil, name: " ", timeLeft: "5m left", year: nil),
                       "5m left")
    }

    func testMovieLine() {
        XCTAssertEqual(HomeCardText.subtitle(isEpisode: false, season: nil, episode: nil, name: "Film", timeLeft: "1h 12m left", year: 1999),
                       "1h 12m left")
        XCTAssertEqual(HomeCardText.subtitle(isEpisode: false, season: nil, episode: nil, name: "Film", timeLeft: nil, year: 1999), "1999")
        XCTAssertEqual(HomeCardText.subtitle(isEpisode: false, season: nil, episode: nil, name: "Film", timeLeft: nil, year: nil), "")
    }
}
