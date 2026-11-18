import XCTest
@testable import Cove

final class StatsEmbyFixTests: XCTestCase {
    func testEmbyDayItemsObjectIsDecoded() {
        let json = #"{"user_name":"j","user_id":"a","has_image":false,"activity":[{"Time":"20:15","Id":"42","Name":"Film","Type":"Movie","Client":"Cove","Method":"DirectPlay","Device":"Mac","Duration":"5400","RowId":"7"}]}"#
        let p = StatsDecode.dayPlays(Data(json.utf8), day: "2026-11-01")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.itemId, "42")
    }
}
