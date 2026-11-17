import XCTest
@testable import Cove

/// v1.18.1 owner notes: Home reloads on a server/user change; pop-up cards don't wake the player controls.
@MainActor
final class OwnerNotes1181Tests: XCTestCase {
    func waitUntil(_ cond: () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testTaskKeyChangesWithSession() {
        let m = HomeModel(prefetchRows: false, load: { [] })
        let a = HomeModel.sessionKey(server: "https://a", userId: "u1")
        let b = HomeModel.sessionKey(server: "https://b", userId: "u1")
        let c = HomeModel.sessionKey(server: "https://a", userId: "u2")
        XCTAssertNotEqual(m.taskKey(0, session: a), m.taskKey(0, session: b))
        XCTAssertNotEqual(m.taskKey(0, session: a), m.taskKey(0, session: c))
        XCTAssertEqual(m.taskKey(0, session: a), m.taskKey(0, session: a))
    }

    func testReloadOnSessionChangeShowsNewServersRows() async {
        final class Box { var server = "A" }
        let box = Box()
        let m = HomeModel(prefetchRows: false, load: { [Row(title: box.server, items: [])] })
        await m.load(session: "A|u")
        XCTAssertEqual(m.rows.map(\.title), ["A"])
        box.server = "B"
        await m.load(session: "B|u")
        XCTAssertEqual(m.rows.map(\.title), ["B"])
        XCTAssertEqual(m.loadedSession, "B|u")
        XCTAssertFalse(m.loading)
    }

    func testCancelledOldLoadDoesNotOverwrite() async {
        let m = HomeModel(prefetchRows: false, load: {
            try? await Task.sleep(for: .milliseconds(300)); return [Row(title: "old", items: [])]
        })
        let t = Task { await m.load(session: "A|u") }
        try? await Task.sleep(for: .milliseconds(50))
        t.cancel()
        await t.value
        XCTAssertTrue(m.rows.isEmpty)
    }

    func testPointerMove() {
        XCTAssertTrue(PlayerUIModel.isPointerMove(from: nil, to: .zero))
        XCTAssertFalse(PlayerUIModel.isPointerMove(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(PlayerUIModel.isPointerMove(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.3, y: 9.8)))
        XCTAssertTrue(PlayerUIModel.isPointerMove(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 10)))
    }

    func testStillPointerHoverDoesNotShowControls() {
        let ui = PlayerUIModel(style: .classic)
        ui.pointer(.active(CGPoint(x: 100, y: 100)))
        ui.showUI = false   // auto-hidden
        // The Up next card appears under the still pointer: SwiftUI sends hover again at the same point
        ui.pointer(.active(CGPoint(x: 100, y: 100)))
        ui.pointer(.ended)
        ui.pointer(.active(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(ui.showUI)
        XCTAssertFalse(ui.controlsVisible)
        ui.pointer(.active(CGPoint(x: 140, y: 100)))   // a real move
        XCTAssertTrue(ui.showUI)
    }
}
