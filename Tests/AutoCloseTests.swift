import XCTest
@testable import Cove

final class AutoCloseTests: XCTestCase {
    private func s(active: Bool = true, key: AutoClose.NewKey = .other, keep: Bool = false,
                   modal: Bool = false, recent: Bool = false) -> AutoClose.Situation {
        AutoClose.Situation(appActive: active, newKey: key, keepOpen: keep, hasModal: modal, openedRecently: recent)
    }

    func testClosesWhenAnotherWindowBecomesKey() { XCTAssertTrue(AutoClose.shouldClose(s())) }
    func testClosesWhenAnotherAppIsActive() { XCTAssertTrue(AutoClose.shouldClose(s(active: false, key: .none))) }
    func testStaysForMenusAndRelatedWindows() {
        XCTAssertFalse(AutoClose.shouldClose(s(key: .none)))
        XCTAssertFalse(AutoClose.shouldClose(s(key: .itself)))
        XCTAssertFalse(AutoClose.shouldClose(s(key: .related)))
    }
    func testStaysWithUnsavedChangesModalOrWhileOpening() {
        XCTAssertFalse(AutoClose.shouldClose(s(keep: true)))
        XCTAssertFalse(AutoClose.shouldClose(s(active: false, keep: true)))
        XCTAssertFalse(AutoClose.shouldClose(s(modal: true)))
        XCTAssertFalse(AutoClose.shouldClose(s(recent: true)))
    }
    func testOpenedRecently() {
        let now = Date()
        XCTAssertFalse(AutoClose.openedRecently(shownAt: nil, now: now))
        XCTAssertTrue(AutoClose.openedRecently(shownAt: now.addingTimeInterval(-0.2), now: now))
        XCTAssertFalse(AutoClose.openedRecently(shownAt: now.addingTimeInterval(-0.6), now: now))
    }
}
