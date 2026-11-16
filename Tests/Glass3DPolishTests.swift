import XCTest
@testable import Cove

/// Glass3D polish: the A–Z thinning, the Glass setting's frosting amount and the server menu's title.
final class Glass3DPolishTests: XCTestCase {
    let letters = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    func testAllLettersWhenTheyFit() {
        XCTAssertEqual(AlphaBar.thin(letters, slots: 27), letters)
        XCTAssertEqual(AlphaBar.thin(letters, slots: 100), letters)
    }

    func testEveryOtherLetterWhenTooShort() {
        let t = AlphaBar.thin(letters, slots: 20)
        XCTAssertEqual(t.first, "#")
        XCTAssertEqual(Array(t.prefix(3)), ["#", "B", "D"])
        XCTAssertLessThanOrEqual(t.count, 20)
        XCTAssertEqual(t.count, 14)
    }

    func testThinningAlwaysFitsAndKeepsOrder() {
        for slots in 1...40 {
            let t = AlphaBar.thin(letters, slots: slots)
            XCTAssertLessThanOrEqual(t.count, slots)
            XCTAssertFalse(t.isEmpty)
            XCTAssertEqual(t.first, "#")
            XCTAssertEqual(t, letters.filter { t.contains($0) })   // order kept, no duplicates
        }
        XCTAssertEqual(AlphaBar.thin(letters, slots: 0), [])
        XCTAssertEqual(AlphaBar.thin([], slots: 5), [])
    }

    func testSlotsFromHeight() {
        XCTAssertEqual(AlphaBar.slots(height: 0), 0)
        XCTAssertEqual(AlphaBar.slots(height: .infinity), 0)
        XCTAssertEqual(AlphaBar.slots(height: 12 + 21 * 27), 27)
        XCTAssertEqual(AlphaBar.slots(height: 12 + 21 * 10 + 5), 10)
    }

    func testFrostFollowingMacOSAddsNothingOnLiquidGlass() {
        XCTAssertEqual(GlassFrost.amount(follow: true, frost: 0.9, liquidGlass: true), 0)
        XCTAssertEqual(GlassFrost.amount(follow: false, frost: 0.9, liquidGlass: true), 0.9, accuracy: 1e-9)
    }

    func testFrostAlwaysAppliesBeforeLiquidGlass() {
        XCTAssertEqual(GlassFrost.amount(follow: true, frost: 0.5, liquidGlass: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GlassFrost.amount(follow: false, frost: 2, liquidGlass: false), 1)
        XCTAssertEqual(GlassFrost.amount(follow: false, frost: -1, liquidGlass: false), 0)
        XCTAssertEqual(GlassFrost.amount(follow: false, frost: .nan, liquidGlass: false), GlassFrost.defaultFrost)
    }

    func testFrostLayersGrowWithTheAmount() {
        XCTAssertEqual(GlassFrost.layers(0).blur, 0)
        XCTAssertEqual(GlassFrost.layers(0).tint, 0)
        XCTAssertLessThan(GlassFrost.layers(0.5).tint, GlassFrost.layers(1).tint)
        XCTAssertEqual(GlassFrost.layers(1).blur, 1)
    }

    func testServerMenuTitle() {
        XCTAssertEqual(ServerMenu.title(name: "Home Jellyfin", address: "http://10.0.0.2:8096"), "Home Jellyfin")
        XCTAssertEqual(ServerMenu.title(name: "  ", address: "http://media.example.com:8096"), "media.example.com")
        XCTAssertEqual(ServerMenu.title(name: "", address: "weird"), "weird")
        let long = ServerMenu.title(name: String(repeating: "x", count: 50), address: "")
        XCTAssertEqual(long.count, 30)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(ServerMenu.title(name: String(repeating: "y", count: 30), address: ""), String(repeating: "y", count: 30))
    }
}
