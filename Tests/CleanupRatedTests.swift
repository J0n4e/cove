import XCTest
@testable import Cove

final class CleanupRatedTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(CleanupRated.allCases.map(\.title), ["Any rating", "Rated by you", "Has a server rating", "No server rating"])
    }
}
