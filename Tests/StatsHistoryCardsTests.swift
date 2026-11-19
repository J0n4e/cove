import XCTest
@testable import Cove

/// Activity → History poster cards: the caption line and same-day merging (×2).
final class StatsHistoryCardsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private func play(_ id: String, type: String = "Movie", name: String = "Film", seconds: Int = 3600,
                      hour: Int = 20, minute: Int = 15, item: String? = nil) -> StatsPlay {
        var c = Calendar(identifier: .gregorian); c.timeZone = utc
        let d = c.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
        return StatsPlay(id: id, start: d, day: "2026-11-10", itemId: item ?? "i" + id, name: name, type: type,
                         client: "Cove", device: "Mac", method: "DirectPlay", seconds: seconds)
    }

    func testCaption() {
        let ep = StatsHistoryCard(play: play("1", type: "Episode", name: "Show - s2e4 - Pilot"), count: 1, seconds: 45 * 60)
        XCTAssertEqual(StatsHistoryText.caption(ep, timeZone: utc), "S2:E4 · 20:15 · 45 min")
        let mv = StatsHistoryCard(play: play("2"), count: 1, seconds: 3600 + 52 * 60)
        XCTAssertEqual(StatsHistoryText.caption(mv, timeZone: utc), "20:15 · 1 h 52 min")
        XCTAssertEqual(StatsHistoryText.length(7200), "2 h")
        XCTAssertEqual(StatsHistoryText.length(20), "1 min")
    }

    func testSameDayMerge() {
        let ps = [play("1", seconds: 1800, hour: 10, item: "m"), play("2", hour: 12, item: "x"),
                  play("3", seconds: 1200, hour: 21, minute: 0, item: "m")]
        let cards = StatsHistoryText.cards(ps)
        XCTAssertEqual(cards.map(\.id), ["m", "x"])          // newest first, one card per title
        XCTAssertEqual(cards[0].count, 2)
        XCTAssertEqual(cards[0].seconds, 3000)
        XCTAssertEqual(cards[0].play.id, "3")                 // the latest play drives the time
        XCTAssertEqual(StatsHistoryText.caption(cards[0], timeZone: utc), "21:00 · 50 min")
        XCTAssertEqual(cards[1].count, 1)
    }

    func testBadgeTip() {
        XCTAssertTrue(StatsHistoryText.badgeTip(play("1")).hasPrefix("Cove · Mac · "))
    }
}
