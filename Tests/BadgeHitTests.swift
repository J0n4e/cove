import XCTest
@testable import Cove

/// Glass3D grid posters: the badges stay baked into the decor picture on hover (no live swap); clicks and
/// tooltips hit-test their rects, scaled by the zoom.
final class BadgeHitTests: XCTestCase {
    let poster = CGSize(width: 150, height: 225)
    let viewH: CGFloat = 270   // poster + labels
    let left = CGSize(width: 23, height: 23)
    let leftRated = CGSize(width: 23 + 5 + 36, height: 23)
    let right = CGSize(width: 23, height: 23)

    func testRectsAtRest() {
        let (l, r) = PosterBadgeHit.cardRects(poster: poster, left: left, right: right)
        XCTAssertEqual(l, CGRect(x: 8, y: 225 - 8 - 23, width: 23, height: 23))
        XCTAssertEqual(r, CGRect(x: 150 - 8 - 23, y: 225 - 8 - 23, width: 23, height: 23))
        // At rest the card sits at the top of the cell: view = card shifted up by the labels' height
        XCTAssertEqual(PosterBadgeHit.toView(l, poster: poster, viewHeight: viewH, zoom: 1),
                       l.offsetBy(dx: 0, dy: viewH - poster.height))
    }

    func testRectsZoomedScaleAboutCentre() {
        let (l, _) = PosterBadgeHit.cardRects(poster: poster, left: left, right: right)
        let v = PosterBadgeHit.toView(l, poster: poster, viewHeight: viewH, zoom: 1.06)
        let cx = poster.width / 2, cy = viewH - poster.height / 2
        XCTAssertEqual(v.minX, cx + (8 - cx) * 1.06, accuracy: 0.0001)
        XCTAssertEqual(v.maxY, cy + (poster.height - 8 - poster.height / 2) * 1.06, accuracy: 0.0001)
        XCTAssertEqual(v.width, 23 * 1.06, accuracy: 0.0001)
    }

    func testHitInsideOutside() {
        let top = viewH - 8 - 11   // the badges' middle row at rest
        func hit(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, l: CGSize? = nil) -> PosterBadgeHit? {
            PosterBadgeHit.hit(CGPoint(x: x, y: y), poster: poster, viewHeight: viewH, left: l ?? left, right: right, zoom: z)
        }
        XCTAssertEqual(hit(19, top, 1), .fav)
        XCTAssertEqual(hit(150 - 19, top, 1), .watched)
        XCTAssertNil(hit(75, top, 1))
        XCTAssertNil(hit(19, viewH - 60, 1))
        XCTAssertEqual(hit(50, top, 1, l: leftRated), .rating)
        // Zoomed: the corners move out; a point just outside the rest rect is inside the zoomed one
        let restEdge: CGFloat = 8 - 0.5
        XCTAssertNil(hit(restEdge, top, 1))
        XCTAssertEqual(hit(restEdge, top, 1.06), .fav)
        XCTAssertEqual(hit(150 - restEdge, top, 1.06), .watched)
        XCTAssertNil(hit(75, top, 1.06))
    }

    func testDecorKeyHasNoHover() {
        let k = PosterGridCell.decorKey(glass3D: true, played: false, unwatched: 0, fav: true, rating: 8, progress: 0, accent: "red")
        XCTAssertEqual(k, "gridDecor|true|false|0|true|8|0|red|true")   // badges always baked in
        XCTAssertFalse(k.contains("hover"))
    }
}
