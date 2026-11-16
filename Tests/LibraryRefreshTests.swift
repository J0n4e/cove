import XCTest
@testable import Cove

/// Unwatched/Watched libraries follow the local watched state at once (no server request), and the header's count
/// drops with what's hidden.
@MainActor
final class LibraryRefreshTests: XCTestCase {
    /// i0 unplayed, i1 played, i2 without UserData (counts as unplayed), by the server's UserData.
    private func items() -> [Item] {
        let json = """
        [{"Id":"i0","Name":"A","UserData":{"Played":false}},
         {"Id":"i1","Name":"B","UserData":{"Played":true}},
         {"Id":"i2","Name":"C"}]
        """
        return try! JSONDecoder().decode([Item].self, from: Data(json.utf8))
    }

    private func ids(_ v: [Item]) -> [String] { v.map(\.id) }

    func testAllShowsEverything() {
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "all", played: ["i0": true])), ["i0", "i1", "i2"])
    }

    func testUnwatchedFallsBackToUserData() {
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "unwatched", played: [:])), ["i0", "i2"])
    }

    func testUnwatchedHidesLocallyPlayed() {
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "unwatched", played: ["i0": true])), ["i2"])
        // Marked unplayed locally: back in
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "unwatched", played: ["i1": false])), ["i0", "i1", "i2"])
    }

    func testWatchedHidesLocallyUnplayed() {
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "watched", played: [:])), ["i1"])
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "watched", played: ["i1": false])), [])
        XCTAssertEqual(ids(LibraryModel.visible(items(), watch: "watched", played: ["i2": true])), ["i1", "i2"])
    }

    func testVisibleTotal() {
        XCTAssertEqual(LibraryModel.visibleTotal(total: 250, loaded: 100, visible: 99), 249)
        XCTAssertEqual(LibraryModel.visibleTotal(total: 3, loaded: 3, visible: 3), 3)
        XCTAssertEqual(LibraryModel.visibleTotal(total: 1, loaded: 3, visible: 0), 0)
    }

    func testModelUsesPlayedMapAndKeepsFullCountForPaging() async {
        let all = items()
        let m = LibraryModel(lib: LibPref(id: "LR", name: "Movies", title: "Movies", kind: "movies"),
                             defaults: UserDefaults(suiteName: "LibraryRefreshTests-\(UUID().uuidString)")!,
                             fetch: { start, _, _ in ItemList(Items: start == 0 ? all : [], TotalRecordCount: 3) })
        m.watch = "unwatched"
        await m.load(reset: true)
        XCTAssertEqual(m.visibleCount, 2)          // i1 already hidden by its UserData
        m.played = ["i0": true]
        XCTAssertEqual(ids(m.visibleItems), ["i2"])
        XCTAssertEqual(m.visibleCount, 1)
        XCTAssertEqual(m.items.count, 3)           // paging still counts every loaded item
    }

    // Paging after items were hidden locally: the server's filtered list already lost them

    func testNextStartSkipsNothing() {
        XCTAssertEqual(LibraryModel.nextStart(loaded: 100, hidden: 0), 100)
        XCTAssertEqual(LibraryModel.nextStart(loaded: 100, hidden: 2), 98)   // 2 watched since: start 2 earlier
        XCTAssertEqual(LibraryModel.nextStart(loaded: 3, hidden: 5), 0)
    }

    func testAppendPageDropsRepeats() {
        let all = items()
        let shown = [all[0], all[2]]
        XCTAssertEqual(ids(LibraryModel.appendPage(shown, [all[2], all[1]])), ["i0", "i2", "i1"])
    }
}
