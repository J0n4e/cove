import XCTest
@testable import Cove

final class TrashCardsTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_795_000_000)

    func rec(kind: NexcrateAPI.Kind = .movie, itemId: String = "i1", posterURL: String? = nil, posterItemId: String? = nil) -> DeletionRecord {
        DeletionRecord(server: "s", itemId: itemId, name: "I Am Lisa", what: "The movie \u{201C}I Am Lisa\u{201D}", kind: kind, ref: "tmdb:1",
                       scope: nil, deletedAt: when, entryIds: [1], libraryId: nil, posterURL: posterURL, posterItemId: posterItemId)
    }
    func server(_ id: String) -> URL? { URL(string: "https://srv/Items/\(id)/Images/Primary") }

    func testTitleAndLineUnchanged() {
        let r = rec()
        let m = DeletedRowModel.make(r, server: server)
        XCTAssertEqual(m.title, "The movie \u{201C}I Am Lisa\u{201D}")
        let expected = "Deleted \(when.formatted(date: .abbreviated, time: .shortened)) · Deleted permanently on \(when.addingTimeInterval(DeletionStore.lifetime).formatted(date: .abbreviated, time: .omitted))"
        XCTAssertEqual(m.line, expected)
    }

    func testPosterFallbackOrder() {
        XCTAssertEqual(DeletedRowModel.poster(rec(posterURL: "https://x/p.jpg", posterItemId: "s9"), server: server), .url(URL(string: "https://x/p.jpg")!))
        XCTAssertEqual(DeletedRowModel.poster(rec(posterURL: "not a url", posterItemId: "s9"), server: server), .url(server("s9")!))
        XCTAssertEqual(DeletedRowModel.poster(rec(), server: server), .url(server("i1")!))
        XCTAssertEqual(DeletedRowModel.poster(rec(itemId: ""), server: { _ in nil }), .placeholder("film"))
        XCTAssertEqual(DeletedRowModel.poster(rec(kind: .series), server: { _ in nil }), .placeholder("tv"))
    }

    func testCountdownThresholds() {
        func c(_ h: Double) -> (String, DeletedRowModel.Urgency) { let x = DeletedRowModel.countdown(seconds: h * 3600); return (x.text, x.urgency) }
        XCTAssertTrue(c(168) == ("7 days left", .normal))
        XCTAssertTrue(c(120.5) == ("5 days left", .normal))
        XCTAssertTrue(c(48) == ("2 days left", .normal))
        XCTAssertTrue(c(47.9) == ("Last day", .warning))
        XCTAssertTrue(c(24) == ("Last day", .warning))
        XCTAssertTrue(c(23.9) == ("23 h left", .danger))
        XCTAssertTrue(c(1) == ("1 h left", .danger))
        XCTAssertTrue(c(0.5) == ("<1 h left", .danger))
        XCTAssertTrue(c(-1) == ("<1 h left", .danger))
        let r = rec()
        XCTAssertEqual(DeletedRowModel.countdown(r, now: when.addingTimeInterval(3 * 86400)).text, "4 days left")
    }

    func testOldRecordsDecodeWithoutPoster() throws {
        let old = #"[{"id":"a","server":"s","itemId":"i","name":"n","what":"w","kind":"movie","ref":"tmdb:1","deletedAt":"2026-11-22T19:19:00Z","entryIds":[1]}]"#
        let r = DeletionStore.decode(Data(old.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertNil(r.first?.posterURL); XCTAssertNil(r.first?.posterItemId)
        let round = DeletionStore.decode(DeletionStore.encode([rec(posterURL: "https://x/p.jpg", posterItemId: "s9")])!)
        XCTAssertEqual(round.first?.posterURL, "https://x/p.jpg"); XCTAssertEqual(round.first?.posterItemId, "s9")
    }
}
