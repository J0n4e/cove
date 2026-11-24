import XCTest
@testable import Cove
import SwiftUI

/// UI polish round 2: the thumbnail inner-control hover flag (centre Play AND the Resume ring), the poster shine
/// position math, Ken Burns timing / Reduce Motion, skeleton grid and the new tokens.
final class UIPolishRound2Tests: XCTestCase {
    typealias T = Glass3DTokens

    // MARK: Ring / Play hover → card border off
    func testCardBorderOffWhileOnAnInnerControl() {
        XCTAssertTrue(ThumbnailHover.cardLit(hover: true, innerControl: false))
        // the pointer on Play or on the Resume ring: same flag, card unlit
        XCTAssertFalse(ThumbnailHover.cardLit(hover: true, innerControl: true))
        XCTAssertFalse(ThumbnailHover.cardLit(hover: false, innerControl: false))
        XCTAssertFalse(ThumbnailHover.cardLit(hover: false, innerControl: true))
    }

    func testLeavingTheCardClearsTheInnerFlag() {
        XCTAssertFalse(ThumbnailHover.innerAfterCardHover(false, inner: true))
        XCTAssertTrue(ThumbnailHover.innerAfterCardHover(true, inner: true))
        XCTAssertFalse(ThumbnailHover.innerAfterCardHover(true, inner: false))
    }

