import XCTest
@testable import Cove

/// v1.18.6 (Glass3D): one poster badge look on every kind, identical at rest and on hover; the Up next countdown
/// in a SyncPlay group.
final class V1186Tests: XCTestCase {
    // MARK: Badges

    func testBadgeStateSameAtRestAndOnHoverForEveryKind() {
        for kind in PosterBadgeState.Kind.allCases {
            for fav in [false, true] {
                for played in [false, true] {
                    for n in [0, 3, 140] {
                        for r in [nil, 8] as [Int?] {
                            XCTAssertEqual(PosterBadgeState.of(kind, fav: fav, played: played, unwatched: n, rating: r, hover: false),
                                           PosterBadgeState.of(kind, fav: fav, played: played, unwatched: n, rating: r, hover: true),
                                           "\(kind) fav \(fav) played \(played) n \(n)")
                        }
                    }
                }
            }
        }
    }

    func testHeartAndCheckAlwaysShown() {
        for kind in PosterBadgeState.Kind.allCases {
            let s = PosterBadgeState.of(kind, fav: false, played: false, hover: false)
            XCTAssertEqual(s.fav, "heart")
            XCTAssertEqual(s.watched, "checkmark")
            XCTAssertTrue(s.dim)
            XCTAssertNil(s.rating)
            let on = PosterBadgeState.of(kind, fav: true, played: true, rating: 9, hover: true)
            XCTAssertEqual(on.fav, "heart.fill")
            XCTAssertFalse(on.dim)
            XCTAssertEqual(on.rating, 9)
        }
    }

    func testUnwatchedCountOnlyForSeriesAndSeasons() {
        XCTAssertEqual(PosterBadgeState.of(.series, fav: false, played: false, unwatched: 12, hover: false).watched, "12")
        XCTAssertTrue(PosterBadgeState.of(.season, fav: false, played: false, unwatched: 4, hover: true).capsule)
        XCTAssertEqual(PosterBadgeState.of(.season, fav: false, played: true, unwatched: 4, hover: false).watched, "checkmark")
        XCTAssertEqual(PosterBadgeState.of(.movie, fav: false, played: false, unwatched: 4, hover: false).watched, "checkmark")
        XCTAssertEqual(PosterBadgeState.of(.collection, fav: false, played: false, unwatched: 4, hover: false).watched, "checkmark")
        XCTAssertEqual(PosterBadgeState.of(.series, fav: false, played: false, unwatched: 140, hover: false).watched, "99+")
    }

    // MARK: Up next in a group

    func testGroupCountdownClockText() {
        XCTAssertEqual(GroupUpNext.clock(12), "0:12")
        XCTAssertEqual(GroupUpNext.clock(65), "1:05")
        XCTAssertEqual(GroupUpNext.clock(-3), "0:00")
        XCTAssertEqual(GroupUpNext.text(12), "Next episode for everyone in 0:12")
    }

    func testGroupCountdownFollowsServerTime() {
        let when = Date(timeIntervalSince1970: 1_000_000)
        let pos = Int64(1300 * SyncPlayGroup.ticksPerSecond)   // the group unpaused at 21:40
        // 1330 s long: 30 s left at the Unpause, 12 s left 18 s later (server time), 0 past the end
        XCTAssertEqual(GroupUpNext.secsLeft(positionTicks: pos, when: when, serverNow: when, duration: 1330), 30)
        XCTAssertEqual(GroupUpNext.secsLeft(positionTicks: pos, when: when, serverNow: when.addingTimeInterval(18), duration: 1330), 12)
        XCTAssertEqual(GroupUpNext.secsLeft(positionTicks: pos, when: when, serverNow: when.addingTimeInterval(17.4), duration: 1330), 13)
        XCTAssertEqual(GroupUpNext.secsLeft(positionTicks: pos, when: when, serverNow: when.addingTimeInterval(60), duration: 1330), 0)
    }

    @MainActor func testOutsideAGroupUsesTheLocalCount() {
        let g = SyncPlayGroup()
        XCTAssertFalse(g.isInGroup)
        XCTAssertEqual(g.upNextSecsLeft(duration: 1330, local: 7), 7)
    }
}
