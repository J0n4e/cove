import XCTest
@testable import Cove

/// The detail page's Glass3D About card helpers (key-facts line, two-column list, width, hidden path).
final class AboutCardTests: XCTestCase {
    private func stream(_ i: Int, _ type: String, lang: String? = nil, codec: String? = nil, display: String? = nil,
                        def: Bool = false, range: String? = nil, w: Int? = nil, h: Int? = nil, bitrate: Int? = nil) -> MStream {
        MStream(Index: i, Type: type, DisplayTitle: display, IsDefault: def, Language: lang, Codec: codec,
                VideoRange: range, Width: w, Height: h, BitRate: bitrate)
    }

    // MARK: Key facts line
    func testKeyFactsOrderAndIcons() {
        let v = stream(0, "Video", codec: "hevc", range: "HDR 10", w: 3840, h: 2160)
        var a = stream(1, "Audio", lang: "eng", codec: "truehd", display: "English - Dolby TrueHD Atmos 7.1", def: true)
        a.ChannelLayout = "7.1"
        let facts = AboutCard.keyFacts(video: v, audio: [a], runTimeTicks: 134 * 60 * 10_000_000, size: 58_000_000_000)
        XCTAssertEqual(facts.map(\.text).prefix(4), ["4K", "HDR10", "Dolby Atmos 7.1", "2h 14m"])
        XCTAssertTrue(facts[4].text.hasSuffix("GB"))
        XCTAssertEqual(facts.map(\.icon), ["4k.tv", "sun.max", "hifispeaker.2", nil, nil])
    }

    func testKeyFactsSkipMissing() {
        XCTAssertEqual(AboutCard.keyFacts(video: nil, audio: [], runTimeTicks: nil, size: nil), [])
        let v = stream(0, "Video", range: "SDR", w: 1920, h: 1080)
        XCTAssertEqual(AboutCard.keyFacts(video: v, audio: [], runTimeTicks: 48 * 60 * 10_000_000, size: nil).map(\.text), ["1080p", "48m"])
    }

    func testIconMapping() {
        XCTAssertEqual(AboutCard.icon(forFact: "Dolby Vision"), "sparkles.tv")
        XCTAssertEqual(AboutCard.icon(forFact: "HDR10+"), "sun.max")
        XCTAssertEqual(AboutCard.icon(forFact: "DTS:X"), "speaker.wave.3")
        XCTAssertNil(AboutCard.icon(forFact: "1080p"))
        XCTAssertEqual(AboutCard.hdr("Dolby Vision"), "Dolby Vision")
        XCTAssertEqual(AboutCard.hdr("HDR10+"), "HDR10+")
        XCTAssertNil(AboutCard.hdr("SDR"))
        let dtsx = stream(1, "Audio", codec: "dts", display: "DTS:X 7.1")
        XCTAssertEqual(AboutCard.keyFacts(video: nil, audio: [dtsx], runTimeTicks: nil, size: nil).first?.icon, "speaker.wave.3")
    }

    // MARK: List rows
    func testRowsListEveryTrack() {
        var v = stream(0, "Video", codec: "hevc", w: 3840, h: 1600, bitrate: 62_000_000); v.BitDepth = 10
        let audio = (1...6).map { stream($0, "Audio", lang: "eng", codec: "ac3", def: $0 == 1) }
        var forced = stream(7, "Subtitle", lang: "eng"); forced.IsForced = true
        let sdh = stream(8, "Subtitle", lang: "eng", display: "English SDH")
        let more = (9...20).map { stream($0, "Subtitle", lang: "fre") }
        let rows = AboutCard.rows(streams: [v] + audio + [forced, sdh] + more, container: "mkv", size: 1_000_000_000,
                                  added: Date(), hasFile: true, genres: ["Drama"], studios: [])
        XCTAssertEqual(rows.map(\.label), ["Video", "Audio", "Subtitles", "File", "Genres"])
        XCTAssertEqual(rows[0].lines, ["HEVC · 10-bit · 3840×1600 · 62 Mbps"])
        XCTAssertEqual(rows[1].lines.count, 6)                       // all audio tracks, no "+N more"
        XCTAssertTrue(rows[1].lines[0].hasSuffix("Default"))
        XCTAssertFalse(rows[1].lines[1].contains("Default"))
        XCTAssertEqual(rows[2].lines.count, 14)                      // long → one per line, all of them
        XCTAssertTrue(rows[2].lines[0].hasSuffix("(Forced)"))
        XCTAssertTrue(rows[2].lines[1].hasSuffix("(SDH)"))
        XCTAssertTrue(rows[3].lines[0].hasPrefix("MKV · "))
        XCTAssertTrue(rows[3].lines[0].contains("Added "))
    }

    func testShortSubtitlesShareOneLine() {
        let subs = [stream(1, "Subtitle", lang: "eng"), stream(2, "Subtitle", lang: nil)]
        XCTAssertEqual(AboutCard.subtitleLines(subs), ["English, Unknown language"])
    }

    func testSeriesWithoutFileHasNoFileRow() {
        let rows = AboutCard.rows(streams: [], container: nil, size: nil, added: nil, hasFile: false, genres: ["Drama"])
        XCTAssertEqual(rows.map(\.label), ["Genres"])
    }

    // MARK: Width, path
    func testWidthIsFourCastCards() {
        XCTAssertEqual(AboutCard.cardWidth(castCardWidth: CastTile.width("normal")), 4 * 104 + 3 * 18)
        XCTAssertEqual(AboutCard.cardWidth(castCardWidth: CastTile.width("large")), 4 * 152 + 3 * 18)
    }

    func testPathHiddenByDefault() {
        XCTAssertFalse(AboutCard.pathShownByDefault)
    }

    func testResolutionAndRuntime() {
        XCTAssertEqual(AboutCard.resolution(width: 3840, height: 1600), "4K")
        XCTAssertEqual(AboutCard.resolution(width: 1920, height: 800), "1080p")
        XCTAssertNil(AboutCard.resolution(width: nil, height: nil))
        XCTAssertEqual(AboutCard.runtime(120 * 60 * 10_000_000), "2h")
        XCTAssertNil(AboutCard.runtime(nil))
    }

    func testLinkLabelsAndIcons() {
        XCTAssertEqual(AboutCard.linkLabel("TheMovieDb"), "TMDB")
        XCTAssertEqual(AboutCard.linkLabel("IMDb"), "IMDb")
        XCTAssertEqual(AboutCard.linkIcon("Unknown"), "link")
    }
}
