import XCTest
@testable import Cove

final class DeleteEverywhereTests: XCTestCase {
    typealias N = NexcrateAPI

    func obj(_ d: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any] ?? [:] }

    // MARK: Refs

    func testRefs() {
        XCTAssertEqual(N.target(type: "Movie", providerIds: ["Tmdb": "603"], seriesProviderIds: nil, index: nil, parentIndex: nil),
                       .init(kind: .movie, ref: "tmdb:603", scope: nil))
        XCTAssertEqual(N.target(type: "Series", providerIds: ["tmdb": "1399"], seriesProviderIds: nil, index: nil, parentIndex: nil)?.ref, "tmdb:1399")
        let season = N.target(type: "Season", providerIds: ["Tmdb": "999"], seriesProviderIds: ["Tmdb": "1399"], index: 2, parentIndex: nil)
        XCTAssertEqual(season, .init(kind: .series, ref: "tmdb:1399", scope: .init(seasons: [2])))
        let specials = N.target(type: "Season", providerIds: nil, seriesProviderIds: ["Tmdb": "1399"], index: 0, parentIndex: nil)
        XCTAssertEqual(specials?.scope?.seasons, [0])
        let ep = N.target(type: "Episode", providerIds: nil, seriesProviderIds: ["TMDB": "1399"], index: 4, parentIndex: 2)
        XCTAssertEqual(ep?.scope?.episodes, [.init(season: 2, episode: 4)])
        let dbl = N.target(type: "Episode", providerIds: nil, seriesProviderIds: ["Tmdb": "1"], index: 1, parentIndex: 0, indexEnd: 2)
        XCTAssertEqual(dbl?.scope?.episodes, [.init(season: 0, episode: 1), .init(season: 0, episode: 2)])
        XCTAssertNil(N.target(type: "Movie", providerIds: ["Imdb": "tt1"], seriesProviderIds: nil, index: nil, parentIndex: nil))
        XCTAssertNil(N.target(type: "Episode", providerIds: ["Tmdb": "5"], seriesProviderIds: nil, index: 1, parentIndex: 1))
        XCTAssertNil(N.target(type: "BoxSet", providerIds: ["Tmdb": "5"], seriesProviderIds: nil, index: nil, parentIndex: nil))
    }

    func testAddress() {
        XCTAssertEqual(N.normalizedAddress("nas:8390/"), "http://nas:8390")
        XCTAssertEqual(N.normalizedAddress("https://x.example/nexcrate/api/v1/"), "https://x.example/nexcrate")
        XCTAssertEqual(N.baseURL("http://nas:8390"), "http://nas:8390/api/v1")
        XCTAssertNil(N.normalizedAddress("  "))
    }

    // MARK: Requests

    func testWholeDelete() {
        let r = N.removeTitle(.init(kind: .movie, ref: "tmdb:603", scope: nil))
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/titles/movie/tmdb:603?delete_files=true")
        XCTAssertNil(r.body)
    }

    func testScopeDeleteAndFreeze() {
        let t = N.Target(kind: .series, ref: "tmdb:1399", scope: .init(seasons: [2]))
        let d = N.deleteFiles(t)
        XCTAssertEqual(d.method, "POST"); XCTAssertEqual(d.path, "/titles/series/tmdb:1399/delete-files")
        XCTAssertEqual((obj(d.body)["series"] as? [String: Any])?["seasons"] as? [Int], [2])
        let f = N.monitoring(t, monitored: false)
        XCTAssertEqual(f.method, "PUT"); XCTAssertEqual(f.path, "/titles/series/tmdb:1399/monitoring")
        XCTAssertEqual(obj(f.body)["monitored"] as? Bool, false)
        XCTAssertEqual((obj(f.body)["series"] as? [String: Any])?["seasons"] as? [Int], [2])
        let e = N.deleteFiles(.init(kind: .series, ref: "tmdb:1", scope: .init(episodes: [.init(season: 2, episode: 4)])))
        let eps = (obj(e.body)["series"] as? [String: Any])?["episodes"] as? [[String: Int]]
        XCTAssertEqual(eps ?? [], [["season": 2, "episode": 4]])
    }

    func testUndoRequests() {
        XCTAssertEqual(N.restore(42), .init(method: "POST", path: "/recycle-bin/42/restore"))
        let thaw = N.monitoring(.init(kind: .series, ref: "tmdb:1", scope: .init(seasons: [1])), monitored: true)
        XCTAssertEqual(obj(thaw.body)["monitored"] as? Bool, true)
        XCTAssertEqual(obj(N.pairing().body)["scopes"] as? [String], ["read", "request"])
        XCTAssertEqual(obj(N.pairing().body)["app"] as? String, "Cove")
    }

    // MARK: Errors

    func testErrors() {
        XCTAssertEqual(N.errorCode(Data(#"{"code":"download_finished","message":"x","params":{}}"#.utf8)), "download_finished")
        XCTAssertTrue(N.message(status: 409, code: "download_finished")!.contains("Try again in a minute"))
        XCTAssertEqual(N.message(status: 409, code: "download_importing"), N.message(status: 409, code: "download_finished"))
        XCTAssertTrue(N.message(status: 409, code: "title_has_source_versions")!.contains("Radarr or Sonarr"))
        XCTAssertNil(N.message(status: 204, code: nil))
        XCTAssertTrue(N.serverDeleteMessage(status: 403)!.contains("Allow media deletion"))
        XCTAssertNil(N.serverDeleteMessage(status: 204))
    }

    // MARK: Recycle bin

    func testRecycleMatching() {
        let json = """
        {"items":[
         {"entry_id":3,"kind":"series","ref":"tmdb:1","season":2,"episodes":[4],"file_name":"a.mkv","deleted_at":"2026-11-22T10:00:30Z","deleted_by":"key","restorable":true},
         {"entry_id":2,"kind":"series","ref":"tmdb:1","season":3,"episodes":[1],"file_name":"b.mkv","deleted_at":"2026-11-22T10:00:30.500+00:00","deleted_by":"key","restorable":true},
         {"entry_id":1,"kind":"series","ref":"tmdb:1","season":2,"episodes":[4],"file_name":"old.mkv","deleted_at":"2026-11-20T10:00:00Z","deleted_by":"key","restorable":true},
         {"entry_id":9,"kind":"movie","ref":"tmdb:1","season":null,"episodes":[],"file_name":"m.mkv","deleted_at":"2026-11-22T10:00:30Z","deleted_by":"owner","restorable":true}
        ]}
        """
        let e = N.decodeRecycleBin(Data(json.utf8))
        XCTAssertEqual(e.count, 4)
        let since = N.parseDate("2026-11-22T10:00:00Z")!
        XCTAssertEqual(N.matching(e, target: .init(kind: .series, ref: "tmdb:1", scope: .init(seasons: [2])), since: since).map(\.entryId), [3])
        XCTAssertEqual(N.matching(e, target: .init(kind: .series, ref: "tmdb:1", scope: nil), since: since).map(\.entryId), [3, 2])
        XCTAssertEqual(N.matching(e, target: .init(kind: .series, ref: "tmdb:1", scope: .init(episodes: [.init(season: 3, episode: 1)])), since: since).map(\.entryId), [2])
        XCTAssertEqual(N.matching(e, target: .init(kind: .movie, ref: "tmdb:1", scope: nil), since: since), [])   // by owner, not us
    }

    // MARK: Pairing

    func testPairing() {
        let s = N.decodePairingStart(Data(#"{"pairing_id":"p1","secret":"s","code":"7Q4-K2P","expires_at":"2026-11-22T10:00:00Z","poll_seconds":3}"#.utf8))
        XCTAssertEqual(s?.code, "7Q4-K2P"); XCTAssertEqual(s?.poll_seconds, 3)
        func st(_ j: String) -> N.PairingState.Phase? { N.decodePairingState(Data(j.utf8))?.phase }
        XCTAssertEqual(st(#"{"state":"pending","key":null,"scopes":null,"expires_at":"x"}"#), .waiting)
        XCTAssertEqual(st(#"{"state":"confirmed","key":"k","scopes":["read","request"],"expires_at":"x"}"#), .gotKey("k", ["read", "request"]))
        XCTAssertEqual(st(#"{"state":"delivered","key":null,"scopes":null,"expires_at":"x"}"#), .delivered)
        XCTAssertEqual(st(#"{"state":"denied","key":null,"scopes":null,"expires_at":"x"}"#), .denied)
        XCTAssertEqual(st(#"{"state":"expired","key":null,"scopes":null,"expires_at":"x"}"#), .expired)
        XCTAssertEqual(N.pairingState("p1").path, "/pairing/p1")
    }

    // MARK: Confirm text

    func testConfirmText() {
        let nex = N.confirmText(type: "Movie", scopeLine: "m", inNexcrate: true, configured: true, versionNames: ["1080p", "4K"])
        XCTAssertEqual(nex.button, "Delete"); XCTAssertNil(nex.warning)
        XCTAssertTrue(nex.bullets.contains { $0.contains("versions: 1080p, 4K") })
        XCTAssertTrue(nex.bullets.contains { $0.contains("qBittorrent") })
        XCTAssertTrue(nex.bullets.contains { $0.contains("7 days") })
        let season = N.confirmText(type: "Season", scopeLine: "s", inNexcrate: true, configured: true, versionNames: [], season: 2)
        XCTAssertTrue(season.bullets[0].contains("Files of Season 2 removed, season frozen in nexcrate"))
        let perm = N.confirmText(type: "Movie", scopeLine: "m", inNexcrate: false, configured: true, versionNames: [])
        XCTAssertEqual(perm.button, "Delete permanently")
        XCTAssertTrue(perm.warning!.contains("This is permanent")); XCTAssertNil(perm.hint)
        let noNex = N.confirmText(type: "Movie", scopeLine: "m", inNexcrate: false, configured: false, versionNames: [])
        XCTAssertEqual(noNex.hint, "Connect nexcrate in Settings → Connect for a 7-day undo.")
        XCTAssertTrue(N.confirmText(type: "Episode", scopeLine: "e", inNexcrate: true, configured: true, versionNames: [], doubleEpisode: true)
            .bullets.contains { $0.contains("goes whole") })
        XCTAssertEqual(N.scopeLine(type: "Season", name: "Specials", seriesName: "GoT", index: 0, parentIndex: nil, indexEnd: nil, childCount: nil),
                       "Specials of \u{201C}GoT\u{201D}")
        XCTAssertTrue(N.canDelete(type: "Episode", admin: true))
        XCTAssertFalse(N.canDelete(type: "Movie", admin: false))
        XCTAssertFalse(N.canDelete(type: "BoxSet", admin: true))
    }

    // MARK: Store

    func testStoreExpiry() {
        let now = Date()
        func rec(_ age: TimeInterval) -> DeletionRecord {
            DeletionRecord(server: "s", itemId: "i", name: "n", what: "w", kind: .movie, ref: "tmdb:1", scope: nil,
                           deletedAt: now.addingTimeInterval(-age), entryIds: [1], libraryId: nil)
        }
        let kept = DeletionStore.pruned([rec(8 * 86400), rec(60), rec(6 * 86400)], now: now)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.first?.deletedAt, rec(60).deletedAt)
        let round = DeletionStore.decode(DeletionStore.encode([rec(60)])!)
        XCTAssertEqual(round.first?.ref, "tmdb:1"); XCTAssertEqual(round.first?.entryIds, [1])
    }

    func testTombstoneDropsFromLists() {
        let t = Item.tombstone("a")!
        XCTAssertTrue(t.isTombstone)
        let a = Item.tombstone("a")!, b = Item.tombstone("b")!
        XCTAssertEqual(LiveRefresh.replacing([a, b], with: ["a": t])?.map(\.id), ["b"])
    }
}
