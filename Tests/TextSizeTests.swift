import XCTest
import SwiftUI
@testable import Cove

/// The text-size factor: system size × the Settings choice, and the default leaving every size untouched.
final class TextSizeTests: XCTestCase {
    func testSystemDefaultIsOne() {
        XCTAssertEqual(TextScale.system(.large), 1.0)
    }

    func testSystemMappingIsOrdered() {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
                                        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        let factors = sizes.map(TextScale.system)
        XCTAssertEqual(factors, factors.sorted())
        XCTAssertEqual(Set(factors).count, factors.count)
        XCTAssertEqual(TextScale.system(.xSmall), 0.88)
        XCTAssertEqual(TextScale.system(.xxxLarge), 1.36)
        XCTAssertEqual(TextScale.system(.accessibility5), 1.8)
    }

    func testInAppChoices() {
        XCTAssertEqual(TextScale.inApp("default"), 1.0)
        XCTAssertEqual(TextScale.inApp("smaller"), 0.9)
        XCTAssertEqual(TextScale.inApp("larger"), 1.15)
        XCTAssertEqual(TextScale.inApp("largest"), 1.3)
        XCTAssertEqual(TextScale.inApp("garbage"), 1.0)
        XCTAssertEqual(TextScale.choices.map(\.0), ["smaller", "default", "larger", "largest"])
    }

    func testCombinedClamp() {
        XCTAssertEqual(TextScale.combined(system: 1.0, inApp: 1.0), 1.0)
        XCTAssertEqual(TextScale.combined(system: 1.0, inApp: 1.3), 1.3, accuracy: 0.0001)
        XCTAssertEqual(TextScale.combined(system: 1.8, inApp: 1.3), 2.0)    // 2.34 → 2.0
        XCTAssertEqual(TextScale.combined(system: 0.88, inApp: 0.9), 0.8)   // 0.792 → 0.8
    }

    func testScaledSizeAtDefaultIsBase() {
        for base: CGFloat in [9, 10, 10.5, 12, 13, 15.5, 22, 42, 60] {
            XCTAssertEqual(TextScale.scaledSize(base: base, scale: 1.0), base)
        }
        XCTAssertEqual(TextScale.scaledSize(base: 20, scale: 1.3), 26)
        XCTAssertEqual(TextScale.scaledSize(base: 10, scale: 0.9), 9)
    }
}
