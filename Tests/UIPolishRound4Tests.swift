import XCTest
@testable import Cove
import SwiftUI

/// UI polish round 4: micro-interactions (press, menu pop-in, ♡/✓ symbol swap, keyboard focus ring,
/// skeleton → content crossfade, specular top edge), all from the existing tokens.
final class UIPolishRound4Tests: XCTestCase {
    typealias T = Glass3DTokens

    // MARK: 1 Press feedback
    func testPressRecipeDarkensWithoutScale() {
        XCTAssertEqual(T.Press.brightness, -0.08)
        XCTAssertEqual(T.Press.scale, 1)
        XCTAssertEqual(T.Press.animation, T.Motion.fast)
        XCTAssertEqual(GlassButtonStyle.brightness(pressed: true, hover: false), T.Press.brightness)
        XCTAssertEqual(GlassButtonStyle.brightness(pressed: true, hover: true), T.Press.brightness)
        XCTAssertEqual(GlassButtonStyle.hoverBrightness(false), 0)
        XCTAssertGreaterThan(T.Press.shadeOpacity, 0)
    }

    func testButtonStylesHaveNoPressedScale() throws {
        for f in ["Sources/Classic/Glass3DComponents/GlassButtonStyle.swift", "Sources/Shared/Components.swift",
                  "Sources/Classic/Glass3DComponents/Interactions.swift"] {
            let s = try source(f)
            XCTAssertFalse(s.contains("isPressed ? 0.9"), f)
            let re = try NSRegularExpression(pattern: #"scaleEffect\([^)]*isPressed"#)
            XCTAssertEqual(re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)), 0, f)
        }
        let style = try source("Sources/Classic/Glass3DComponents/GlassButtonStyle.swift")
        XCTAssertFalse(style.contains("scaleEffect"))
        XCTAssertGreaterThanOrEqual(style.components(separatedBy: ".pressFeedback(").count - 1, 5)   // every kind
        XCTAssertTrue(try source("Sources/Shared/Components.swift").contains(".pressFeedback(configuration.isPressed"))
    }

    // MARK: 2 Menus
    func testMenusPopInWithOneMotionToken() throws {
        XCTAssertEqual(T.Menu.animation, T.Motion.fast)
        for f in ["Sources/GlassDropdown.swift", "Sources/Classic/Glass3DProfileCircle.swift"] {
            let s = try source(f)
            XCTAssertTrue(s.contains(".transition(.coveMenuPopIn)"), f)
            XCTAssertTrue(s.contains("Glass3DTokens.Menu.animation"), f)
        }
        XCTAssertFalse(try source("Sources/Shared/GlassPopIn.swift").contains("scale"))
    }

    // MARK: 3 Symbol swap
    func testHeartAndCheckSwapTheirSymbol() throws {
        XCTAssertTrue(SymbolSwap.usesReplaceEffect)
        XCTAssertTrue(try source("Sources/Classic/Glass3DComponents/Interactions.swift")
            .contains("contentTransition(.symbolEffect(.replace))"))
        for f in ["Sources/Classic/Glass3DPosterBadges.swift", "Sources/Classic/ClassicDetail.swift",
                  "Sources/Shared/Components.swift"] {
            XCTAssertTrue(try source(f).contains(".symbolSwap()"), f)
        }
        XCTAssertEqual(PosterBadges.favSymbol(fav: true, hover: false), PosterBadges.favSymbol(fav: true, hover: true))
    }

    // MARK: 4 Focus ring
    func testFocusRingOnlyWhereTheFocusEffectIsOn() throws {
        XCTAssertTrue(FocusGlow<Capsule>.shows(focused: true, effectEnabled: true))
        XCTAssertFalse(FocusGlow<Capsule>.shows(focused: true, effectEnabled: false))   // dialogs (.focusEffectDisabled)
        XCTAssertFalse(FocusGlow<Capsule>.shows(focused: false, effectEnabled: true))
        XCTAssertLessThan(T.FocusRing.opacity, 1)
        XCTAssertTrue(try source("Sources/Classic/Glass3DComponents/GlassButtonStyle.swift").contains(".focusGlow(focused"))
        XCTAssertTrue(try source("Sources/Classic/ClassicLogin.swift").contains(".focusGlowField("))
    }

    // MARK: 5 Crossfade
    func testSkeletonsCrossfadeOnMotionStandard() throws {
        XCTAssertEqual(T.Crossfade.animation, T.Motion.standard)
        for (path, text) in try sources() where text.contains("SkeletonShimmer(") && !path.hasSuffix("SkeletonShimmer.swift") {
            let lines = text.components(separatedBy: "\n").filter { $0.contains("SkeletonShimmer(") }
            for l in lines { XCTAssertTrue(l.contains(".skeletonCrossfade()"), "\(path): \(l)") }
        }
        XCTAssertTrue(try source("Sources/Classic/Glass3DComponents/EmptyState.swift").contains(".skeletonCrossfade()"))
    }

    // MARK: 6 Specular edge
    func testSpecularEdgeOnEveryRaisedLevel() throws {
        XCTAssertEqual(T.Specular.opacity(level: 0), 0)
        XCTAssertEqual(T.Specular.opacity(level: 1), 0)
        for level in 2...4 {
            XCTAssertGreaterThan(T.Specular.opacity(level: level), 0, "level \(level)")
            XCTAssertEqual(T.Specular.opacity(level: level), T.elevation(level).highlight)
        }
        XCTAssertEqual(T.Specular.lineWidth, 1)
        XCTAssertTrue(try source("Sources/Classic/Glass3DComponents/Elevation.swift").contains(".specularEdge(level: level"))
        let menu = try source("Sources/Classic/Glass3DComponents/MenuAndToast.swift")
        XCTAssertTrue(menu.contains(".specularEdge(level: Glass3DTokens.Menu.level"))
        XCTAssertEqual(menu.components(separatedBy: ".specularEdge(level: Glass3DTokens.Toast.level").count - 1, 2)
        XCTAssertTrue(try source("Sources/GlassWindow.swift").contains("SpecularEdgeView"))
        XCTAssertGreaterThanOrEqual(SpecularEdgeView.level, T.Specular.minLevel)
    }

    // MARK: Helpers
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func sources() throws -> [(String, String)] {
        let base = root.appendingPathComponent("Sources")
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let u = e?.nextObject() as? URL {
            guard u.pathExtension == "swift" else { continue }
            out.append((u.lastPathComponent, try String(contentsOf: u, encoding: .utf8)))
        }
        return out
    }
}
