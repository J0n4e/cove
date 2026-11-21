import XCTest
@testable import Cove

/// Edit metadata + Find to edit (Sources/Admin/MetadataEditorAPI.swift): both servers' item JSON, round trip,
/// edit application, diff text, search request.
final class MetadataEditorTests: XCTestCase {
    typealias API = MetadataEditorAPI

    private func query(_ path: String) -> [String: String] {
        var out: [String: String] = [:]
        for q in URLComponents(string: "http://x" + path)?.queryItems ?? [] { out[q.name] = q.value }
        return out
    }
    private func obj(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
    private func roundTrip(_ o: [String: Any]) -> [String: Any] {
        let d = try! JSONSerialization.data(withJSONObject: o)
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    let jellyfin = """
    {"Id":"j1","Name":"Heat","OriginalTitle":"Heat","SortName":"heat","Type":"Movie","ProductionYear":1995,
     "PremiereDate":"1995-12-15T00:00:00.0000000Z","OfficialRating":"R","CommunityRating":7.9,"CriticRating":88,
     "Overview":"A crew.","Taglines":["A Los Angeles crime saga"],"Genres":["Drama","Crime"],
     "GenreItems":[{"Name":"Drama","Id":"g1"},{"Name":"Crime","Id":"g2"}],"Tags":["heist"],
     "Studios":[{"Name":"Warner Bros.","Id":"s1"}],
     "People":[{"Name":"Al Pacino","Id":"p1","Role":"Vincent Hanna","Type":"Actor","PrimaryImageTag":"x"}],
     "ProviderIds":{"Imdb":"tt0113277","Tmdb":"949"},"LockData":false,"LockedFields":[],
     "UnknownThing":{"Keep":true},"MediaSources":[{"Id":"m"}]}
    """

    let emby = """
    {"Id":"e1","Name":"Lost","Type":"Series","ProductionYear":2004,"Status":"Ended","EndDate":"2010-05-23T00:00:00.0000000Z",
     "Genres":["Drama"],"TagItems":[{"Name":"Island","Id":101}],"Studios":[{"Name":"ABC","Id":7}],
     "People":[],"ProviderIds":{"Tvdb":73739,"Imdb":"tt0411008"},"LockData":true,"LockedFields":["Genres"],
     "DisplayOrder":"aired","PreferredMetadataLanguage":"en","EmbyOnly":[1,2]}
    """

    // MARK: Decoding

    func testDecodeJellyfinItem() {
        let d = API.draft(obj(jellyfin))
        XCTAssertEqual(d.name, "Heat")
        XCTAssertEqual(d.year, "1995")
        XCTAssertEqual(d.premiereDate, "1995-12-15")
        XCTAssertEqual(d.tagline, "A Los Angeles crime saga")
        XCTAssertEqual(d.genres, ["Drama", "Crime"])
        XCTAssertEqual(d.tags, ["heist"])
        XCTAssertEqual(d.studios, ["Warner Bros."])
        XCTAssertEqual(d.people.first?.name, "Al Pacino")
        XCTAssertEqual(d.people.first?.role, "Vincent Hanna")
        XCTAssertEqual(d.communityRating, "7.9")
        XCTAssertEqual(d.criticRating, "88")
        XCTAssertEqual(d.providerIds["Imdb"], "tt0113277")
    }

    func testDecodeEmbyItemTagItemsAndNumericIds() {
        let d = API.draft(obj(emby))
        XCTAssertEqual(d.tags, ["Island"])           // from TagItems
        XCTAssertEqual(d.providerIds["Tvdb"], "73739")  // number → string
        XCTAssertEqual(d.status, "Ended")
        XCTAssertEqual(d.endDate, "2010-05-23")
        XCTAssertTrue(d.lockData)
        XCTAssertEqual(d.lockedFields, ["Genres"])
        XCTAssertEqual(d.displayOrder, "aired")
    }

    // MARK: Round trip

    func testUnchangedDraftKeepsEverything() {
        let item = obj(jellyfin)
        let d = API.draft(item)
        let out = API.apply(d, original: d, to: item, emby: false)
        XCTAssertEqual(NSDictionary(dictionary: out), NSDictionary(dictionary: item))
    }

    func testEditKeepsUnknownKeys() {
        let item = obj(jellyfin)
        let o = API.draft(item)
        var e = o; e.name = "Heat (1995)"
        let out = roundTrip(API.apply(e, original: o, to: item, emby: false))
        XCTAssertEqual(out["Name"] as? String, "Heat (1995)")
        XCTAssertEqual((out["UnknownThing"] as? [String: Any])?["Keep"] as? Bool, true)
        XCTAssertNotNil(out["MediaSources"])
        XCTAssertEqual(out["Overview"] as? String, "A crew.")
    }

    // MARK: Apply

    func testGenresKeepGenreItemsInStep() {
        let item = obj(jellyfin)
        let o = API.draft(item)
        var e = o; e.genres = ["Crime", "Thriller", " thriller "]
        let out = API.apply(e, original: o, to: item, emby: false)
        XCTAssertEqual(out["Genres"] as? [String], ["Crime", "Thriller"])
        let gi = out["GenreItems"] as? [[String: Any]] ?? []
        XCTAssertEqual(gi.compactMap { $0["Name"] as? String }, ["Crime", "Thriller"])
        XCTAssertEqual(gi.first?["Id"] as? String, "g2")   // existing entry kept
    }

    func testJellyfinTagsAsStrings() {
        let item = obj(jellyfin)
        let o = API.draft(item)
        var e = o; e.tags = ["heist", "4K"]
        let out = API.apply(e, original: o, to: item, emby: false)
        XCTAssertEqual(out["Tags"] as? [String], ["heist", "4K"])
        XCTAssertNil(out["TagItems"])   // Jellyfin item had none: not invented
    }

    func testEmbyTagsWriteTagItemsAndTags() {
        let item = obj(emby)
        let o = API.draft(item)
        var e = o; e.tags = ["Island", "4K"]
        let out = API.apply(e, original: o, to: item, emby: true)
        XCTAssertEqual(out["Tags"] as? [String], ["Island", "4K"])
        let ti = out["TagItems"] as? [[String: Any]] ?? []
        XCTAssertEqual(ti.compactMap { $0["Name"] as? String }, ["Island", "4K"])
        XCTAssertEqual(ti.first?["Id"] as? Int, 101)
        // Emby without TagItems in the answer still gets them
        var bare = item; bare.removeValue(forKey: "TagItems")
        let o2 = API.draft(bare); var e2 = o2; e2.tags = ["4K"]
        XCTAssertNotNil(API.apply(e2, original: o2, to: bare, emby: true)["TagItems"])
    }

    func testStudiosPeopleProviderIdsLocks() {
        let item = obj(jellyfin)
        let o = API.draft(item)
        var e = o
        e.studios = ["Warner Bros.", "Regency"]
        e.people[0].role = "Lt. Vincent Hanna"
        e.people.append(.init(name: "Michael Mann", type: "Director"))
        e.providerIds["Tmdb"] = ""
        e.providerIds["Tvdb"] = "123"
        e.lockedFields = ["Genres", "Tags"]
        e.lockData = true
        let out = API.apply(e, original: o, to: item, emby: false)
        let st = out["Studios"] as? [[String: Any]] ?? []
        XCTAssertEqual(st.compactMap { $0["Name"] as? String }, ["Warner Bros.", "Regency"])
        XCTAssertEqual(st.first?["Id"] as? String, "s1")
        let pp = out["People"] as? [[String: Any]] ?? []
        XCTAssertEqual(pp.count, 2)
        XCTAssertEqual(pp[0]["Role"] as? String, "Lt. Vincent Hanna")
        XCTAssertEqual(pp[0]["PrimaryImageTag"] as? String, "x")   // server's own keys kept
        XCTAssertEqual(pp[1]["Type"] as? String, "Director")
        let ids = out["ProviderIds"] as? [String: Any] ?? [:]
        XCTAssertNil(ids["Tmdb"])
        XCTAssertEqual(ids["Tvdb"] as? String, "123")
        XCTAssertEqual(ids["Imdb"] as? String, "tt0113277")
        XCTAssertEqual(out["LockedFields"] as? [String], ["Genres", "Tags"])
        XCTAssertEqual(out["LockData"] as? Bool, true)
    }

    func testDatesAndNumbers() {
        let item = obj(jellyfin)
        let o = API.draft(item)
        var e = o; e.premiereDate = "1995-12-16"; e.communityRating = "8,1"; e.year = ""; e.criticRating = ""
        let out = API.apply(e, original: o, to: item, emby: false)
        XCTAssertEqual(out["PremiereDate"] as? String, "1995-12-16T00:00:00.000Z")
        XCTAssertEqual(out["CommunityRating"] as? Double, 8.1)
        XCTAssertTrue(out["ProductionYear"] is NSNull)
        XCTAssertTrue(out["CriticRating"] is NSNull)
        var bad = o; bad.premiereDate = "16.12.1995"
        XCTAssertTrue(API.apply(bad, original: o, to: item, emby: false)["PremiereDate"] is NSNull)
    }

    // MARK: Diff

    func testSummaryText() {
        let o = API.draft(obj(jellyfin))
        var e = o; e.genres = ["Crime", "Thriller"]; e.tags = ["heist", "4K"]
        XCTAssertEqual(API.summary(e, original: o), "Changed: Genres +Thriller \u{2212}Drama, Tags +4K")
        XCTAssertEqual(API.summary(o, original: o), "")
        var t = o; t.name = "Heat 2"; t.lockData = true
        XCTAssertEqual(API.summary(t, original: o), "Changed: Title \u{2192} Heat 2, Metadata locked")
    }

    func testLockHint() {
        let o = API.draft(obj(jellyfin))
        var e = o; e.tags = ["4K"]
        XCTAssertEqual(API.needsLockHint(e, original: o), ["Tags"])
        e.lockedFields = ["Tags"]
        XCTAssertEqual(API.needsLockHint(e, original: o), [])
        let em = API.draft(obj(emby)); var e2 = em; e2.genres = ["Mystery"]
        XCTAssertEqual(API.needsLockHint(e2, original: em), [])   // whole item locked
    }

    func testSuggestions() {
        XCTAssertEqual(API.suggest("dr", from: ["Drama", "Adrenaline", "Comedy"], excluding: []), ["Drama", "Adrenaline"])
        XCTAssertEqual(API.suggest("dr", from: ["Drama", "Adrenaline"], excluding: ["drama"]), ["Adrenaline"])
        XCTAssertEqual(API.suggest(" ", from: ["Drama"], excluding: []), [])
        XCTAssertEqual(API.decodeNames(Data(#"{"Items":[{"Name":"A"},{"Name":"a"},{"Name":"B"}]}"#.utf8)), ["A", "B"])
        XCTAssertEqual(API.decodeRatings(Data(#"[{"Name":"PG","Value":5},{"Name":"R","Value":9}]"#.utf8)), ["PG", "R"])
    }

    // MARK: Requests

    func testSearchRequest() throws {
        let r = try XCTUnwrap(API.search(userId: "u1", libraryId: "lib", kind: "movies", term: " the matrix "))
        XCTAssertEqual(r.method, "GET")
        XCTAssertTrue(r.path.hasPrefix("/Users/u1/Items?"))
        let q = query(r.path)
        XCTAssertEqual(q["ParentId"], "lib")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["SearchTerm"], "the matrix")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie,BoxSet")
        XCTAssertEqual(q["Limit"], "20")
        XCTAssertEqual(q["Fields"], "ProductionYear,Path")
        XCTAssertEqual(query(API.search(userId: "u", libraryId: "l", kind: "tvshows", term: "x")!.path)["IncludeItemTypes"], "Series,Season,Episode")
        XCTAssertNil(API.search(userId: "u", libraryId: "l", kind: nil, term: "  "))
    }

    func testDecodeHitsAndSelection() {
        let hits = API.decodeHits(Data(#"{"Items":[{"Id":"a","Name":"Pilot","Type":"Episode","SeriesName":"Lost","ProductionYear":2004},{"Id":"b","Name":"Heat","Type":"Movie"}]}"#.utf8))
        XCTAssertEqual(hits.map(\.id), ["a", "b"])
        XCTAssertEqual(hits[0].detail, "Lost · Episode · 2004")
        XCTAssertEqual(hits[1].detail, "Movie")
        XCTAssertEqual(API.moveSelection(nil, by: 1, count: 2), 0)
        XCTAssertEqual(API.moveSelection(1, by: 1, count: 2), 1)
        XCTAssertEqual(API.moveSelection(0, by: -1, count: 2), 0)
        XCTAssertNil(API.moveSelection(0, by: 1, count: 0))
    }

    func testLoadAndSaveRequests() throws {
        let l = API.load(userId: "u", itemId: "i")
        let f = query(l.path)["Fields"] ?? ""
        for k in ["Tags", "LockedFields", "LockData", "ProviderIds", "People", "Studios", "Taglines"] { XCTAssertTrue(f.contains(k), k) }
        let s = try XCTUnwrap(API.save(itemId: "i", item: ["Id": "i", "Name": "X"]))
        XCTAssertEqual(s.method, "POST")
        XCTAssertEqual(s.path, "/Items/i")
        XCTAssertEqual(s.contentType, "application/json")
    }

    func testDetailMenuStartsWithEditMetadata() {
        XCTAssertEqual(ItemAdminAPI.detailMenu(type: "Movie", admin: true).first, .editMetadata)
        XCTAssertEqual(ItemAdminAPI.Action.editMetadata.title, "Edit metadata…")
        XCTAssertEqual(ItemAdminAPI.detailMenu(type: "Movie", admin: false), [])
    }

    func testProviderLinks() {
        XCTAssertEqual(API.providerURL("Imdb", id: "tt1", type: "Movie")?.absoluteString, "https://www.imdb.com/title/tt1")
        XCTAssertEqual(API.providerURL("Tmdb", id: "5", type: "Series")?.absoluteString, "https://www.themoviedb.org/tv/5")
        XCTAssertNil(API.providerURL("Imdb", id: " ", type: nil))
        XCTAssertEqual(API.providerKeys("Movie", existing: ["Zap": "1"]), ["Imdb", "Tmdb", "Zap"])
    }
}
