import XCTest
@testable import Cove

/// The Library and Home models shared by both themes: paging decisions, generations, filter persistence.
@MainActor
final class SharedLibraryHomeTests: XCTestCase {
    private func items(_ ids: Range<Int>, backdrop: Bool = false) -> [Item] {
        let json = "[" + ids.map { i in
            "{\"Id\":\"i\(i)\",\"Name\":\"T\(i)\"" + (backdrop ? ",\"BackdropImageTags\":[\"b\"]" : "") + "}"
        }.joined(separator: ",") + "]"
        return try! JSONDecoder().decode([Item].self, from: Data(json.utf8))
    }

    private func page(_ start: Int, _ limit: Int, total: Int) -> ItemList {
        ItemList(Items: items(start..<min(start + limit, total)), TotalRecordCount: total)
    }

    private var lib: LibPref { LibPref(id: "L1", name: "Movies", title: "Movies", kind: "movies") }

    private func freshDefaults() -> UserDefaults {
        let name = "SharedLibraryHomeTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    // MARK: Pure paging decisions

    func testGridTriggers() {
        XCTAssertTrue(LibraryModel.gridTriggers(index: 70, count: 100))
        XCTAssertTrue(LibraryModel.gridTriggers(index: 99, count: 100))
        XCTAssertFalse(LibraryModel.gridTriggers(index: 69, count: 100))
        XCTAssertFalse(LibraryModel.gridTriggers(index: 98, count: 100))
    }

    func testListTriggers() {
        let ids = (0..<100).map { "i\($0)" }
        XCTAssertTrue(LibraryModel.listTriggers(id: "i70", ids: ids))
        XCTAssertTrue(LibraryModel.listTriggers(id: "i99", ids: ids))
        XCTAssertFalse(LibraryModel.listTriggers(id: "i50", ids: ids))
        // 30 or fewer rows: only the last one
        let few = (0..<30).map { "i\($0)" }
        XCTAssertTrue(LibraryModel.listTriggers(id: "i29", ids: few))
        XCTAssertFalse(LibraryModel.listTriggers(id: "i0", ids: few))
    }

    func testMayLoad() {
        XCTAssertTrue(LibraryModel.mayLoad(reset: true, loading: true, failed: true, count: 5, total: 5))
        XCTAssertTrue(LibraryModel.mayLoad(reset: false, loading: false, failed: false, count: 100, total: 500))
        XCTAssertFalse(LibraryModel.mayLoad(reset: false, loading: true, failed: false, count: 100, total: 500))
        XCTAssertFalse(LibraryModel.mayLoad(reset: false, loading: false, failed: true, count: 100, total: 500))
        XCTAssertFalse(LibraryModel.mayLoad(reset: false, loading: false, failed: false, count: 500, total: 500))
    }

    // MARK: Model with a stub fetcher

    func testPagesOfAHundredAndSmallLibraryLoadsWhole() async {
        var calls: [(Int, Int)] = []
        let m = LibraryModel(lib: lib, defaults: freshDefaults()) { start, limit, _ in
            calls.append((start, limit)); return self.page(start, limit, total: 250)
        }
        await m.load(reset: true)
        XCTAssertEqual(m.items.count, 250)
        XCTAssertEqual(m.total, 250)
        XCTAssertEqual(calls.map(\.0), [0, 100, 200])
        XCTAssertEqual(Set(calls.map(\.1)), [100])
    }

    func testLargeLibraryLoadsOnePageThenLoadMoreRunsOnce() async {
        var calls = 0
        let m = LibraryModel(lib: lib, defaults: freshDefaults()) { start, limit, _ in
            calls += 1; return self.page(start, limit, total: 1000)
        }
        await m.load(reset: true)
        XCTAssertEqual(m.items.count, 100)
        m.cellWillShow(70); m.cellWillShow(99); m.loadMore()   // one task, not three
        let t = m.pageTask
        XCTAssertNotNil(t)
        await t?.value
        XCTAssertEqual(m.items.count, 200)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(m.pageTask)
        m.cellWillShow(50)   // not a trigger
        XCTAssertNil(m.pageTask)
    }

    func testResetBumpsGenerationAndDropsStaleResult() async {
        var gate: CheckedContinuation<Void, Never>?
        var slow = true
        let m = LibraryModel(lib: lib, defaults: freshDefaults()) { start, limit, sort in
            if slow { slow = false; await withCheckedContinuation { gate = $0 } }
            return ItemList(Items: self.items(sort == "name" ? 0..<3 : 10..<12), TotalRecordCount: sort == "name" ? 3 : 2)
        }
        let stale = Task { await m.load(reset: true) }
        while gate == nil { await Task.yield() }
        let g0 = m.gen
        m.sort = "latest"
        await m.load(reset: true)
        XCTAssertEqual(m.gen, g0 + 1)
        XCTAssertEqual(m.items.map(\.id), ["i10", "i11"])
        gate?.resume()
        await stale.value
        XCTAssertEqual(m.items.map(\.id), ["i10", "i11"], "the older load's result is dropped")
        XCTAssertEqual(m.total, 2)
    }

    func testFailedPageKeepsItemsAndRetryContinues() async {
        var fail = false
        let m = LibraryModel(lib: lib, defaults: freshDefaults()) { start, limit, _ in
            fail ? nil : self.page(start, limit, total: 1000)
        }
        await m.load(reset: true)
        fail = true
        await m.load(reset: false)
        XCTAssertTrue(m.loadFailed)
        XCTAssertEqual(m.items.count, 100)
        m.loadMore(); await m.pageTask?.value   // blocked until Retry
        XCTAssertEqual(m.items.count, 100)
        fail = false
        m.loadFailed = false   // what retry() effectively allows: a new page load
        await m.load(reset: false)
        XCTAssertEqual(m.items.count, 200)
    }

    func testCancelDropsPageTask() async {
        let m = LibraryModel(lib: lib, defaults: freshDefaults()) { start, limit, _ in self.page(start, limit, total: 1000) }
        await m.load(reset: true)
        m.loadMore()
        XCTAssertNotNil(m.pageTask)
        m.cancel()
        XCTAssertNil(m.pageTask)
    }

    func testFiltersPersistUnderSameKey() {
        let d = freshDefaults()
        d.set("list", forKey: "defaultLibraryLayout")
        let m = LibraryModel(lib: lib, defaults: d)
        XCTAssertEqual(m.sort, "name"); XCTAssertEqual(m.layout, "list"); XCTAssertFalse(m.desc)
        m.sort = "latest"; m.sortChanged(); m.genre = "Drama"; m.layout = "grid"
        XCTAssertTrue(m.desc)
        m.save(d)
        let saved = d.dictionary(forKey: "lf-L1")
        XCTAssertEqual(saved?["sort"] as? String, "latest")
        XCTAssertEqual(saved?["genre"] as? String, "Drama")
        let again = LibraryModel(lib: lib, defaults: d)
        XCTAssertEqual(again.sort, "latest"); XCTAssertTrue(again.desc); XCTAssertEqual(again.layout, "grid")
        XCTAssertEqual(again.genre, "Drama"); XCTAssertTrue(again.filtered)
    }

    // MARK: Home

    func testHeroItems() {
        let a = items(0..<5, backdrop: true), b = items(0..<2, backdrop: true) + items(5..<7)
        let hero = HomeModel.heroItems([a, b])
        XCTAssertEqual(hero.map(\.id), ["i0", "i1"])   // two per row, the second row's titles already taken
        let many = (0..<6).map { r in items((r * 10)..<(r * 10 + 3), backdrop: true) }
        XCTAssertEqual(HomeModel.heroItems(many).count, 8)
    }

    func testHomeLoadAndRetry() async {
        let m = HomeModel(prefetchRows: false) { [] }
        XCTAssertTrue(m.loading)
        await m.load()
        XCTAssertFalse(m.loading)
        let k = m.taskKey(3)
        m.retry()
        XCTAssertTrue(m.loading)
        XCTAssertNotEqual(m.taskKey(3), k)
        XCTAssertEqual(m.taskKey(3), "3-1")
    }
}
