import XCTest

/// The whole lit area of tabs, pills, dropdowns and glass buttons clicks, not only their text/icon glyphs:
/// the shared components carry a `contentShape` covering their visible shape.
final class FullHitAreaTests: XCTestCase {
    private func src(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testPlainHandHitsWholeLabel() throws {
        XCTAssertTrue(try src("Sources/Shared/Components.swift").contains("configuration.label.contentShape(Rectangle())"))
    }

    func testGlassButtonStyleHitsWholeFace() throws {
        XCTAssertTrue(try src("Sources/Classic/Glass3DComponents/GlassButtonStyle.swift").contains("Group { face }.contentShape(Rectangle())"))
    }

    func testSegmentTabsAndTabHover() throws {
        XCTAssertTrue(try src("Sources/Classic/Glass3DSegmentTabs.swift").contains(".contentShape(Capsule())"))
        XCTAssertTrue(try src("Sources/Classic/Glass3DTabHover.swift").contains(".contentShape(Rectangle())"))
    }

    func testGlassPillAndClearGlass() throws {
        let s = try src("Sources/ClassicPill.swift")
        XCTAssertTrue(s.contains("styled(content).contentShape(Capsule())"))
        XCTAssertGreaterThanOrEqual(s.components(separatedBy: ".contentShape(shape)").count - 1, 2)
    }

    func testDropdownPills() throws {
        XCTAssertTrue(try src("Sources/GlassDropdown.swift").contains(".contentShape(Capsule())"))
        let y = try src("Sources/Stats/YearReviewView.swift")
        XCTAssertGreaterThanOrEqual(y.components(separatedBy: ".contentShape(Capsule())").count - 1, 2)
    }
}
