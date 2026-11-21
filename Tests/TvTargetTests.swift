import XCTest
@testable import Cove

final class TvTargetTests: XCTestCase {
    func testDefaultIsCast() {
        XCTAssertEqual(TvTarget.normalized(nil), "cast")
        XCTAssertEqual(TvTarget.normalized("bogus"), "cast")
        XCTAssertEqual(TvTarget.normalized("airplay"), "airplay")
        XCTAssertEqual(TvTarget.options.map(\.0), ["cast", "airplay"])
    }

    func testBarItemsCast() {
        let ids = PlayerBarItems.items(tvTarget: "cast")
        XCTAssertTrue(ids.contains("cast")); XCTAssertFalse(ids.contains("airplay"))
        XCTAssertEqual(Array(ids.suffix(3)), ["pip", "cast", "fullscreen"])
    }

    func testBarItemsAirPlay() {
        let ids = PlayerBarItems.items(tvTarget: "airplay")
        XCTAssertFalse(ids.contains("cast")); XCTAssertTrue(ids.contains("airplay"))
        XCTAssertEqual(Array(ids.suffix(3)), ["pip", "airplay", "fullscreen"])
    }

    func testActiveSessionsKeepTheirButton() {
        XCTAssertEqual(Array(PlayerBarItems.items(tvTarget: "airplay", casting: true).suffix(4)),
                       ["pip", "cast", "airplay", "fullscreen"])
        XCTAssertEqual(Array(PlayerBarItems.items(tvTarget: "cast", airPlayActive: true).suffix(4)),
                       ["pip", "cast", "airplay", "fullscreen"])
    }

    func testBarItemFilterUsesAirPlayOn() {
        let mk = { (id: String, on: Bool) in Glass3DBarItem(id: id, icon: "x", on: on, help: id) }
        let off = [mk("pip", false), mk("cast", false), mk("airplay", false), mk("fullscreen", false)]
        XCTAssertEqual(PlayerBarItems.items(off, tvTarget: "cast").map(\.id), ["pip", "cast", "fullscreen"])
        let on = [mk("pip", false), mk("cast", false), mk("airplay", true), mk("fullscreen", false)]
        XCTAssertEqual(PlayerBarItems.items(on, tvTarget: "cast").map(\.id), ["pip", "cast", "airplay", "fullscreen"])
        XCTAssertEqual(PlayerBarItems.items(off, tvTarget: "airplay", casting: true).map(\.id), ["pip", "cast", "airplay", "fullscreen"])
    }

    func testDetailOrderBothSettings() {
        XCTAssertEqual(DetailRowOrder.order(tvTarget: "cast"),
                       ["play", "resume", "watchTogether", "cast", "trailer", "watched", "favorite", "rating", "admin"])
        XCTAssertEqual(DetailRowOrder.order(tvTarget: "airplay"),
                       ["play", "resume", "watchTogether", "airplay", "trailer", "watched", "favorite", "rating", "admin"])
        XCTAssertTrue(DetailRowOrder.order(tvTarget: "airplay", casting: true).contains("cast"))
    }

    func testLockDecision() {
        XCTAssertNil(TvTarget.lockReason(casting: false, airPlayActive: false))
        XCTAssertEqual(TvTarget.lockReason(casting: true, airPlayActive: false), "Stop casting to change this")
        XCTAssertEqual(TvTarget.lockReason(casting: false, airPlayActive: true), "Stop AirPlay to change this")
        XCTAssertEqual(TvTarget.apply("airplay", current: "cast", casting: false, airPlayActive: false), "airplay")
        XCTAssertEqual(TvTarget.apply("airplay", current: "cast", casting: true, airPlayActive: false), "cast")
        XCTAssertEqual(TvTarget.apply("cast", current: "airplay", casting: false, airPlayActive: true), "airplay")
    }
}
