import XCTest
@testable import Cove

final class NavOrderActivityTests: XCTestCase {
    func testActivityLastOnFirstRun() {
        XCTAssertEqual(NavOrder.rows("", libIds: ["a", "b"]), [NavOrder.favorites, "a", "b", NavOrder.nowPlaying])
    }
    func testMoveSavedOrder() {
        let saved = [NavOrder.nowPlaying, NavOrder.favorites, "a", "b"].joined(separator: ",")
        let moved = NavOrder.activityLast(saved)
        XCTAssertEqual(NavOrder.rows(moved, libIds: ["a", "b"]).last, NavOrder.nowPlaying)
    }
}
