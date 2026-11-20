import XCTest
@testable import Cove

@MainActor
final class BannerSourceTests: XCTestCase {
    private func item(_ id: String, type: String = "Movie", backdrop: Bool = true, played: Bool = false,
                      series: String? = nil, created: String? = nil, added: String? = nil) -> Item {
        var o: [String: Any] = ["Id": id, "Name": "T" + id, "Type": type, "UserData": ["Played": played]]
        if backdrop { o["BackdropImageTags"] = ["b"] }
        if let series { o["SeriesName"] = series }
        if let created { o["DateCreated"] = created }
        if let added { o["DateLastContentAdded"] = added }
        return try! JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func testSettingValues() {
        XCTAssertEqual(BannerSource.key, "bannerSource")
        XCTAssertEqual(BannerSource.defaultValue, "rows")
        XCTAssertEqual(BannerSource.options.map(\.0), ["rows", "newest", "random", "favorites"])
        XCTAssertEqual(BannerSource.options.map(\.1), ["From Home rows", "Newest", "Random picks", "Favorites"])
        for (v, _) in BannerSource.options { XCTAssertNotNil(BannerSource(rawValue: v)) }
    }

    func testRowsModeUnchanged() {
        let rows = [(0..<5).map { item("a\($0)") }, (0..<3).map { item("b\($0)") }]
        XCTAssertEqual(BannerSource.resolve(.rows, rows: rows, fetched: [item("x")]).map(\.id), HomeModel.heroItems(rows).map(\.id))
        XCTAssertEqual(HomeModel.heroItems(rows).map(\.id), ["a0", "a1", "b0", "b1"])
    }

    func testPickFiltersDedupesAndCaps() {
        let list = [item("1", backdrop: false), item("2"), item("2b", series: "T2"), item("e", type: "Episode"),
                    item("box", type: "BoxSet"), item("s", type: "Series")] + (10..<30).map { item("\($0)") }
        let p = BannerSource.pick(list)
        XCTAssertEqual(p.count, 8)
        XCTAssertEqual(Array(p.map(\.id).prefix(3)), ["2", "s", "10"])
        XCTAssertEqual(Set(p.map(\.heroTitle)).count, 8)
    }

    func testRandomPrefersUnwatched() {
        let many = (0..<5).map { item("u\($0)") } + (0..<5).map { item("w\($0)", played: true) }
        XCTAssertTrue(BannerSource.preferUnwatched(many).allSatisfy { $0.UserData?.Played != true })
        let few = (0..<3).map { item("u\($0)") } + (0..<5).map { item("w\($0)", played: true) }
        XCTAssertEqual(BannerSource.preferUnwatched(few).count, 8)
    }

    func testNewestMergesMoviesAndShows() {
        let l = [item("m1", created: "2026-01-02"), item("m2", created: "2026-01-05"),
                 item("s1", type: "Series", created: "2020-01-01", added: "2026-01-04")]
        XCTAssertEqual(BannerSource.newestFirst(l).map(\.id), ["m2", "s1", "m1"])
    }

    func testFavoritesEmptyFallsBackToRows() async {
        let rows = [Row(title: "R", items: [item("r1"), item("r2")])]
        let m = HomeModel(prefetchRows: false, load: { rows }, heroLoad: { _ in [] }, source: { .favorites })
        await m.load()
        XCTAssertEqual(m.heroItems.map(\.id), ["r1", "r2"])
        let failed = HomeModel(prefetchRows: false, load: { rows }, heroLoad: { _ in nil }, source: { .newest })
        await failed.load()
        XCTAssertEqual(failed.heroItems.map(\.id), ["r1", "r2"])
    }

    func testFetchedSourceUsedAndSettingChangeReloads() async {
        let rows = [Row(title: "R", items: [item("r1")])]
        final class Box { var s = BannerSource.favorites }
        let box = Box()
        let m = HomeModel(prefetchRows: false, load: { rows },
                          heroLoad: { s in s == .favorites ? [self.item("f1"), self.item("f1"), self.item("f2", backdrop: false)] : [self.item("n1")] },
                          source: { box.s })
        await m.load()
        XCTAssertEqual(m.heroItems.map(\.id), ["f1"])
        box.s = .newest
        await m.sourceChanged()
        XCTAssertEqual(m.heroItems.map(\.id), ["n1"])
        box.s = .rows
        await m.sourceChanged()
        XCTAssertEqual(m.heroItems.map(\.id), ["r1"])
    }
}
