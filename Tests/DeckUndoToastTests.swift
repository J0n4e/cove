import XCTest
@testable import Cove

/// Deck: every card is the same Button (no link/button swap when the front card moves back); the collection's
/// movie opens through a link layer over the front card. Undo toast: shown in the search box's place when there is one.
final class DeckUndoToastTests: XCTestCase {
    private func source(_ f: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
    }

    func testOnlyTheFrontCardLinks() {
        XCTAssertEqual(DeckFrontLink.target(k: 0, item: "movie"), "movie")
        XCTAssertNil(DeckFrontLink.target(k: 1, item: "movie"))
        XCTAssertNil(DeckFrontLink.target(k: 3, item: "movie"))
        XCTAssertNil(DeckFrontLink.target(k: 0, item: nil as String?))   // series: no link
    }

    func testDeckCardsKeepOneViewType() throws {
        let s = try source("Sources/Classic/ClassicDetail.swift")
        let start = try XCTUnwrap(s.range(of: "func deckButton"))
        let end = try XCTUnwrap(s.range(of: "func frontLink", range: start.upperBound..<s.endIndex))
        let body = String(s[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("NavigationLink"), "deck cards are always a Button")
        XCTAssertFalse(body.contains(".transition(.identity)"))
        XCTAssertTrue(s.contains(".overlay { frontLink(p, k: k) }"))
    }

    func testUndoToastPlacement() {
        XCTAssertEqual(UndoToastPlacement.decide(searchSlotOnScreen: true), .searchSlot)
        XCTAssertEqual(UndoToastPlacement.decide(searchSlotOnScreen: false), .floating)
    }

    func testUndoToastUsesTheSearchBoxLook() throws {
        let dock = try source("Sources/Shared/SearchDock.swift")
        XCTAssertTrue(dock.contains("DeleteUndoToastView("))
        XCTAssertTrue(dock.contains(".coveGlassPopIn(value: undo.current?.id)"))
        let toast = try source("Sources/Classic/Glass3DDeleteEverywhere.swift")
        XCTAssertTrue(toast.contains("height: SearchDock.boxHeight).searchGlass()"))
        XCTAssertTrue(toast.contains(".seconds(15)"))
    }
}
