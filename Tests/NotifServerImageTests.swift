import XCTest
@testable import Cove

final class NotifServerImageTests: XCTestCase {
    func testImageServerIsTheEntrysOwn() {
        XCTAssertEqual(NotificationInbox.imageServer(stored: "https://b.example", current: "https://a.example"), "https://b.example")
        // Old entries without a server → the current one
        XCTAssertEqual(NotificationInbox.imageServer(stored: "", current: "https://a.example/"), "https://a.example")
        let img = StoredNotificationImage(id: "42", kind: "Backdrop")
        let u = NotificationInbox.imageURL(server: NotificationInbox.imageServer(stored: "https://b.example", current: "https://a.example"), img)
        XCTAssertEqual(u?.host, "b.example")
        XCTAssertTrue(u?.absoluteString.contains("EnableImageEnhancers=false") ?? false)
        XCTAssertFalse(u?.absoluteString.contains("api_key") ?? true)   // the token goes in a header, never the link
    }

    func testOtherServerHeaders() {
        let tokens = ["https://b.example": "tok"]
        XCTAssertEqual(NotificationInbox.otherServerHeaders(server: "https://B.example", current: "https://a.example", tokens: tokens),
                       ["X-Emby-Token": "tok"])
        XCTAssertEqual(NotificationInbox.otherServerHeaders(server: "https://a.example", current: "https://a.example", tokens: tokens), [:])
        XCTAssertEqual(NotificationInbox.otherServerHeaders(server: "https://c.example", current: "https://a.example", tokens: tokens), [:])
    }
}
