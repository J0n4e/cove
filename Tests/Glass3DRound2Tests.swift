import XCTest
@testable import Cove

/// Glass3D polish round 2: the thumbnails' progress line, the library sort label and item count.
final class Glass3DRound2Tests: XCTestCase {
    func testProgressLineWidth() {
        XCTAssertEqual(Glass3DTokens.progressWidth(fraction: 0.5, width: 260), 130)
        XCTAssertEqual(Glass3DTokens.progressWidth(fraction: 0.25, width: 220), 55)
    }

    func testNoLineWhenUnstartedFinishedOrInvalid() {
        XCTAssertEqual(Glass3DTokens.progressWidth(fraction: 0, width: 260), 0)
        XCTAssertEqual(Glass3DTokens.progressWidth(fraction: 1, width: 260), 0)
        XCTAssertEqual(Glass3DTokens.progressWidth(fraction: -0.2, width: 260), 0)
        XCTAssertEqual(Glass3DTokens.progressWidth(fraction: 0.5, width: 0), 0)
    }

    func testSortLabel() {
        XCTAssertEqual(Glass3DTokens.sortLabel(field: "Name", ascending: true), "Sort: Name ↑")
        XCTAssertEqual(Glass3DTokens.sortLabel(field: "Recently Added", ascending: false), "Sort: Recently Added ↓")
    }

    func testItemCount() {
        XCTAssertEqual(Glass3DTokens.itemCount(1170), "1,170 items")
        XCTAssertEqual(Glass3DTokens.itemCount(1), "1 item")
        XCTAssertEqual(Glass3DTokens.itemCount(0), "0 items")
    }

    func testTokenValues() {
        XCTAssertEqual(Glass3DTokens.Radius.card, 12)
        XCTAssertEqual(Glass3DTokens.Radius.panel, 14)
        XCTAssertEqual(Glass3DTokens.Radius.row, 10)
        XCTAssertEqual(Glass3DTokens.Radius.field, 8)
        XCTAssertEqual(Glass3DTokens.Radius.thumb, 6)
        XCTAssertEqual(Glass3DTokens.Radius.tag, 4)
        XCTAssertEqual(Glass3DTokens.Text.pageTitle, 30)
        XCTAssertEqual(Glass3DTokens.Text.section, 22)
    }

    func testPlayerStripIsBlackOnlyInGlass3D() {
        XCTAssertEqual(ClassicPlayerTitleBar.stripColor(glass3D: true), .black)
        XCTAssertEqual(ClassicPlayerTitleBar.stripColor(glass3D: false), ClassicPlayerView.titleBarGray)
    }
}
