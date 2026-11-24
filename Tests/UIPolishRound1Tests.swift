import XCTest
@testable import Cove
import SwiftUI

/// UI polish round 1: tokens (motion, elevation, spacing, radius), shared components' pure parts and a lint
/// guard against new raw fonts / radius literals.
final class UIPolishRound1Tests: XCTestCase {
    typealias T = Glass3DTokens

    // MARK: Motion
    func testMotionDurations() {
        XCTAssertEqual(T.Motion.duration(.fast), 0.15)
        XCTAssertEqual(T.Motion.duration(.standard), 0.22)
        XCTAssertEqual(T.Motion.duration(.slow), 0.3)
        XCTAssertLessThan(T.Motion.duration(.fast), T.Motion.duration(.standard))
        XCTAssertLessThan(T.Motion.duration(.standard), T.Motion.duration(.slow))
    }

    func testReduceMotionMakesEverythingInstant() {
        for s in T.Motion.Speed.allCases {
            XCTAssertEqual(T.Motion.duration(s, reduceMotion: true), 0)
            XCTAssertEqual(T.Motion.duration(s, reduceMotion: false), T.Motion.duration(s))
            XCTAssertNil(T.Motion.resolved(T.Motion.animation(s), reduceMotion: true))
            XCTAssertNotNil(T.Motion.resolved(T.Motion.animation(s), reduceMotion: false))
        }
        XCTAssertFalse(T.Motion.allowsLoop(reduceMotion: true))
        XCTAssertTrue(T.Motion.allowsLoop(reduceMotion: false))
        XCTAssertEqual(T.Motion.springDamping, 0.86)
    }

    // MARK: Elevation
    func testElevationRecipes() {
        let flat = T.elevation(0)
        XCTAssertEqual(flat.fill, 0); XCTAssertEqual(flat.stroke, 0); XCTAssertNil(flat.shadow)
        XCTAssertEqual(T.elevation(1).fill, 0.05); XCTAssertEqual(T.elevation(1).stroke, 0.10); XCTAssertNil(T.elevation(1).shadow)
        let card = T.elevation(2)
        XCTAssertEqual(card.fill, 0.07); XCTAssertEqual(card.stroke, 0.14); XCTAssertEqual(card.highlight, 0.22)
        XCTAssertEqual(card.shadow, T.Shadow(radius: 8, y: 3, opacity: 0.35))
        XCTAssertEqual(T.elevation(3).backgroundFill, 0.75)
        XCTAssertEqual(T.elevation(4).shadow, T.Shadow(radius: 28, y: 12, opacity: 0.5))
    }

    func testElevationRisesAndClamps() {
        for l in 1...4 {
            XCTAssertGreaterThan(T.elevation(l).stroke, T.elevation(l - 1).stroke)
            XCTAssertGreaterThan(T.elevation(l).highlight, T.elevation(l - 1).highlight)
        }
        XCTAssertEqual(T.elevation(-3), T.elevation(0))
        XCTAssertEqual(T.elevation(9), T.elevation(4))
    }

    // MARK: Scales
    func testSpacingAndRadiusScales() {
        let space = [T.Space.xs, T.Space.s, T.Space.m, T.Space.l, T.Space.xl]
        XCTAssertEqual(space, space.sorted()); XCTAssertEqual(Set(space).count, space.count)
        XCTAssertEqual(T.Space.l, 14)   // GlassCard's default padding = the admin card's
        XCTAssertEqual(T.Radius.button, 9)
        XCTAssertEqual(T.Radius.window, 16); XCTAssertEqual(T.Radius.hero, 18); XCTAssertEqual(T.Radius.banner, 22)
    }

    // MARK: Components
    func testEmptyStateText() {
        XCTAssertEqual(EmptyState.spoken(title: "No matches", message: "Try again."), "No matches. Try again.")
        XCTAssertEqual(EmptyState.spoken(title: "Nothing here.", message: nil), "Nothing here.")
        XCTAssertEqual(EmptyState.spoken(title: "A", message: ""), "A")
        XCTAssertEqual(EmptyState.helpNoMatch("subs"), "No help topic matches \u{201C}subs\u{201D}.")
    }

    func testSkeletonBand() {
        XCTAssertEqual(SkeletonShimmer.bandOffset(phase: 0, width: 200), -100)
        XCTAssertEqual(SkeletonShimmer.bandOffset(phase: 1, width: 200), 200)
        XCTAssertEqual(SkeletonShimmer.bandOffset(phase: 5, width: 200), 200)
        XCTAssertEqual(SkeletonShimmer.blockCount(0), 1)
        XCTAssertEqual(SkeletonShimmer.blockCount(4), 4)
    }

    func testButtonPressAndHoverNeverScaleOnlyLight() {
        XCTAssertLessThan(GlassButtonStyle.brightness(pressed: true, hover: true), 0)
        XCTAssertGreaterThan(GlassButtonStyle.brightness(pressed: false, hover: true), 0)
        XCTAssertEqual(GlassButtonStyle.brightness(pressed: false, hover: false), 0)
        XCTAssertTrue(GlassButtonStyle.isSolid(.primary)); XCTAssertTrue(GlassButtonStyle.isSolid(.destructive))
        XCTAssertFalse(GlassButtonStyle.isSolid(.secondary)); XCTAssertFalse(GlassButtonStyle.isSolid(.lift(backing: true)))
    }

    func testBadgesAndHeaders() {
        XCTAssertEqual(CountBadge.text(3), "3")
        XCTAssertEqual(CountBadge.text(100), "99+")
        XCTAssertEqual(SectionHeader.shown("Server", style: .eyebrow), "SERVER")
        XCTAssertEqual(SectionHeader.shown("Server", style: .page), "Server")
    }

    // MARK: Lint guard
    /// Every Swift file under Sources/.
    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let u = e?.nextObject() as? URL {
            if u.pathExtension == "swift" { out.append((u.lastPathComponent, try String(contentsOf: u, encoding: .utf8))) }
        }
        XCTAssertGreaterThan(out.count, 50)
        return out
    }

    func testNoNewRawSystemFonts() throws {
        // Fixed-size glyph fonts (rating badges), the font helpers themselves and the Year in review share
        // image (ImageRenderer at a fixed pixel size) are the only allowed places.
        let allowed: Set<String> = ["RatingButton.swift", "YearReviewView.swift", "ClassicFont.swift", "TextScale.swift"]
        for (name, text) in try sources() where !allowed.contains(name) {
            XCTAssertFalse(text.contains(".font(.system(size:"), "\(name): use cvFont / coveFont")
        }
    }

    func testNoCornerRadiusLiterals() throws {
        let re = try NSRegularExpression(pattern: #"cornerRadius(: *|\()[0-9]"#)
        for (name, text) in try sources() {
            let n = re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(n, 0, "\(name): use Glass3DTokens.Radius")
        }
    }

    func testNoSystemStatusColours() throws {
        for (name, text) in try sources() {
            for bad in ["Color.red", "Color.green", "Color.orange", ".foregroundColor(.red)", ".foregroundColor(.orange)", ".foregroundColor(.green)"] {
                XCTAssertFalse(text.contains(bad), "\(name): \(bad) → Glass3DTokens.Status")
            }
        }
    }
}
