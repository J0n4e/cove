import XCTest
@testable import Cove

final class NexviewRequestsTests: XCTestCase {
    let ann = WatchActivityUser(id: "a", name: "Ann", imageTag: nil, disabled: false)
    let bob = WatchActivityUser(id: "b", name: "bob.smith", imageTag: nil, disabled: false)

    // Shape of RequestWithUser (nexview backend/app/schemas_requests.py), extra fields included
    let sample = #"""
    [{"id":7,"media_type":"movie","fassung":"radarr","tier":"standard","tmdb_id":550,"title":"Fight Club","poster_path":null,
      "release_date":"1999-10-15","status":"downloaded","quality_profile_id":4,"root_folder_path":"/movies","season":null,"episodes":null,
      "from_watchlist":false,"requested_at":"2026-11-12T21:14:05.123456","approved_at":"2026-11-12T21:20:00",
      "completed_at":"2026-11-12T21:40:00+00:00","approved_by_name":"Admin","rejection_reason":null,"error_message":null,
      "rating":8,"feedback":"Great","rated_at":null,"feedback_reply":null,"replied_at":null,
      "user_id":3,"username":"ann","display_name":"Ann","avatar_url":null,"requester_subscriptions":[]},
     {"id":9,"media_type":"tv","tmdb_id":1399,"title":"GoT","status":"approved","season":2,"episodes":[3,7],
      "requested_at":"2026-11-14T08:00:00Z","approved_at":null,"completed_at":null,"approved_by_name":null,
      "rating":null,"feedback":null,"user_id":4,"username":"bob.smith","display_name":null,"avatar_url":null},
     {"id":10,"media_type":"movie","tmdb_id":550,"title":"Fight Club","status":"pending_approval",
      "requested_at":"2026-11-13T09:00:00","user_id":5,"username":"carl","display_name":"Carl"},
     {"id":"broken"}]
    """#

    func reqs() throws -> [NexviewRequest] { try XCTUnwrap(Nexview.decodeRequests(Data(sample.utf8))) }

    func item(_ id: String, _ type: String, tmdb: Any?, entries: [(WatchActivityUser, [String: Any])] = []) -> CleanupItem {
        var o: [String: Any] = ["Id": id, "Name": id, "Type": type]
        if let tmdb { o["ProviderIds"] = ["Tmdb": tmdb, "Imdb": "tt1"] }
        var map = [id: Cleanup.item(o, libraryId: "L")!]
        for (u, ud) in entries { Cleanup.merge([["Id": id, "UserData": ud, "RecursiveItemCount": 10]], user: u, into: &map) }
        return map[id]!
    }

    func testDecode() throws {
        let r = try reqs()
        XCTAssertEqual(r.count, 3)   // the broken row is skipped, not the whole list
        let fc = r[0]
        XCTAssertEqual(fc.id, 7); XCTAssertEqual(fc.mediaType, "movie"); XCTAssertEqual(fc.tmdbId, 550)
        XCTAssertEqual(fc.status, "downloaded"); XCTAssertEqual(fc.approvedByName, "Admin")
        XCTAssertEqual(fc.rating, 8); XCTAssertEqual(fc.feedback, "Great"); XCTAssertEqual(fc.requesterName, "Ann")
        // naive datetimes are UTC
        XCTAssertEqual(fc.requestedAt?.timeIntervalSince1970 ?? 0, 1_794_518_045.123, accuracy: 0.01)
        XCTAssertEqual(fc.approvedAt?.timeIntervalSince1970, 1_794_518_400)
        XCTAssertEqual(fc.completedAt?.timeIntervalSince1970, 1_794_519_600)
        XCTAssertEqual(r[1].requesterName, "bob.smith")   // no display name
        XCTAssertEqual(r[1].episodes, [3, 7]); XCTAssertEqual(r[1].season, 2)
        XCTAssertNotNil(Nexview.date("2026-11-14T08:00:00Z"))
        XCTAssertNil(Nexview.date("nope"))
    }

    func testMatchByTmdbAndType() throws {
        var map: [String: CleanupItem] = [:]
        for i in [item("fc", "Movie", tmdb: "550"), item("got", "Series", tmdb: 1399), item("fcSeries", "Series", tmdb: "550"),
                  item("none", "Movie", tmdb: nil)] { map[i.id] = i }
        NexviewMatch.attach(try reqs(), to: &map)
        XCTAssertEqual(map["fc"]?.requests.map(\.id), [7, 10])       // both requests, oldest first
        XCTAssertEqual(map["got"]?.requests.map(\.id), [9])
        XCTAssertEqual(map["fcSeries"]?.requests, [])               // tv ≠ movie
        XCTAssertEqual(map["none"]?.requests, [])
        XCTAssertEqual(Nexview.columnText(map["fc"]!), "Ann +1")
        XCTAssertEqual(Nexview.columnText(map["got"]!), "bob.smith")
        XCTAssertEqual(map["fc"]?.requestedAt, map["fc"]?.requests.first?.requestedAt)
    }

    func testTooltipLine() throws {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Nexview.line(try reqs()[0], timeZone: utc),
                       "Requested 12 Nov 2026, 21:14 \u{00B7} approved by Admin 12 Nov \u{00B7} ready 12 Nov 21:40 \u{00B7} rated 8 \u{00B7} \u{201C}Great\u{201D}")
        XCTAssertEqual(Nexview.line(try reqs()[1], timeZone: utc), "Requested 14 Nov 2026, 08:00 \u{00B7} season 2, episodes 3, 7")
    }

    func testUserMatchingAndFilters() throws {
        let r = try reqs()
        // Ann requested fc and watched it; Carl has no server user
        let watched = item("fc", "Movie", tmdb: 550, entries: [(ann, ["Played": true, "PlayCount": 1])])
        let unwatched = item("got", "Series", tmdb: 1399, entries: [(bob, ["Played": false, "UnplayedItemCount": 10])])
        let notRequested = item("x", "Movie", tmdb: 1)
        let items = NexviewMatch.attach(r, to: [watched, unwatched, notRequested])
        let fc = items[0], got = items[1]
        XCTAssertEqual(NexviewMatch.watched(r[0], in: fc), true)                  // "ann"/"Ann" case-insensitive
        XCTAssertNil(NexviewMatch.watched(r[2], in: fc))                          // Carl: unknown
        XCTAssertEqual(NexviewMatch.watched(r[1], in: got), false)                // matched by username
        XCTAssertTrue(Nexview.tooltip(fc).contains("no server user with this name, counted as not watched"))

        func ids(_ f: CleanupFilter) -> [String] { Cleanup.filtered(items, library: nil, kind: .both, filter: f).map(\.id) }
        XCTAssertEqual(ids(.requested), ["fc", "got"])
        XCTAssertEqual(ids(.requestedUnwatched), ["got"])   // fc: one requester (Ann) watched it

        // only Carl requested it (no server user) → counts as never watched by the requester
        let carlOnly = NexviewMatch.attach([r[2]], to: [item("fc", "Movie", tmdb: 550, entries: [(ann, ["Played": true])])])
        XCTAssertTrue(Cleanup.matches(carlOnly[0], filter: .requestedUnwatched))
    }

    func testFilterOptionsAndMessages() {
        XCTAssertFalse(CleanupFilter.options(nexview: false).contains(.requested))
        XCTAssertTrue(CleanupFilter.options(nexview: true).contains(.requestedUnwatched))
        XCTAssertEqual(Nexview.requestsPath, "/api/admin/requests")
        XCTAssertTrue(Nexview.message(status: 403, detail: nil).contains("admin or approver"))
        XCTAssertEqual(Nexview.errorDetail(Data(#"{"detail":{"code":"approvers_only","message":"x"}}"#.utf8)), "approvers_only")
        let me = Nexview.decodeMe(Data(#"{"version":"1","konto":{"id":1,"username":"j","name":"Jonae","role":"admin","betreiber":true},"schluessel":{"name":"cove","nur_lesen":true},"darf":["lesen"]}"#.utf8))
        XCTAssertEqual(me, Nexview.Me(name: "Jonae", role: "admin", readOnly: true))
    }
}
