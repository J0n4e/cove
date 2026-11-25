import XCTest
@testable import Cove

/// Deck: every card is the same Button (no link/button swap when the front card moves back); the collection's
/// movie opens through a link layer over the front card. Undo toast: shown in the search box's place when there is one.
final class DeckUndoToastTests: XCTestCase {
    private func source(_ f: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
    }

    func testDeckCrossFadesAsOnePiece() throws {
        // Owner: back to the pre-redesign deck move — the whole stack cross-fades, the same both ways
        let s = try source("Sources/Classic/ClassicDetail.swift")
        XCTAssertTrue(s.contains(".id(pos)"))
        XCTAssertFalse(s.contains("leavingGone"))
        XCTAssertFalse(s.contains("arrivingSolid"))
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
