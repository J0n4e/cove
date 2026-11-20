import XCTest
@testable import Cove

/// Detail page AirPlay pill: the hand-off to the player (paused, then plays on a route or once the menu is gone).
final class AirPlayDetailTests: XCTestCase {
    func testPlaysOnRouteOrMenuClosedOrTimeout() {
        XCTAssertTrue(AirPlayDetailStart.shouldPlay(externalActive: true, menuClosed: false, sinceMenu: 0))
        XCTAssertTrue(AirPlayDetailStart.shouldPlay(externalActive: false, menuClosed: true, sinceMenu: 0.5))
        XCTAssertTrue(AirPlayDetailStart.shouldPlay(externalActive: false, menuClosed: false, sinceMenu: 5))
        XCTAssertFalse(AirPlayDetailStart.shouldPlay(externalActive: false, menuClosed: false, sinceMenu: 2))
    }

    func testArmedExpires() {
        let t = Date()
        XCTAssertTrue(AirPlayDetailStart.isArmed(phase: .armed, armedAt: t, now: t.addingTimeInterval(1)))
        XCTAssertTrue(AirPlayDetailStart.isArmed(phase: .menuOpen, armedAt: t, now: t.addingTimeInterval(1)))
        XCTAssertFalse(AirPlayDetailStart.isArmed(phase: .armed, armedAt: t, now: t.addingTimeInterval(25)))
        XCTAssertFalse(AirPlayDetailStart.isArmed(phase: .done, armedAt: t, now: t))
        XCTAssertFalse(AirPlayDetailStart.isArmed(phase: .idle, armedAt: nil, now: t))
    }

    func testTrackedMenuClick() {
        XCTAssertTrue(AirPlayDetailStart.menuClosed(clickDuration: 2))
        XCTAssertFalse(AirPlayDetailStart.menuClosed(clickDuration: 0.01))
    }
}
