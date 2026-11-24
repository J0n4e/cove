import XCTest
@testable import Cove

final class WatchIntroPillTests: XCTestCase {
    func testWatchIntroSeeksToStartAndPlays() {
        let a = IntroDecision.watchIntro(introStart: 42)
        XCTAssertEqual(a.seekTo, 42); XCTAssertTrue(a.play); XCTAssertFalse(a.showSkippedPill)
    }
    func testWatchIntroUnknownStartSeeksToZero() {
        XCTAssertEqual(IntroDecision.watchIntro(introStart: nil).seekTo, 0)
    }
    func testAutoSkipSuppressedAfterWatchIntro() {
        let a = IntroDecision.watchIntro(introStart: 10)
        XCTAssertFalse(IntroDecision.shouldAutoSkip(inside: true, introDone: a.introDone, autoSkip: true))
        XCTAssertTrue(IntroDecision.shouldAutoSkip(inside: true, introDone: false, autoSkip: true))
    }
}
