import XCTest
@testable import Cove

final class HelpTests: XCTestCase {
    func testIdsAreUnique() {
        let ids = HelpTopics.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryTopicHasContent() {
        for t in HelpTopics.all {
            XCTAssertFalse(t.title.isEmpty, t.id)
            XCTAssertFalse(t.symbol.isEmpty, t.id)
            XCTAssertFalse(t.intro.isEmpty, t.id)
            XCTAssertFalse(t.sections.isEmpty, t.id)
            for s in t.sections {
                XCTAssertFalse(s.heading.isEmpty, t.id)
                XCTAssertFalse(s.blocks.isEmpty, t.id + " / " + s.heading)
                for b in s.blocks { XCTAssertFalse(b.plain.trimmingCharacters(in: .whitespaces).isEmpty, t.id) }
            }
        }
    }

    func testBothGroupsHaveTopics() {
        XCTAssertGreaterThanOrEqual(HelpTopics.all.filter { $0.group == .watching }.count, 12)
        XCTAssertGreaterThanOrEqual(HelpTopics.all.filter { $0.group == .admin }.count, 8)
    }

    func testAdminTopicsHiddenForNonAdmins() {
        XCTAssertTrue(HelpSearch.visible(admin: false).allSatisfy { $0.group == .watching })
        XCTAssertTrue(HelpSearch.visible(admin: nil).allSatisfy { $0.group == .watching })
        XCTAssertEqual(HelpSearch.visible(admin: true).count, HelpTopics.all.count)
        // Searching can't bring admin topics back
        let user = HelpSearch.visible(admin: false)
        XCTAssertTrue(HelpSearch.filter(user, query: "Cleanup").allSatisfy { $0.group == .watching })
    }

    func testEmptyQueryKeepsEverything() {
        let all = HelpSearch.visible(admin: true)
        XCTAssertEqual(HelpSearch.filter(all, query: "").map(\.id), all.map(\.id))
        XCTAssertEqual(HelpSearch.filter(all, query: "   ").map(\.id), all.map(\.id))
    }

    func testSearchMatchesTitleAndBody() {
        let all = HelpSearch.visible(admin: true)
        XCTAssertEqual(HelpSearch.filter(all, query: "cleanup").first?.id, "cleanup")   // title first
        XCTAssertTrue(HelpSearch.filter(all, query: "SyncPlay").contains { $0.id == "watch-together" })
        XCTAssertTrue(HelpSearch.filter(all, query: "Cove.log").contains { $0.id == "updates" })   // body text
        XCTAssertTrue(HelpSearch.filter(all, query: "xyzzy-nothing").isEmpty)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let all = HelpSearch.visible(admin: true)
        XCTAssertEqual(HelpSearch.filter(all, query: "PLAYER").map(\.id), HelpSearch.filter(all, query: "player").map(\.id))
        XCTAssertEqual(HelpSearch.filter(all, query: "plåyér").map(\.id), HelpSearch.filter(all, query: "player").map(\.id))
    }

    func testEveryWordMustMatch() {
        let all = HelpSearch.visible(admin: true)
        let r = HelpSearch.filter(all, query: "nexcrate pairing")
        XCTAssertTrue(r.contains { $0.id == "connect" })
        XCTAssertFalse(r.contains { $0.id == "home" })
    }

    func testHighlightRanges() {
        let s = "Open Cleanup, then cleanup again"
        let r = HelpSearch.ranges(in: s, query: "CLEANUP")
        XCTAssertEqual(r.map { String(s[$0]) }, ["Cleanup", "cleanup"])
        XCTAssertTrue(HelpSearch.ranges(in: s, query: "").isEmpty)
    }

    func testProfileMenuHasHelpRow() {
        XCTAssertEqual(ProfileMenuSpec.title(.help), "Cove Help")
    }
}
