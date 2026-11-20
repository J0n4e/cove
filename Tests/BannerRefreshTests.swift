import XCTest
@testable import Cove

@MainActor
final class BannerRefreshTests: XCTestCase {
    private func item(_ id: String, backdrop: Bool = true) -> Item {
        var o: [String: Any] = ["Id": id, "Name": "T" + id, "Type": "Movie"]
        if backdrop { o["BackdropImageTags"] = ["b"] }
        return try! JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func testIntervalValuesAndDefault() {
        XCTAssertEqual(BannerRefresh.key, "bannerRefresh")
        XCTAssertEqual(BannerRefresh.defaultValue, 0)
        XCTAssertEqual(BannerRefresh.options.map(\.0), [0, 15, 30, 60])
        XCTAssertEqual(BannerRefresh.options.map(\.1), ["Only when Home loads", "Every 15 min", "Every 30 min", "Every hour"])
    }

    func testRowsRotationChangesAndWraps() {
        let rows = [(0..<5).map { item("a\($0)") }, (0..<3).map { item("b\($0)") } + [item("nb", backdrop: false)]]
        // Round 0 is exactly today's banner
        XCTAssertEqual(BannerRefresh.rotatedRows(rows, round: 0).map(\.id), HomeModel.heroItems(rows).map(\.id))
        XCTAssertEqual(BannerRefresh.rotatedRows(rows, round: 1).map(\.id), ["a2", "a3", "b2", "b0"])
        XCTAssertNotEqual(BannerRefresh.rotatedRows(rows, round: 1).map(\.id), BannerRefresh.rotatedRows(rows, round: 0).map(\.id))
        XCTAssertEqual(BannerRefresh.rotatedRows(rows, round: 2).map(\.id), ["a4", "a0", "b1", "b2"])
        XCTAssertEqual(BannerRefresh.rotatedRows(rows, round: 3).map(\.id), ["a1", "a2", "b0", "b1"])
        XCTAssertLessThanOrEqual(BannerRefresh.rotatedRows(Array(repeating: rows[0], count: 1) + (0..<6).map { r in (0..<4).map { item("r\(r)-\($0)") } }, round: 1).count, 8)
    }

    func testRandomAvoidsPreviousSet() {
        let previous = (0..<8).map { item("p\($0)") }
        let fetched = ((0..<8).map { item("p\($0)") } + (0..<10).map { item("n\($0)") }).shuffled()
        let picked = BannerSource.pick(BannerRefresh.avoidingPrevious(fetched, previous: previous))
        XCTAssertEqual(picked.count, 8)
        XCTAssertTrue(Set(picked.map(\.id)).isDisjoint(with: previous.map(\.id)))
        // Not enough new titles: the previous ones fill up
        let few = [item("p0"), item("n0"), item("p1")]
        XCTAssertEqual(BannerSource.pick(BannerRefresh.avoidingPrevious(few, previous: previous)).map(\.id), ["n0", "p0", "p1"])
    }

    func testIsDue() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(BannerRefresh.isDue(minutes: 0, last: t0, now: t0 + 99_999, visible: true, playing: false))
        XCTAssertFalse(BannerRefresh.isDue(minutes: 15, last: t0, now: t0 + 14 * 60, visible: true, playing: false))
        XCTAssertTrue(BannerRefresh.isDue(minutes: 15, last: t0, now: t0 + 15 * 60, visible: true, playing: false))
        XCTAssertFalse(BannerRefresh.isDue(minutes: 15, last: t0, now: t0 + 3600, visible: false, playing: false))
        XCTAssertFalse(BannerRefresh.isDue(minutes: 15, last: t0, now: t0 + 3600, visible: true, playing: true))
    }

    func testNoRefreshWhenHiddenThenOnceWhenVisible() async {
        final class Box { var now = Date(timeIntervalSince1970: 0); var visible = false; var fetches = 0 }
        let box = Box()
        let rows = [Row(title: "R", items: (0..<6).map { item("r\($0)") })]
        let m = HomeModel(prefetchRows: false, load: { rows }, heroLoad: { _ in box.fetches += 1; return nil },
                          source: { .rows }, refreshEvery: { 15 }, visible: { box.visible }, playing: { false },
                          now: { box.now })
        await m.load()
        let first = m.heroItems.map(\.id)
        XCTAssertEqual(first, ["r0", "r1"])
        box.now += 16 * 60
        let hidden = await m.refreshBannerIfDue()
        XCTAssertFalse(hidden)
        XCTAssertEqual(m.heroItems.map(\.id), first)
        XCTAssertEqual(m.heroGeneration, 0)
        box.visible = true
        let shown = await m.refreshBannerIfDue()
        XCTAssertTrue(shown)
        XCTAssertEqual(m.heroItems.map(\.id), ["r2", "r3"])
        XCTAssertEqual(m.heroGeneration, 1)
        let again = await m.refreshBannerIfDue()   // once: the interval starts over
        XCTAssertFalse(again)
        XCTAssertEqual(box.fetches, 0)              // rows mode never queries the server
    }

    func testRandomRefreshRequeriesAndAvoidsRepeat() async {
        final class Box { var now = Date(timeIntervalSince1970: 0); var n = 0 }
        let box = Box()
        let pool = (0..<16).map { item("x\($0)") }
        let m = HomeModel(prefetchRows: false, load: { [] },
                          heroLoad: { _ in box.n += 1; return pool },
                          source: { .random }, refreshEvery: { 30 }, visible: { true }, playing: { false }, now: { box.now })
        await m.load()
        let first = Set(m.heroItems.map(\.id))
        XCTAssertEqual(first.count, 8)
        box.now += 31 * 60
        let did = await m.refreshBannerIfDue()
        XCTAssertTrue(did)
        XCTAssertEqual(box.n, 2)
        XCTAssertTrue(first.isDisjoint(with: m.heroItems.map(\.id)))
    }
}
