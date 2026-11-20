import XCTest
@testable import Cove

/// The player/detail Cast menu (AirPlay-style): rows, tick, icons and the empty states.
final class CastMenuTests: XCTestCase {
    private func dev(_ id: String, _ name: String, _ model: String) -> CastDevice {
        CastDevice(id: id, name: name, model: model, service: name, domain: "local.")
    }

    func testThisMacFirstAndTickedWhenNotCasting() {
        let rows = CastMenu.rows(devices: [dev("a", "Living Room", "Chromecast")], castingTo: nil, macName: "Mac")
        XCTAssertEqual(rows.map(\.name), ["Mac", "Living Room"])
        XCTAssertEqual(rows[0].target, .mac)
        XCTAssertEqual(rows[0].icon, "laptopcomputer")
        XCTAssertEqual(rows.map(\.checked), [true, false])
    }

    func testTickOnCastDevice() {
        let d = [dev("a", "A", "Chromecast"), dev("b", "B", "Google TV")]
        let rows = CastMenu.rows(devices: d, castingTo: "b", macName: "Mac")
        XCTAssertEqual(rows.map(\.checked), [false, false, true])
    }

    func testCastingToUnlistedDeviceTicksNothing() {
        let rows = CastMenu.rows(devices: [dev("a", "A", "Chromecast")], castingTo: "gone", macName: "Mac")
        XCTAssertEqual(rows.filter(\.checked).count, 0)
    }

    func testModelIsTooltipOnly() {
        let rows = CastMenu.rows(devices: [dev("a", "A", "Chromecast Ultra")], castingTo: nil, macName: "Mac")
        XCTAssertEqual(rows[1].tip, "Chromecast Ultra")
        XCTAssertEqual(rows[1].name, "A")
    }

    func testIcons() {
        XCTAssertEqual(CastMenu.icon(model: "Chromecast"), "tv")
        XCTAssertEqual(CastMenu.icon(model: "Google TV Streamer"), "tv")
        XCTAssertEqual(CastMenu.icon(model: "Chromecast Audio"), "hifispeaker")
        XCTAssertEqual(CastMenu.icon(model: "Nest Audio"), "hifispeaker")
        XCTAssertEqual(CastMenu.icon(model: "Google Nest Hub"), "tv")
    }

    func testMacName() {
        XCTAssertEqual(CastMenu.macName("Jonae's MacBook Pro M5"), "Jonae's MacBook Pro M5")
        XCTAssertEqual(CastMenu.macName(nil), "This Mac")
        XCTAssertEqual(CastMenu.macName("  "), "This Mac")
    }

    func testStatus() {
        XCTAssertEqual(CastMenu.status(searching: true, devices: 0, error: nil), .searching)
        XCTAssertEqual(CastMenu.status(searching: false, devices: 0, error: nil), .notFound)
        XCTAssertEqual(CastMenu.status(searching: true, devices: 2, error: nil), CastMenu.Status.none)
        XCTAssertEqual(CastMenu.status(searching: false, devices: 0, error: "x"), .error("x"))
    }

    func testSizes() {
        XCTAssertEqual(CastMenu.maxVisible, 6)
        XCTAssertEqual(CastMenu.width, 240)
        XCTAssertTrue((28...30).contains(CastMenu.rowHeight))
    }
}
