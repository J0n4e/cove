import XCTest
@testable import Cove
import SwiftUI

/// Glass3D polish round 2: the thumbnails' progress line, the library sort label and item count.
final class Glass3DRound2Tests: XCTestCase {
    // The bottom progress line (progressWidth) is gone: the Resume ring replaced it (UI polish round 1).

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

// MARK: - Progress (bottom line + Resume ring) and unselected tabs

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

    func testBottomLineWidth() {
        XCTAssertEqual(ProgressStyle.lineWidth(0.25, total: 260), 65, accuracy: 0.001)
        XCTAssertEqual(ProgressStyle.lineWidth(0.5, total: 220), 110, accuracy: 0.001)
        XCTAssertEqual(ProgressStyle.lineWidth(0, total: 260), 0)
        XCTAssertEqual(ProgressStyle.lineWidth(1, total: 260), 0)
        XCTAssertEqual(ProgressStyle.lineWidth(.nan, total: 260), 0)
        XCTAssertEqual(ProgressStyle.lineWidth(0.5, total: 0), 0)
    }

    func testRingSitsAboveBottomLine() {
        XCTAssertGreaterThan(ProgressStyle.ringBottomInset, ProgressStyle.line)
    }

    func testResumeTooltipFormatting() {
        XCTAssertEqual(ProgressStyle.timeText(45), "0:45")
        XCTAssertEqual(ProgressStyle.timeText(754), "12:34")
        XCTAssertEqual(ProgressStyle.timeText(3723), "1:02:03")
        XCTAssertEqual(ProgressStyle.timeText(-5), "0:00")
        XCTAssertEqual(ProgressStyle.resumeTip(754), "Resume from 12:34")
    }

    func testStartPositionPerButton() {
        XCTAssertEqual(ProgressStyle.centreStart(hasProgress: true), 0)
        XCTAssertNil(ProgressStyle.centreStart(hasProgress: false))
        XCTAssertEqual(ProgressStyle.centreTip(hasProgress: true), "Play from the beginning")
        XCTAssertNil(ProgressStyle.centreTip(hasProgress: false))
        XCTAssertEqual(ProgressStyle.ringStart(resumeAt: 754), 754)
        XCTAssertEqual(ProgressStyle.ringStart(resumeAt: -1), 0)
    }

    func testUnselectedTabFillIsLighterThanHover() {
        XCTAssertLessThan(Glass3DTabHover.fill(hover: false), Glass3DTabHover.fill(hover: true))
        XCTAssertGreaterThan(Glass3DTabHover.fill(hover: false), 0)
    }

    func testTabHoverScaleAndLabel() {
        XCTAssertEqual(Glass3DTabHover.scale(on: false, hover: true, pressed: false), 1)
        XCTAssertEqual(Glass3DTabHover.scale(on: true, hover: true, pressed: false), 1)
        XCTAssertEqual(Glass3DTabHover.scale(on: false, hover: false, pressed: false), 1)
        XCTAssertEqual(Glass3DTabHover.scale(on: true, hover: true, pressed: true), 0.97)
        XCTAssertEqual(Glass3DTabHover.labelOpacity(on: false, hover: false), 1)
        XCTAssertEqual(Glass3DTabHover.labelOpacity(on: false, hover: true), 1)
        XCTAssertEqual(Glass3DTabHover.labelOpacity(on: true, hover: false), 1)
    }
}
