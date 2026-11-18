import XCTest
@testable import Cove

final class StabilityTests: XCTestCase {
    func testBoundedMapKeepsCapAndEvictsOldestWritten() {
        var m = BoundedMap<Int>(cap: 3)
        m["a"] = 1; m["b"] = 2; m["c"] = 3
        m["a"] = 10            // rewritten: now the newest
        m["d"] = 4             // evicts b, the oldest write
        XCTAssertEqual(m.count, 3)
        XCTAssertNil(m["b"])
        XCTAssertEqual(m["a"], 10); XCTAssertEqual(m["c"], 3); XCTAssertEqual(m["d"], 4)
    }

    func testBoundedMapStaysBoundedUnderManyWrites() {
        var m = BoundedMap<Int>(cap: 100)
        for i in 0..<50_000 { m["k\(i % 300)"] = i }
        XCTAssertEqual(m.count, 100)
        XCTAssertEqual(m["k199"], 49_999)
        m["k199"] = nil
        XCTAssertEqual(m.count, 99)
        m.removeAll()
        XCTAssertEqual(m.count, 0); XCTAssertNil(m["k298"])
    }

    func testBlurHashKeepsEarlierHashesPastOldLimit() {
        BlurHash.lock.withLock { BlurHash.hashes.removeAll() }
        for i in 0..<2_500 { BlurHash.remember("id\(i)", "Primary", "h\(i)") }
        // The old code cleared everything at 2,000 entries
        XCTAssertEqual(BlurHash.lock.withLock { BlurHash.hashes["id0|Primary"] }, "h0")
        BlurHash.lock.withLock { BlurHash.hashes.removeAll() }
    }

    func testGridDiffAppendedTail() {
        XCTAssertEqual(GridDiff.appendedTail(old: ["a", "b"], new: ["a", "b", "c", "d"]), 2..<4)
        XCTAssertNil(GridDiff.appendedTail(old: [], new: ["a"]))                 // first load: reload
        XCTAssertNil(GridDiff.appendedTail(old: ["a", "b"], new: ["a", "b"]))    // no change
        XCTAssertNil(GridDiff.appendedTail(old: ["a", "b"], new: ["b", "a", "c"]))
        XCTAssertNil(GridDiff.appendedTail(old: ["a", "b"], new: ["a"]))          // item hidden (watched filter)
    }
}
