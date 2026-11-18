import XCTest
@testable import Cove

final class PreferExternalSrtTests: XCTestCase {
    private func sub(_ i: Int, _ codec: String, ext: Bool) -> MStream {
        var s = MStream(Index: i, Type: "Subtitle", DisplayTitle: "Romanian", IsDefault: false, Language: "rum",
                        Codec: codec, VideoRange: nil, Width: nil, Height: nil, BitRate: nil)
        s.IsExternal = ext
        return s
    }
    func testExternalSrtBeatsEmbeddedSubrip() {
        XCTAssertEqual(bestTextSub([sub(4, "subrip", ext: false), sub(6, "srt", ext: true)])?.Index, 6)
    }
    func testEmbeddedTextBeatsPicture() {
        XCTAssertEqual(bestTextSub([sub(3, "pgssub", ext: false), sub(4, "subrip", ext: false)])?.Index, 4)
    }
}
