import XCTest
@testable import Cove

final class EpisodeImagePickTests: XCTestCase {
    typealias I = EpisodeImagePick.Input
    func full(_ a: Double?) -> I {
        I(id: "e", primaryAspect: a, imageTags: ["Primary": "p", "Thumb": "t"], backdropTags: ["b"], seriesId: "s",
          parentThumbId: "season", parentThumbTag: "st", seriesThumbTag: "sst", parentBackdropId: "s", parentBackdropTags: ["sb"])
    }
    func p(_ i: I) -> String { let r = EpisodeImagePick.pick(i); return r.itemId + "|" + r.imageType }

    func testLandscapePrimaryKept() { XCTAssertEqual(p(full(16.0 / 9)), "e|Primary") }
    func testMissingAspectTreatedAsLandscape() { XCTAssertEqual(p(full(nil)), "e|Primary"); XCTAssertEqual(p(full(0)), "e|Primary") }
    func testSquareIsNotPortrait() { XCTAssertEqual(p(full(1)), "e|Primary") }

    func testPortraitFallbackOrder() {
        var i = full(0.67)
        XCTAssertEqual(p(i), "e|Thumb")
        i.imageTags["Thumb"] = nil
        XCTAssertEqual(p(i), "e|Backdrop")
        i.backdropTags = []
        XCTAssertEqual(p(i), "season|Thumb")
        i.parentThumbId = nil; i.parentThumbTag = nil
        XCTAssertEqual(p(i), "s|Thumb")
        i.seriesThumbTag = nil
        XCTAssertEqual(p(i), "s|Backdrop")
        i.parentBackdropTags = []
        XCTAssertEqual(p(i), "e|Primary")   // last resort: the poster, cropped into the 16:9 frame
    }

    func testParentThumbPointingAtSeriesCountsAsSeriesThumb() {
        let i = I(id: "e", primaryAspect: 0.7, seriesId: "s", parentThumbId: "s", parentThumbTag: "x",
                  parentBackdropId: "s", parentBackdropTags: ["sb"])
        XCTAssertEqual(p(i), "s|Thumb")
    }

    func testDecodesFromItemJSON() throws {
        let j = #"{"Id":"e","Name":"E","Type":"Episode","SeriesId":"s","PrimaryImageAspectRatio":0.68,"ImageTags":{"Primary":"p"},"BackdropImageTags":[],"ParentThumbItemId":"s","ParentThumbImageTag":"t"}"#
        let it = try JSONDecoder().decode(Item.self, from: Data(j.utf8))
        XCTAssertEqual(it.PrimaryImageAspectRatio, 0.68)
        XCTAssertEqual(EpisodeImagePick.pick(it).itemId, "s")
        XCTAssertEqual(EpisodeImagePick.pick(it).imageType, "Thumb")
    }
}
