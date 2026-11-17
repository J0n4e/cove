import XCTest
@testable import Cove
import SwiftUI

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

// MARK: - Progress style (Ring / Glow) and unselected tabs

final class Glass3DProgressStyleTests: XCTestCase {
    func testTrimFractionClamps() {
        XCTAssertNil(ProgressStyle.trimFraction(0))
        XCTAssertNil(ProgressStyle.trimFraction(-0.2))
        XCTAssertNil(ProgressStyle.trimFraction(1))
        XCTAssertNil(ProgressStyle.trimFraction(1.5))
        XCTAssertNil(ProgressStyle.trimFraction(.nan))
        XCTAssertEqual(ProgressStyle.trimFraction(0.4) ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(ProgressStyle.trimFraction(0.001) ?? -1, 0.001, accuracy: 0.00001)
    }

    func testBorderStartsAtTopCentre() {
        let r = CGRect(x: 0, y: 0, width: 260, height: 146)
        XCTAssertEqual(ProgressStyle.borderStart(in: r), CGPoint(x: 130, y: 0))
        let o = CGRect(x: 1.25, y: 1.25, width: 100, height: 50)
        XCTAssertEqual(ProgressStyle.borderStart(in: o), CGPoint(x: 51.25, y: 1.25))
    }

    func testBorderPathBeginsAtStartPoint() {
        let r = CGRect(x: 0, y: 0, width: 220, height: 124)
        let path = TopCenterRoundedBorder(radius: 6).path(in: r)
        var first: CGPoint?
        path.forEach { el in
            if first == nil, case .move(let to) = el { first = to }
        }
        XCTAssertEqual(first, CGPoint(x: 110, y: 0))
        XCTAssertEqual(path.boundingRect.width, 220, accuracy: 0.5)
        XCTAssertEqual(path.boundingRect.height, 124, accuracy: 0.5)
    }

    func testProgressStyleDefaultsAndChoices() {
        XCTAssertEqual(ProgressStyle.key, "progressStyle")
        XCTAssertEqual(ProgressStyle.choices.map(\.0), ["ring", "glow"])
    }

    func testUnselectedTabFillIsLighterThanHover() {
        XCTAssertLessThan(Glass3DTabHover.fill(hover: false), Glass3DTabHover.fill(hover: true))
        XCTAssertGreaterThan(Glass3DTabHover.fill(hover: false), 0)
    }

    func testTabHoverScaleAndLabel() {
        XCTAssertEqual(Glass3DTabHover.scale(on: false, hover: true, pressed: false), 1.03)
        XCTAssertEqual(Glass3DTabHover.scale(on: true, hover: true, pressed: false), 1)
        XCTAssertEqual(Glass3DTabHover.scale(on: false, hover: false, pressed: false), 1)
        XCTAssertEqual(Glass3DTabHover.scale(on: true, hover: true, pressed: true), 0.97)
        XCTAssertEqual(Glass3DTabHover.labelOpacity(on: false, hover: false), 0.6)
        XCTAssertEqual(Glass3DTabHover.labelOpacity(on: false, hover: true), 1)
        XCTAssertEqual(Glass3DTabHover.labelOpacity(on: true, hover: false), 1)
    }
}
