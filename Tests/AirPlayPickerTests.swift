import XCTest
@testable import Cove

final class AirPlayPickerTests: XCTestCase {
    func testSamePlayerIsUnchanged() {
        let a = NSObject()
        XCTAssertEqual(AirPlayPicker.decide(current: a, new: a, externalActive: true), .unchanged)
        XCTAssertEqual(AirPlayPicker.decide(current: nil, new: nil, externalActive: false), .unchanged)
    }
    func testNewPlayerIsSet() {
        XCTAssertEqual(AirPlayPicker.decide(current: NSObject(), new: NSObject(), externalActive: true), .set)
        XCTAssertEqual(AirPlayPicker.decide(current: nil, new: NSObject(), externalActive: false), .set)
    }
    func testNilNeverClearsDuringAirPlay() {
        XCTAssertEqual(AirPlayPicker.decide(current: NSObject(), new: nil, externalActive: true), .keepWhileExternal)
        XCTAssertEqual(AirPlayPicker.decide(current: NSObject(), new: nil, externalActive: false), .clear)
    }
}
