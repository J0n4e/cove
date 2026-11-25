import XCTest

final class EpisodeGridCardTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Classic/ClassicDetail.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testGridUsesGlassPanelCard() throws {
        let s = try source()
        XCTAssertTrue(s.contains("episodeTile(ep, grid: true)"))
        XCTAssertTrue(s.contains(".modifier(EpisodeGridPanel(active: grid))"))
        XCTAssertTrue(s.contains("glassCard(padding: Glass3DTokens.Space.s, radius: Glass3DTokens.Radius.panel, level: 2)"))
    }

    func testGridTextTitleAndThreeLineOverview() throws {
        let s = try source()
        XCTAssertTrue(s.contains("func episodeGridText"))
        XCTAssertTrue(s.contains(".lineLimit(3).truncationMode(.tail)"))
        XCTAssertTrue(s.contains("if !overview.isEmpty"))
        XCTAssertTrue(s.contains("EpisodeImagePick") || s.contains("aspectRatio(16 / 9"))
    }
}
