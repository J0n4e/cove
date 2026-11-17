import XCTest
@testable import Cove
import SwiftUI

/// Glass3D polish round 3: the Liquid lens hover option.
final class Glass3DRound3Tests: XCTestCase {
    func testHoverOptionsAndNames() {
        XCTAssertEqual(HoverStyle.options.map(\.0), ["fog", "glow", "glass"])
        XCTAssertEqual(HoverStyle.options.map(\.1), ["Fogged mirror", "Soft glow", "Liquid lens"])
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
}
