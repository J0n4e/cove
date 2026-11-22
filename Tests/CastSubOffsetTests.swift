import XCTest
@testable import Cove

final class CastSubOffsetTests: XCTestCase {
    func testShiftLater() {
        let c = CastVTT.shift([Cue(start: 10, end: 12, text: "a")], offsetMs: 1500)
        XCTAssertEqual(c.first?.start ?? 0, 11.5, accuracy: 0.0001)
        XCTAssertEqual(c.first?.end ?? 0, 13.5, accuracy: 0.0001)
    }

    func testNegativeClampsAtZero() {
        let cues = [Cue(start: 0.5, end: 3, text: "first"), Cue(start: 0.2, end: 0.8, text: "gone"),
                    Cue(start: 10, end: 12, text: "b")]
        let c = CastVTT.shift(cues, offsetMs: -1000)
        XCTAssertEqual(c.count, 2)              // the cue ending before 0 is dropped
        XCTAssertEqual(c[0].start, 0)           // clamped at 0
        XCTAssertEqual(c[0].end, 2, accuracy: 0.0001)
        XCTAssertEqual(c[1].start, 9, accuracy: 0.0001)
    }

    func testVTTUsesOffset() {
        let v = CastVTT.make([Cue(start: 1, end: 2, text: "hi")], offsetMs: 500)
        XCTAssertTrue(v.contains("00:00:01.500 --> 00:00:02.500"), v)
        let n = CastVTT.make([Cue(start: 1, end: 2, text: "hi")], offsetMs: -1500)
        XCTAssertTrue(n.contains("00:00:00.000 --> 00:00:00.500"), n)
        XCTAssertEqual(CastVTT.make([Cue(start: 1, end: 2, text: "hi")]), CastVTT.make([Cue(start: 1, end: 2, text: "hi")], offsetMs: 0))
    }

    func testLabelsAndBurnIn() {
        XCTAssertEqual(CastSubOffset.label(0), "No offset")
        XCTAssertEqual(CastSubOffset.label(300), "+0.3 s")
        XCTAssertEqual(CastSubOffset.label(-1200), "\u{2212}1.2 s")
        XCTAssertFalse(CastSubOffset.adjustable(hasSub: true, isImage: true))
        XCTAssertTrue(CastSubOffset.adjustable(hasSub: true, isImage: false))
    }
}
