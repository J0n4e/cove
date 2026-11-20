import XCTest
@testable import Cove

/// AirPlay video: which path a subtitle takes while the picture is on the TV, and the bar order.
final class AirPlayTests: XCTestCase {
    private func act(_ path: SubPath, airPlay: Bool = true, inStream: Bool = false, burned: Bool = false,
                     hls: Bool = true, unsupported: Bool = false, text: Bool = true) -> AirPlaySubAction {
        PlayerModel.airPlaySubAction(path: path, airPlay: airPlay, playingInStream: inStream, burnedForAirPlay: burned,
                                     hls: hls, inStreamUnsupported: unsupported, textCodec: text)
    }

    func testCoveDrawnOnAirPlayGoesInStream() {
        XCTAssertEqual(act(.file), .inStream)          // external SRT
        XCTAssertEqual(act(.extraction), .inStream)    // extracted SUBRIP
        XCTAssertEqual(act(.inStream), .inStream)      // embedded track currently downloaded
    }

    func testCoveDrawnOnAirPlayBurnsInWhenNotInStream() {
        XCTAssertEqual(act(.extraction, unsupported: true), .burnIn)   // Emby: rendition missing (hlsSubsMissing)
        XCTAssertEqual(act(.file, unsupported: true), .burnIn)
        XCTAssertEqual(act(.extraction, hls: false), .burnIn)          // Direct Play: no HLS stream
        XCTAssertEqual(act(.extraction, text: false), .burnIn)         // codec the server can't make WebVTT of
    }

    func testInStreamOnAirPlayKeeps() {
        XCTAssertEqual(act(.inStream, inStream: true), .keep)
        XCTAssertEqual(act(.burnIn), .keep)
        XCTAssertEqual(act(.none), .keep)
    }

    func testAirPlayOffBackToCoveDrawn() {
        XCTAssertEqual(act(.burnIn, airPlay: false, burned: true), .coveDrawn)
        XCTAssertEqual(act(.burnIn, airPlay: false, burned: false), .keep)   // an image subtitle stays burned in
        XCTAssertEqual(act(.inStream, airPlay: false, inStream: true), .keep)
        XCTAssertEqual(act(.file, airPlay: false), .keep)
    }

    func testBarOrderAirPlayAfterCast() {
        let o = Glass3DBarItem.order
        let cast = o.firstIndex(of: "cast"), air = o.firstIndex(of: "airplay"), fs = o.firstIndex(of: "fullscreen")
        XCTAssertNotNil(air)
        XCTAssertEqual(air, cast.map { $0 + 1 })
        XCTAssertEqual(fs, air.map { $0 + 1 })
        let items = ["fullscreen", "airplay", "pip", "cast"].map { Glass3DBarItem(id: $0, icon: "x", help: $0) }
        XCTAssertEqual(Glass3DBarItem.ordered(items).map(\.id), ["pip", "cast", "airplay", "fullscreen"])
    }
}
