import XCTest
@testable import Cove

/// Settings and About glass windows: which backdrop is used, and the readability tint.
final class GlassWindowsTests: XCTestCase {
    func testLiquidGlassOnMacOS26() {
        XCTAssertEqual(GlassWindowBackdrop.choose(liquidGlass: true, reduceTransparency: false), .liquidGlass)
    }
    func testVisualEffectBefore26() {
        XCTAssertEqual(GlassWindowBackdrop.choose(liquidGlass: false, reduceTransparency: false), .visualEffect)
    }
    func testReduceTransparencyWinsEverywhere() {
        XCTAssertEqual(GlassWindowBackdrop.choose(liquidGlass: true, reduceTransparency: true), .reducedFill)
        XCTAssertEqual(GlassWindowBackdrop.choose(liquidGlass: false, reduceTransparency: true), .reducedFill)
        XCTAssertEqual(GlassWindowBackdrop.reducedFillAlpha, 0.85, accuracy: 0.001)   // dark, never pure black
    }
    func testTintFollowsGlassSetting() {
        XCTAssertEqual(GlassWindowBackdrop.tintAlpha(follow: true, frost: 1), 0.18, accuracy: 0.001)
        XCTAssertEqual(GlassWindowBackdrop.tintAlpha(follow: false, frost: 0), 0.08, accuracy: 0.001)
        XCTAssertEqual(GlassWindowBackdrop.tintAlpha(follow: false, frost: 1), 0.48, accuracy: 0.001)
        XCTAssertEqual(GlassWindowBackdrop.tintAlpha(follow: false, frost: 9), 0.48, accuracy: 0.001)
        XCTAssertLessThan(GlassWindowBackdrop.tintAlpha(follow: false, frost: .nan), 0.5)
    }
    func testAlertCornerRadius() { XCTAssertEqual(GlassWindowBackdrop.cornerRadius, 26) }
}