    func testResumeRingReportsToTheCard() throws {
        // The ring must share the Play button's flag (owner screenshot bug): guard the wiring in the source
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let ring = try String(contentsOf: root.appendingPathComponent("Sources/Classic/Glass3DProgress.swift"), encoding: .utf8)
        let start = try XCTUnwrap(ring.range(of: "struct ThumbnailResumeRing"))
        let end = try XCTUnwrap(ring.range(of: "struct ResumeRingMark"))
        XCTAssertTrue(ring[start.lowerBound..<end.lowerBound].contains(".reportsThumbnailInnerHover()"))
        let home = try String(contentsOf: root.appendingPathComponent("Sources/Classic/ClassicHome.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("ThumbnailInnerHoverScope(flag: $onPlay, value: onPlay)"))
        let comps = try String(contentsOf: root.appendingPathComponent("Sources/Shared/Components.swift"), encoding: .utf8)
        XCTAssertTrue(comps.contains("ThumbnailInnerHoverScope(flag: $inner, value: inner)"))
    }

    // MARK: Poster shine
    func testShineFollowsThePointer() {
        let size = CGSize(width: 150, height: 225)
        XCTAssertEqual(PosterShineMath.unit(location: CGPoint(x: 75, y: 45), size: size, reduceMotion: false),
                       CGPoint(x: 0.5, y: 0.2))
        // clamped to the poster
        XCTAssertEqual(PosterShineMath.unit(location: CGPoint(x: -20, y: 400), size: size, reduceMotion: false),
                       CGPoint(x: 0, y: 1))
        // Reduce Motion / no size: static highlight
        XCTAssertEqual(PosterShineMath.unit(location: CGPoint(x: 75, y: 45), size: size, reduceMotion: true), T.Shine.rest)
        XCTAssertEqual(PosterShineMath.unit(location: CGPoint(x: 1, y: 1), size: .zero, reduceMotion: false), T.Shine.rest)
    }

    func testGridShineUndoesTheZoomAndFlipsY() {
        let size = CGSize(width: 100, height: 200)
        // centre stays centre whatever the zoom
        XCTAssertEqual(PosterShineMath.unit(cardPoint: CGPoint(x: 50, y: 100), size: size, zoom: 1.06, reduceMotion: false),
                       CGPoint(x: 0.5, y: 0.5))
        // AppKit y is from the bottom: a point near the top edge is near y 0
        let top = PosterShineMath.unit(cardPoint: CGPoint(x: 0, y: 200), size: size, zoom: 1, reduceMotion: false)
        XCTAssertEqual(top, CGPoint(x: 0, y: 0))
        // zoomed: the visible edge (outside the un-zoomed bounds) maps back onto the edge
        let z = PosterShineMath.unit(cardPoint: CGPoint(x: 103, y: 100), size: size, zoom: 1.06, reduceMotion: false)
        XCTAssertEqual(z.x, 1, accuracy: 0.001)
        XCTAssertEqual(PosterShineMath.radius(size), 200 * T.Shine.radius)
    }

    // MARK: Ken Burns
    func testKenBurnsCycle() {
        let p = T.KenBurns.period
        XCTAssertGreaterThanOrEqual(p, 20); XCTAssertLessThanOrEqual(p, 30)   // very slow (owner: 20–30 s)
        XCTAssertEqual(KenBurnsMath.phase(elapsed: 0), 0)
        XCTAssertEqual(KenBurnsMath.phase(elapsed: p / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(KenBurnsMath.phase(elapsed: p), 1, accuracy: 0.0001)
        XCTAssertEqual(KenBurnsMath.phase(elapsed: p * 2), 0, accuracy: 0.0001)   // back out, then again
        XCTAssertEqual(KenBurnsMath.phase(elapsed: p * 1.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(KenBurnsMath.phase(elapsed: -.infinity), 0)
    }

    func testKenBurnsScaleAndReduceMotion() {
        XCTAssertEqual(KenBurnsMath.scale(phase: 0, reduceMotion: false), 1)
        XCTAssertEqual(KenBurnsMath.scale(phase: 1, reduceMotion: false), 1.06, accuracy: 0.0001)
        XCTAssertEqual(KenBurnsMath.scale(phase: 1, reduceMotion: true), 1)   // static
        XCTAssertEqual(KenBurnsMath.scale(phase: 7, reduceMotion: false), T.KenBurns.maxScale)
        XCTAssertFalse(KenBurnsMath.runs(reduceMotion: true, playing: false, visible: true))
        XCTAssertFalse(KenBurnsMath.runs(reduceMotion: false, playing: true, visible: true))   // paused under a video
        XCTAssertFalse(KenBurnsMath.runs(reduceMotion: false, playing: false, visible: false))  // hidden / occluded
        XCTAssertTrue(KenBurnsMath.runs(reduceMotion: false, playing: false, visible: true))
    }

    func testKenBurnsAnchorNeverUncoversAnEdge() {
        for seed in ["a", "b", "123", "series-9", ""] {
            let a = KenBurnsMath.anchor(seed: seed)
            XCTAssertTrue((0...1).contains(a.x) && (0...1).contains(a.y), seed)
            XCTAssertNotEqual(a, CGPoint(x: 0.5, y: 0.5))   // off-centre: a slow pan
            XCTAssertEqual(KenBurnsMath.anchor(seed: seed), a)   // stable per slide
        }
    }

    // MARK: Skeleton, tokens
    func testSkeletonPosterColumnsAreFixedWidth() {
        let c = SkeletonShimmer.posterColumns(150, spacing: T.Space.l)
        XCTAssertEqual(c.count, 1)
    }

    func testRound2Tokens() {
        let space = [T.Space.xs, T.Space.s, T.Space.m, T.Space.l, T.Space.xl, T.Space.xxl, T.Space.page, T.Space.pageWide]
        XCTAssertEqual(space, space.sorted()); XCTAssertEqual(Set(space).count, space.count)
        XCTAssertGreaterThan(T.Scrubber.trackHover, T.Scrubber.track)
        XCTAssertLessThanOrEqual(T.Scrubber.knob, T.Scrubber.height)   // thicker on hover inside the fixed frame
        XCTAssertLessThan(T.Shine.opacity, 0.25)   // soft
        XCTAssertEqual(DetailInfoPanel.buttonHeight, 44)
    }

    /// Round 2 migrated the touched screens' paddings to Space tokens: keep the numbers from creeping back.
    func testTouchedScreensKeepTheirPaddingTokens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let limits: [String: Int] = ["Sources/Classic/ClassicHome.swift": 5, "Sources/Classic/ClassicDetail.swift": 7,
                                     "Sources/Classic/ClassicLibrary.swift": 4, "Sources/Classic/ClassicPlayer.swift": 19,
                                     "Sources/Classic/ClassicComponents.swift": 0, "Sources/Classic/Glass3DProgress.swift": 0,
                                     "Sources/Classic/Glass3DPlayerPanels.swift": 0]
        let re = try NSRegularExpression(pattern: #"\.padding\((\.[a-zA-Z]+, *)?[0-9]"#)
        for (f, limit) in limits {
            let text = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            let n = re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertLessThanOrEqual(n, limit, "\(f): use Glass3DTokens.Space")
        }
    }

    // MARK: Secondary button 3D recipe (owner add)
    func testSecondaryUsesTheHighlightRecipe() {
        XCTAssertTrue(GlassButtonStyle.usesHighlightRecipe(.secondary))
        XCTAssertTrue(GlassButtonStyle.usesHighlightRecipe(.primary))
        XCTAssertTrue(GlassButtonStyle.usesHighlightRecipe(.destructive))
        XCTAssertFalse(GlassButtonStyle.usesHighlightRecipe(.icon))
        XCTAssertTrue((0.14...0.18).contains(GlassButtonStyle.secondaryFill))
        XCTAssertLessThan(GlassButtonStyle.brightness(pressed: true, hover: false), 0)   // pressed = darker
    }
}
