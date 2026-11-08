import XCTest
@testable import Cove

/// Checks for the parts that don't need a server or the UI.
@MainActor
final class CoveTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Emby.normalize("  myserver:8096/ "), "http://myserver:8096")
        XCTAssertEqual(Emby.normalize("https://a.b//"), "https://a.b")
        XCTAssertEqual(Emby.normalize("HTTP://A.B"), "HTTP://A.B")
    }

    func testSameOrigin() {
        let u = { (s: String) in URL(string: s)! }
        XCTAssertTrue(Net.sameOrigin(u("http://Host:8096/a"), u("http://host:8096/b")))
        XCTAssertTrue(Net.sameOrigin(u("https://host/a"), u("https://host:443")))
        XCTAssertFalse(Net.sameOrigin(u("http://host/a"), u("https://host/a")))
        XCTAssertFalse(Net.sameOrigin(u("http://host:8096"), u("http://other:8096")))
    }

    func testWithoutVideoCopy() {
        let s = Emby.withoutVideoCopy("http://h/v.mp4?a=1&allowvideostreamcopy=true")
        XCTAssertTrue(s.contains("a=1"))
        XCTAssertTrue(s.contains("AllowVideoStreamCopy=false"))
        XCTAssertFalse(s.contains("allowvideostreamcopy=true"))
    }

    func testSavedServerRoundTrip() throws {
        let a = [SavedServer(url: "http://Host:8096", name: "Home", user: "me", token: "t", userId: "u")]
        let b = try JSONDecoder().decode([SavedServer].self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, b)
        XCTAssertEqual(b[0].id, "http://host:8096")
    }

    /// Lists saved by older versions (no token / user id) must still load.
    func testSavedServerOldFormat() throws {
        let old = #"[{"url":"http://h","name":"n","user":"x"}]"#.data(using: .utf8)!
        let b = try JSONDecoder().decode([SavedServer].self, from: old)
        XCTAssertNil(b[0].token)
    }

    func testFavoritesPlace() {
        XCTAssertNil(FavoritesPlace.afterIndex(0, libCount: 5))       // usual place after Home
        XCTAssertEqual(FavoritesPlace.afterIndex(2, libCount: 5), 1)  // after the 2nd library
        XCTAssertEqual(FavoritesPlace.afterIndex(9, libCount: 3), 2)  // libraries removed since: stays last
        XCTAssertNil(FavoritesPlace.afterIndex(3, libCount: 0))       // not signed in yet
    }
}
