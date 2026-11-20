import XCTest
@testable import Cove

final class WatchedDimTests: XCTestCase {
    func testOpacity() {
        XCTAssertEqual(WatchedDim.opacity(played: true, enabled: true), 0.6)
        XCTAssertEqual(WatchedDim.opacity(played: true, enabled: false), 1)
        XCTAssertEqual(WatchedDim.opacity(played: false, enabled: true), 1)
    }
}
