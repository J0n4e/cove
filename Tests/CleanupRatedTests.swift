import XCTest
@testable import Cove

final class CleanupRatedTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(CleanupRated.allCases.map(\.title), ["Any rating", "Has a rating", "No rating"])
    }
}
