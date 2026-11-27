import XCTest
@testable import Cove
import SwiftUI

/// Settings → Appearance → Pill hover: one shared effect for every glass pill / button.
final class PillHoverEffectTests: XCTestCase {
    typealias S = PillHoverStyle

    func testRawValuesAndDefaults() {
        XCTAssertEqual(S.allCases.map(\.rawValue), ["edge", "sweep", "glow", "lift", "none"])
        XCTAssertEqual(S.key, "pillHover")
        XCTAssertEqual(S.softPressKey, "pillSoftPress")
        XCTAssertEqual(S.defaultValue, .edge)
        XCTAssertTrue(S.defaultSoftPress)
        XCTAssertEqual(S.resolve("bogus"), .edge)
        XCTAssertEqual(S.resolve(""), .edge)
        XCTAssertEqual(S.resolve("lift"), .lift)
        XCTAssertEqual(S.options.map(\.1), ["Accent edge", "Light sweep", "Glow", "Lift", "None"])
    }

    func testTokens() {
        let fx = Glass3DTokens.PillFX.self
        XCTAssertEqual(fx.edgeOpacity, 0.85); XCTAssertEqual(fx.edgeWidth, 1.5)
        XCTAssertEqual(fx.sweepSeconds, 0.6)
        XCTAssertEqual(fx.glowRadius, 10); XCTAssertEqual(fx.glowOpacity, 0.5)
        XCTAssertEqual(fx.liftScale, 1.02); XCTAssertEqual(fx.pressScale, 0.96)
    }

    func testScaleAndReduceMotion() {
        XCTAssertEqual(S.scale(.lift, hover: true, pressed: false, softPress: true, reduceMotion: false), 1.02)
        XCTAssertEqual(S.scale(.edge, hover: true, pressed: false, softPress: true, reduceMotion: false), 1)
        XCTAssertEqual(S.scale(.none, hover: true, pressed: true, softPress: true, reduceMotion: false), 0.96)
        XCTAssertEqual(S.scale(.glow, hover: true, pressed: true, softPress: false, reduceMotion: false), 1)
        for s in S.allCases {
            XCTAssertEqual(S.scale(s, hover: true, pressed: true, softPress: true, reduceMotion: true), 1)
            XCTAssertEqual(S.scale(s, hover: true, pressed: false, softPress: true, reduceMotion: true), 1)
            XCTAssertFalse(S.sweeps(s, reduceMotion: true))
            XCTAssertEqual(S.scale(s, hover: false, pressed: false, softPress: true, reduceMotion: false), 1)   // at rest
        }
        XCTAssertTrue(S.sweeps(.sweep, reduceMotion: false))
        XCTAssertFalse(S.sweeps(.edge, reduceMotion: false))
        XCTAssertTrue(S.drawsEdge(.edge, hover: true)); XCTAssertFalse(S.drawsEdge(.edge, hover: false))
        XCTAssertTrue(S.drawsGlow(.glow, hover: true)); XCTAssertFalse(S.drawsGlow(.edge, hover: true))
    }

    func testSharedModifierIsUsedByEveryPillStyle() throws {
        let button = try source("Sources/Classic/Glass3DComponents/GlassButtonStyle.swift")
        XCTAssertEqual(button.components(separatedBy: ".pillHoverEffect(hover: hover, pressed: c.isPressed").count - 1, 3)
        XCTAssertFalse(button.contains("scaleEffect"))
        XCTAssertTrue(try source("Sources/ClassicPill.swift").contains(".pillHoverEffect(hover: hover, in: Capsule())"))
        XCTAssertTrue(try source("Sources/Classic/Glass3DTabHover.swift").contains(".pillHoverEffect("))
        XCTAssertEqual(try source("Sources/Classic/Glass3DToolbar.swift").components(separatedBy: ".pillHoverEffect(").count - 1, 2)
        let fx = try source("Sources/Classic/Glass3DComponents/PillHoverEffect.swift")
        XCTAssertTrue(fx.contains("accessibilityReduceMotion"))
        XCTAssertTrue(fx.contains("Glass3DTokens.Motion.fast"))
        XCTAssertTrue(fx.contains(".clipShape(shape)"))
        XCTAssertTrue(fx.contains(".allowsHitTesting(false)"))
    }

    func testSettingIsInAppearance() throws {
        let s = try source("Sources/Settings.swift")
        XCTAssertTrue(s.contains("PrefRow(label: \"Pill hover\")"))
        XCTAssertTrue(s.contains("Toggle(\"Soft press\", isOn: $pillSoftPress)"))
        XCTAssertTrue(s.contains("PillHoverPreview()"))
        XCTAssertFalse(s.contains("\"Glass3D"))
        XCTAssertTrue(try source("Sources/Help/HelpTopics.swift").contains("Pill hover"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
