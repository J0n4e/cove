import XCTest
@testable import Cove

final class FontChoicesTests: XCTestCase {
    func testDefaultIsSFPro() {
        XCTAssertEqual(ClassicFont.defaultValue, "standard")
        XCTAssertEqual(ClassicFont.choices.first?.0, "standard")
        XCTAssertEqual(ClassicFont.normalized(nil), "standard")
    }
    func testRemovedChoicesFallBackToSFPro() {
        for v in ["helvetica", "gill", "optima", "nonsense"] { XCTAssertEqual(ClassicFont.normalized(v), "standard") }
    }
    func testKeptChoices() {
        for v in ["standard", "rounded", "expanded", "avenir", "futura", "serif", "seravek"] {
            XCTAssertEqual(ClassicFont.normalized(v), v)
        }
        XCTAssertEqual(ClassicFont.choices.count, 7)
    }
}
