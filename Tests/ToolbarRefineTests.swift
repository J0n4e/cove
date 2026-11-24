import XCTest
@testable import Cove

/// The refined top toolbar: overflow into More, library icons, Activity marker rules, tokens and wiring.
final class ToolbarRefineTests: XCTestCase {
    typealias O = ToolbarOverflow
    let ids = ["home", "favorites", "movies", "shows", "docs", "nowplaying"]
    let w: [String: CGFloat] = ["home": 100, "favorites": 110, "movies": 100, "shows": 100, "docs": 120, "nowplaying": 110]

    // MARK: Overflow split
    func testEverythingFitsNoMore() {
        let s = O.split(ids, widths: w, available: 1000, spacing: 6, moreWidth: 44, selected: "home")
        XCTAssertEqual(s.visible, ids)
        XCTAssertTrue(s.overflow.isEmpty)
    }

    func testNotMeasuredShowsAll() {
        XCTAssertEqual(O.split(ids, widths: w, available: 0, spacing: 6, moreWidth: 44, selected: "home").visible, ids)
    }

    func testOverflowLeavesFromTheEndKeepingHomeActivityAndOrder() {
        // total = 640 + 30 = 670; available 500 → drop docs (−126 → 544), shows (→ 438) + 6 + 44 = 488 ≤ 500
        let s = O.split(ids, widths: w, available: 500, spacing: 6, moreWidth: 44, selected: "home")
        XCTAssertEqual(s.visible, ["home", "favorites", "movies", "nowplaying"])
        XCTAssertEqual(s.overflow, ["shows", "docs"])   // bar order inside More
        XCTAssertEqual(s.visible.last, "nowplaying")     // Activity stays last visible
    }

    func testSelectionStaysVisible() {
        let s = O.split(ids, widths: w, available: 500, spacing: 6, moreWidth: 44, selected: "docs")
        XCTAssertTrue(s.visible.contains("docs"))
        XCTAssertTrue(s.visible.contains("home"))
        XCTAssertFalse(s.overflow.contains("docs"))
        XCTAssertEqual(Set(s.visible + s.overflow), Set(ids))
    }

    func testVeryNarrowKeepsOnlyPinned() {
        let s = O.split(ids, widths: w, available: 100, spacing: 6, moreWidth: 44, selected: "movies")
        XCTAssertEqual(s.visible, ["home", "movies", "nowplaying"])
        XCTAssertEqual(s.overflow, ["favorites", "shows", "docs"])
    }

    // MARK: Library icons
    func testDocumentaryUsesVideoNotFolder() {
        XCTAssertEqual(LibraryIcon.symbol(kind: nil, name: "Documentary"), "video")
        XCTAssertEqual(LibraryIcon.symbol(kind: nil, name: "Documentaries"), "video")
        XCTAssertEqual(LibraryIcon.symbol(kind: "movies", name: "Documentaries"), "video")
        XCTAssertEqual(LibraryIcon.symbol(kind: nil, name: "Dokumentationen"), "video")
        XCTAssertEqual(ClassicPageTitle.icon(nil, name: "Documentary", style: .clean), "video")
    }

    func testTypedLibrariesNeverGetAFolder() {
        XCTAssertEqual(LibraryIcon.symbol(kind: "movies"), "film")
        XCTAssertEqual(LibraryIcon.symbol(kind: "tvshows"), "tv")
        XCTAssertEqual(LibraryIcon.symbol(kind: "boxsets"), "square.stack")
        XCTAssertEqual(LibraryIcon.symbol(kind: "music"), "music.note")
        XCTAssertEqual(LibraryIcon.symbol(kind: "homevideos"), "video")
        for k in ["musicvideos", "books", "playlists", "livetv"] {
            XCTAssertNotEqual(LibraryIcon.symbol(kind: k), "folder", k)
        }
        XCTAssertEqual(LibraryIcon.symbol(kind: nil, name: "Mixed stuff"), "folder")   // untyped stays a folder
    }

    // MARK: Activity markers
    func testBadgeVisibilityRules() {
        XCTAssertFalse(ToolbarBadges.showDot(unread: 0))
        XCTAssertTrue(ToolbarBadges.showDot(unread: 1))
        XCTAssertFalse(ToolbarBadges.showCount(streams: 0))
        XCTAssertTrue(ToolbarBadges.showCount(streams: 2))
        XCTAssertEqual(CountBadge.text(3), "3")
    }

    // MARK: Tokens and wiring
    func testTokens() {
        let t = Glass3DTokens.Toolbar.self
        XCTAssertLessThanOrEqual(t.labelShadow.opacity, 0.3)   // at most a very faint shadow
        XCTAssertLessThanOrEqual(t.labelShadow.radius, 1)
        XCTAssertGreaterThan(t.tint, 0)
        XCTAssertLessThan(t.tint, 1)                           // still translucent
        XCTAssertLessThanOrEqual(t.hairline, 1)
        XCTAssertGreaterThan(t.selectedFill, 0)
        XCTAssertEqual(t.iconWeight, Glass3DTokens.Icon.weight)
    }

