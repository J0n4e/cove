import XCTest
@testable import Cove
import SwiftUI

/// Settings → Appearance → Hover effect: the five newer looks.
final class TopBarHoverStylesTests: XCTestCase {
    func testEightOptionsInOrder() {
        XCTAssertEqual(HoverStyle.options.map(\.0), ["fog", "glow", "glass", "slide", "spot", "underline", "frost", "pulse"])
        XCTAssertEqual(HoverStyle.options.map(\.1), ["Fogged mirror", "Soft glow", "Liquid lens", "Sliding light",
                                                     "Spotlight", "Underline glow", "Frosted rise", "Colour pulse"])
    }

    func testKnownKeysKeptUnknownFallBackToDefault() {
        for (k, _) in HoverStyle.options { XCTAssertEqual(HoverStyle.normalized(k), k) }
        XCTAssertEqual(HoverStyle.normalized(nil), "fog")
        XCTAssertEqual(HoverStyle.normalized("sparkle"), "fog")
        XCTAssertEqual(HoverStyle.normalized(""), "fog")
        XCTAssertTrue(HoverStyle.slides("slide"))
        XCTAssertFalse(HoverStyle.slides("bogus"))
    }

    func testReduceMotionMakesThemPlainFades() {
        XCTAssertEqual(HoverStyle.riseScale(shown: true, reduceMotion: false), Glass3DTokens.TopBarHover.riseScale)
        XCTAssertEqual(HoverStyle.riseScale(shown: true, reduceMotion: true), 1)
        XCTAssertEqual(HoverStyle.riseScale(shown: false, reduceMotion: false), 1)
        XCTAssertEqual(HoverStyle.pulseBrightness(peak: true, reduceMotion: false), 0.15, accuracy: 0.001)
        XCTAssertEqual(HoverStyle.pulseBrightness(peak: true, reduceMotion: true), 0)
        XCTAssertEqual(HoverStyle.underlineWidth(shown: false, reduceMotion: false), 0)
        XCTAssertEqual(HoverStyle.underlineWidth(shown: false, reduceMotion: true), Glass3DTokens.TopBarHover.underlineWidth)
    }

    func testSpotlightFollowsThePointerAndCentresWithReduceMotion() {
        let size = CGSize(width: 100, height: 40)
        XCTAssertEqual(HoverStyle.spotCentre(CGPoint(x: 25, y: 10), in: size, reduceMotion: false), UnitPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(HoverStyle.spotCentre(CGPoint(x: 25, y: 10), in: size, reduceMotion: true), .center)
        XCTAssertEqual(HoverStyle.spotCentre(nil, in: size, reduceMotion: false), .center)
        XCTAssertEqual(HoverStyle.spotCentre(CGPoint(x: 300, y: -5), in: size, reduceMotion: false), UnitPoint(x: 1, y: 0))
    }

    func testEachStyleIsHandled() throws {
        let pill = try source("Sources/ClassicPill.swift")
        for k in ["slide", "spot", "underline", "frost", "pulse", "glass", "glow"] {
            XCTAssertTrue(pill.contains("style == \"\(k)\""), k)
        }
        let fx = try source("Sources/Classic/Glass3DTopBarHover.swift")
        XCTAssertTrue(fx.contains(".matchedGeometryEffect(id: \"topBarHover\", in: slide.ns)"))
        XCTAssertTrue(try source("Sources/Classic/ClassicComponents.swift").contains(".onContinuousHover"))
        XCTAssertTrue(fx.contains(".task(id: shown)"))   // the pulse runs once per hover, no loop
        XCTAssertFalse(fx.contains("repeatForever"))
        let bar = try source("Sources/Classic/ClassicToolbarClassic.swift")
        XCTAssertTrue(bar.contains("@Namespace private var hoverNS"))
        XCTAssertTrue(bar.contains("SectionHoverGlow(on: !on, slideId: id)"))
        XCTAssertTrue(try source("Sources/Help/HelpTopics.swift").contains("Sliding light"))
    }

    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func source(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
}
