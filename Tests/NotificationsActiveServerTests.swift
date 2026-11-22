import XCTest
@testable import Cove

@MainActor
final class NotificationsActiveServerTests: XCTestCase {
    func testOnlyActiveServer() {
        XCTAssertTrue(NotificationInbox.isServer("http://a:8096/", "http://A:8096"))
        XCTAssertFalse(NotificationInbox.isServer("http://b:8096", "http://a:8096"))
        XCTAssertTrue(NotificationInbox.isServer("", "http://a:8096"))       // old entries without a server
        XCTAssertTrue(NotificationInbox.isServer("http://b:8096", ""))       // before sign-in
    }
}
