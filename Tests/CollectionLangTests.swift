import XCTest
@testable import Cove

/// Audio/subtitle choices remembered per collection in collection mode (like SeriesLang for episodes).
final class CollectionLangTests: XCTestCase {
    func item(_ json: String) -> Item { try! JSONDecoder().decode(Item.self, from: Data(json.utf8)) }
    func sub(_ i: Int, _ lang: String, _ codec: String) -> MStream {
        try! JSONDecoder().decode(MStream.self, from: Data(
            "{\"Index\":\(i),\"Type\":\"Subtitle\",\"Language\":\"\(lang)\",\"Codec\":\"\(codec)\"}".utf8))
    }

    func testKeyForCollectionSeriesAndFilm() {
        let film = item("{\"Id\":\"f\",\"Name\":\"F\",\"Type\":\"Movie\"}")
        let q = CollectionQueue(id: "box1", name: "Box", items: [film], index: 0)
        XCTAssertEqual(SeriesLang.key(PlayRequest(item: film, collection: q)), "box:box1")
        XCTAssertNil(SeriesLang.key(PlayRequest(item: film)))
        let ep = item("{\"Id\":\"e\",\"Name\":\"E\",\"Type\":\"Episode\",\"SeriesId\":\"s1\"}")
        XCTAssertEqual(SeriesLang.key(PlayRequest(item: ep)), "s1")
    }

    func testStoreRoundTripAndTextPreferred() {
        let k = "box:test-\(UUID().uuidString)"
        SeriesLang.set(k, "sub", "Romanian")
        SeriesLang.set(k, "audio", "eng")
        XCTAssertEqual(SeriesLang.get(k)?["sub"], "Romanian")
        XCTAssertEqual(SeriesLang.get(k)?["audio"], "eng")
        SeriesLang.set(k, "sub", "off")
        XCTAssertEqual(SeriesLang.get(k)?["sub"], "off")
        let streams = [sub(3, "rum", "pgssub"), sub(4, "rum", "subrip")]
        XCTAssertEqual(preferredSub(streams, lang: subLangName(streams[1])), 4)
    }
}
