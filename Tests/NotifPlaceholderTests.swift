import XCTest
@testable import Cove

final class NotifPlaceholderTests: XCTestCase {
    func testPlaceholders() {
        for t in ["-", " – ", "TBA", "tbd", "Episode 23", "Episode #23", ""] {
            XCTAssertTrue(NewMediaDetector.isPlaceholderTitle(t, index: 23), t)
        }
        for t in ["The Queen is Dead", "Pilot", "Episode of Doom"] {
            XCTAssertFalse(NewMediaDetector.isPlaceholderTitle(t, index: 1), t)
        }
    }
}
