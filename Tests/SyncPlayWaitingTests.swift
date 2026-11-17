import XCTest
@testable import Cove

// v1.18.1: the "Waiting for others…" pill at the top of the player while the SyncPlay group waits.

@MainActor
final class SyncPlayWaitingTests: XCTestCase {
    func testMapping() {
        XCTAssertNil(SyncPlayGroup.waitingText(state: nil, selfStalled: false))
        XCTAssertNil(SyncPlayGroup.waitingText(state: "Playing", selfStalled: false))
        XCTAssertNil(SyncPlayGroup.waitingText(state: "Paused", selfStalled: true))
        XCTAssertNil(SyncPlayGroup.waitingText(state: "Idle", selfStalled: false))
        XCTAssertEqual(SyncPlayGroup.waitingText(state: "Waiting", selfStalled: false), "Waiting for others…")
        XCTAssertEqual(SyncPlayGroup.waitingText(state: "Waiting", selfStalled: false, waitingFor: "ldoctoru"),
                       "Waiting for ldoctoru…")
        XCTAssertEqual(SyncPlayGroup.waitingText(state: "Waiting", selfStalled: false, waitingFor: ""),
                       "Waiting for others…")
        XCTAssertEqual(SyncPlayGroup.waitingText(state: "Waiting", selfStalled: true, waitingFor: "ldoctoru"),
                       "Buffering… the group is waiting for you")
    }

    private func msg(_ s: String) -> SocketMessage {
        guard let m = SocketEnvelope.decode(s)?.message else { XCTFail("didn't decode: \(s)"); return .other("") }
        return m
    }

    func testStateUpdateDrivesThePill() {
        let g = SyncPlayGroup()
        g.runsDriver = false
        g.log = { _ in }
        g.handle(msg(GroupFixtures.groupJoined))
        XCTAssertNil(SyncPlayToast.waiting(g))
        // Server-shaped GroupUpdate StateUpdate {State: Waiting, Reason: Buffering}
        g.handle(msg(GroupFixtures.update("StateUpdate", #"{"State":"Waiting","Reason":"Buffering"}"#)))
        XCTAssertEqual(g.info?.state, "Waiting")
        XCTAssertEqual(SyncPlayToast.waiting(g), "Waiting for others…")
        g.handle(msg(GroupFixtures.update("StateUpdate", #"{"State":"Playing","Reason":"Ready"}"#)))
        XCTAssertNil(SyncPlayToast.waiting(g))
        g.handle(msg(GroupFixtures.update("StateUpdate", #"{"State":"Waiting","Reason":"Buffering"}"#)))
        g.handle(msg(GroupFixtures.update("StateUpdate", #"{"State":"Paused","Reason":"Pause"}"#)))
        XCTAssertNil(SyncPlayToast.waiting(g))
    }
}