    func testBarIsWiredWithoutHeavyShadows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/Classic/ClassicRoot.swift"), encoding: .utf8)
        let comp = try String(contentsOf: root.appendingPathComponent("Sources/Classic/Glass3DToolbar.swift"), encoding: .utf8)
        XCTAssertTrue(bar.contains("ToolbarBarSurface()"))
        XCTAssertTrue(bar.contains("ToolbarMoreButton("))
        XCTAssertTrue(bar.contains("ToolbarOverflow.split("))
        XCTAssertFalse(bar.contains("Glass3DTabHover"))   // no dark double shadow, no hover scaling
        XCTAssertFalse(bar.contains("Text3D("))
        XCTAssertTrue(comp.contains(".environment(\\.colorScheme, .dark)"))   // readable in light appearance
        XCTAssertFalse(comp.contains(".shadow("))
        XCTAssertFalse(comp.contains("scaleEffect"))
    }

    // MARK: Toolbar style (Classic default / Clean optional)
    func testDefaultIsClassic() {
        XCTAssertEqual(ToolbarStyle.defaultValue, .classic)
        XCTAssertEqual(ToolbarStyle(raw: ""), .classic)
        XCTAssertEqual(ToolbarStyle(raw: "bogus"), .classic)
        XCTAssertEqual(ToolbarStyle(raw: "clean"), .clean)
        XCTAssertEqual(ToolbarStyle.key, "toolbarStyle")
        XCTAssertEqual(ToolbarStyle.options.map(\.0), ["classic", "clean"])
    }

    func testClassicIconMapIsTheOldOne() {
        let old: [String?: String] = ["movies": "film", "tvshows": "tv", "boxsets": "square.stack", "music": "music.note",
                                      "homevideos": "video", "musicvideos": "folder", "books": "folder",
                                      "playlists": "folder", "livetv": "folder", nil: "folder"]
        for (k, v) in old { XCTAssertEqual(LibraryIcon.symbol(kind: k, name: "x", style: .classic), v, k ?? "nil") }
        XCTAssertEqual(LibraryIcon.symbol(kind: nil, name: "Documentary", style: .classic), "folder")
        XCTAssertEqual(ClassicPageTitle.icon(nil, name: "Documentary"), "folder")   // page title default = classic
    }

    func testCleanIconMap() {
        XCTAssertEqual(LibraryIcon.symbol(kind: nil, name: "Documentary", style: .clean), "video")
        XCTAssertEqual(LibraryIcon.symbol(kind: "musicvideos", style: .clean), "music.note.tv")
        XCTAssertEqual(LibraryIcon.symbol(kind: "books", style: .clean), "book")
        XCTAssertEqual(LibraryIcon.symbol(kind: "playlists", style: .clean), "music.note.list")
        XCTAssertEqual(LibraryIcon.symbol(kind: "livetv", style: .clean), "antenna.radiowaves.left.and.right")
    }

    func testOverflowAndMarkersPerStyle() {
        XCTAssertTrue(ToolbarStyle.clean.usesOverflowMenu)
        XCTAssertFalse(ToolbarStyle.classic.usesOverflowMenu)
        XCTAssertTrue(ToolbarStyle.clean.markersOnIcon)
        XCTAssertFalse(ToolbarStyle.classic.markersOnIcon)
    }

    func testClassicPathRestoredAndWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
        let classic = try src("Sources/Classic/ClassicToolbarClassic.swift")
        XCTAssertTrue(classic.contains("ViewThatFits(in: .horizontal)"))       // icons-only, then sideways scroll
        XCTAssertTrue(classic.contains("Glass3DTabHover(on: on)"))
        XCTAssertTrue(classic.contains("Text3D(text: title"))
        XCTAssertTrue(classic.contains("ActivityUnreadDot(inset: 7)"))           // dot inside the pill
        XCTAssertTrue(classic.contains("if badge > 0 { CountBadge(count: badge) }"))  // count after the name
        XCTAssertTrue(classic.contains(".classicClearGlass()"))
        XCTAssertFalse(classic.contains("ToolbarMoreButton"))
        let bar = try src("Sources/Classic/ClassicRoot.swift")
        XCTAssertTrue(bar.contains("ClassicTopNavCenterClassic()"))
        XCTAssertTrue(bar.contains("ActivityUnreadDot(inset: 7)"))               // classic sidebar row
        let settings = try src("Sources/Settings.swift")
        XCTAssertTrue(settings.contains("PrefRow(label: \"Toolbar style\")"))
        XCTAssertTrue(settings.contains("ToolbarStyle.options"))
    }
}
