import XCTest
@testable import Cove

/// After a server or user change the app lands on Home: the navigation state is reset, and a selected
/// library the new server doesn't have falls back to Home.
@MainActor
final class ServerSwitchTests: XCTestCase {
    func testNavStateResetGoesHome() {
        let nav = NavState()
        var popped = 0
        nav.popToRoot = { popped += 1 }
        nav.sel = "favorites"; nav.query = "matrix"; nav.searchOpen = true; nav.reselect = 3
        nav.reset()
        XCTAssertEqual(nav.sel, "home")
        XCTAssertEqual(nav.query, "")
        XCTAssertFalse(nav.searchOpen)
        XCTAssertEqual(popped, 1, "pushed pages are closed")
        XCTAssertEqual(nav.reselect, 3, "reselect is left alone")
    }

    func testClassicNavStateResetGoesHome() {
        let nav = ClassicNavState()
        var popped = 0
        nav.popToRoot = { popped += 1 }
        nav.sel = "lib-123"; nav.query = "x"; nav.searchOpen = true
        nav.reset()
        XCTAssertEqual(nav.sel, "home")
        XCTAssertEqual(nav.query, "")
        XCTAssertFalse(nav.searchOpen)
        XCTAssertEqual(popped, 1)
    }

    func testMissingLibraryFallsBackToHome() {
        XCTAssertEqual(NavState.selection("old-lib", libIds: ["a", "b"]), "home")
    }

    func testPresentLibraryStays() {
        XCTAssertEqual(NavState.selection("b", libIds: ["a", "b"]), "b")
    }

    func testFixedPagesStay() {
        for p in ["home", "favorites", "nowplaying", "recent"] {
            XCTAssertEqual(NavState.selection(p, libIds: ["a"]), p)
        }
    }

    func testEmptyListWhileLoadingKeepsSelection() {
        XCTAssertEqual(NavState.selection("a", libIds: []), "a")
    }
}
