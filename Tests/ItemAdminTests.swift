import XCTest
@testable import Cove

/// Item admin tools (Sources/Admin/ItemAdminAPI.swift): request shapes for Emby and Jellyfin, decoding, menu rules.
final class ItemAdminTests: XCTestCase {
    typealias API = ItemAdminAPI

    private func query(_ path: String) -> [String: String] {
        var out: [String: String] = [:]
        for q in URLComponents(string: "http://x" + path)?.queryItems ?? [] { out[q.name] = q.value }
        return out
    }
    private func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }

    // MARK: Refresh

    func testRefreshScan() {
        let r = API.refresh(itemId: "abc", mode: .scan, replaceImages: true)
        XCTAssertEqual(r.method, "POST")
        XCTAssertTrue(r.path.hasPrefix("/Items/abc/Refresh?"))
        let q = query(r.path)
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["MetadataRefreshMode"], "Default")
        XCTAssertEqual(q["ImageRefreshMode"], "Default")
        XCTAssertEqual(q["ReplaceAllMetadata"], "false")
        XCTAssertEqual(q["ReplaceAllImages"], "false")   // scan never replaces images
    }

    func testRefreshMissing() {
        let q = query(API.refresh(itemId: "abc", mode: .missing, replaceImages: false).path)
        XCTAssertEqual(q["MetadataRefreshMode"], "FullRefresh")
        XCTAssertEqual(q["ImageRefreshMode"], "FullRefresh")
        XCTAssertEqual(q["ReplaceAllMetadata"], "false")
        XCTAssertEqual(q["ReplaceAllImages"], "false")
        XCTAssertEqual(query(API.refresh(itemId: "abc", mode: .missing, replaceImages: true).path)["ReplaceAllImages"], "true")
    }

    func testRefreshReplaceAllAsksFirst() {
        let q = query(API.refresh(itemId: "abc", mode: .replaceAll, replaceImages: true).path)
        XCTAssertEqual(q["MetadataRefreshMode"], "FullRefresh")
        XCTAssertEqual(q["ReplaceAllMetadata"], "true")
        XCTAssertEqual(q["ReplaceAllImages"], "true")
        XCTAssertTrue(API.RefreshMode.replaceAll.needsConfirm)
        XCTAssertFalse(API.RefreshMode.scan.needsConfirm)
        XCTAssertFalse(API.RefreshMode.missing.needsConfirm)
    }

    func testRefreshSnapshotChangesWithDateOrTags() {
        let a: [String: Any] = ["DateLastRefreshed": "2026-01-01", "ImageTags": ["Primary": "t1"]]
        let b: [String: Any] = ["DateLastRefreshed": "2026-01-01", "ImageTags": ["Primary": "t2"]]
        let c: [String: Any] = ["DateLastRefreshed": "2026-01-02", "ImageTags": ["Primary": "t1"]]
        XCTAssertNotEqual(API.snapshot(a), API.snapshot(b))
        XCTAssertNotEqual(API.snapshot(a), API.snapshot(c))
        XCTAssertEqual(API.snapshot(a), API.snapshot(a))
    }

    // MARK: Identify

    func testRemoteSearchMovieBody() throws {
        let r = try XCTUnwrap(API.remoteSearch(itemId: "m1", type: "Movie", name: " Heat ", year: 1995,
                                               providerIds: ["Imdb": "tt0113277", "Tmdb": " "]))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/Items/RemoteSearch/Movie")
        XCTAssertEqual(r.contentType, "application/json")
        let b = json(r.body)
        XCTAssertEqual(b["ItemId"] as? String, "m1")
        XCTAssertEqual(b["IncludeDisabledProviders"] as? Bool, true)
        let info = try XCTUnwrap(b["SearchInfo"] as? [String: Any])
        XCTAssertEqual(info["Name"] as? String, "Heat")
        XCTAssertEqual(info["Year"] as? Int, 1995)
        XCTAssertEqual(info["ProviderIds"] as? [String: String], ["Imdb": "tt0113277"])   // empty ids dropped
    }

    func testRemoteSearchSeriesAndOthers() {
        XCTAssertEqual(API.remoteSearch(itemId: "s", type: "Series", name: "Dark", year: nil, providerIds: [:])?.path, "/Items/RemoteSearch/Series")
        XCTAssertNil(API.remoteSearch(itemId: "e", type: "Episode", name: "x", year: nil, providerIds: [:]))
        XCTAssertNil(API.remoteSearch(itemId: "b", type: "BoxSet", name: "x", year: nil, providerIds: [:]))
        XCTAssertEqual(API.providerFields("Series"), ["Imdb", "Tmdb", "Tvdb"])
        XCTAssertEqual(API.providerFields("Movie"), ["Imdb", "Tmdb"])
    }

    /// Emby and Jellyfin both answer a plain array; Jellyfin sends ProductionYear, Emby sometimes only PremiereDate.
    func testDecodeSearchBothServers() throws {
        let jf = #"[{"Name":"Heat","ProductionYear":1995,"ProviderIds":{"Tmdb":"949","Imdb":"tt0113277"},"ImageUrl":"https://image.tmdb.org/t/p/original/a.jpg","SearchProviderName":"TheMovieDb","Overview":"A crew"}]"#
        let emby = #"[{"Name":"Heat","PremiereDate":"1995-12-15T00:00:00.0000000Z","ProviderIds":{"Tmdb":949},"ImageUrl":"","SearchProviderName":"TheMovieDb"},{"Overview":"no name"}]"#
        let a = API.decodeSearch(Data(jf.utf8))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].name, "Heat"); XCTAssertEqual(a[0].year, 1995)
        XCTAssertEqual(a[0].providerIds["Tmdb"], "949"); XCTAssertEqual(a[0].provider, "TheMovieDb")
        XCTAssertEqual(a[0].imageURL, "https://image.tmdb.org/t/p/original/a.jpg")
        let b = API.decodeSearch(Data(emby.utf8))
        XCTAssertEqual(b.count, 1)                 // the nameless entry is skipped
        XCTAssertEqual(b[0].year, 1995)            // from PremiereDate
        XCTAssertEqual(b[0].providerIds["Tmdb"], "949")   // a number id becomes text
        XCTAssertNil(b[0].imageURL)
    }

    func testApplySendsTheResultBack() throws {
        let r = API.decodeSearch(Data(#"[{"Name":"Heat","ProductionYear":1995,"ProviderIds":{"Tmdb":"949"}}]"#.utf8))[0]
        let req = API.apply(itemId: "m1", result: r)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/Items/RemoteSearch/Apply/m1?ReplaceAllImages=true")
        XCTAssertEqual(req.contentType, "application/json")
        let b = json(req.body)
        XCTAssertEqual(b["Name"] as? String, "Heat")
        XCTAssertEqual(b["ProductionYear"] as? Int, 1995)
        XCTAssertEqual((b["ProviderIds"] as? [String: String])?["Tmdb"], "949")
    }

    // MARK: Images

    func testRemoteImagesRequest() {
        XCTAssertEqual(API.remoteImages(itemId: "m1", type: "Primary").path, "/Items/m1/RemoteImages?Type=Primary&IncludeAllLanguages=false&Language=en")
        XCTAssertEqual(API.remoteImages(itemId: "m1", type: "Backdrop", allLanguages: true, provider: "The Movie Db").path,
                       "/Items/m1/RemoteImages?Type=Backdrop&IncludeAllLanguages=true&Language=en&ProviderName=The%20Movie%20Db")
    }

    func testDecodeRemoteImages() {
        let s = #"{"Images":[{"ProviderName":"TheMovieDb","Url":"https://i/a.jpg","ThumbnailUrl":"https://i/w300/a.jpg","Height":3000,"Width":2000,"CommunityRating":5.3,"VoteCount":12,"Language":"en","Type":"Primary"},{"Url":"https://i/a.jpg"},{"ProviderName":"Fanart","Url":"https://f/b.png","Language":""}],"TotalRecordCount":3,"Providers":["TheMovieDb","Fanart"]}"#
        let r = API.decodeRemoteImages(Data(s.utf8))
        XCTAssertEqual(r.images.count, 2)   // duplicate link dropped
        XCTAssertEqual(r.providers, ["TheMovieDb", "Fanart"])
        XCTAssertEqual(r.images[0].resolution, "2000 × 3000")
        XCTAssertEqual(r.images[0].rating, 5.3)
        XCTAssertEqual(r.images[0].votes, 12)
        XCTAssertEqual(r.images[0].language, "en")
        XCTAssertNil(r.images[1].language)
        XCTAssertNil(r.images[1].resolution)
    }

    func testDownloadURLEncodesTheImageLink() {
        let img = API.RemoteImage(url: "https://x.org/p/a.jpg?w=1&h=2", thumbnailURL: nil, provider: "TheMovieDb",
                                  width: nil, height: nil, language: nil, rating: nil, votes: nil)
        let r = API.download(itemId: "m1", type: "Primary", image: img)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/Items/m1/RemoteImages/Download?Type=Primary&ImageUrl=https%3A%2F%2Fx.org%2Fp%2Fa.jpg%3Fw%3D1%26h%3D2&ProviderName=TheMovieDb")
        XCTAssertEqual(query(r.path)["ImageUrl"], img.url)   // decodes back to the same link
    }

    /// Same path and base64 body on Emby and Jellyfin (no per-server branch), Content-Type from the file's bytes.
    func testUploadRequest() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9])
        let a = try XCTUnwrap(API.upload(itemId: "m1", type: "Primary", data: jpeg))
        XCTAssertEqual(a.method, "POST")
        XCTAssertEqual(a.path, "/Items/m1/Images/Primary")
        XCTAssertEqual(a.contentType, "image/jpeg")
        XCTAssertEqual(a.body, Data(jpeg.base64EncodedString().utf8))
        let b = try XCTUnwrap(API.upload(itemId: "m1", type: "Backdrop", data: png))
        XCTAssertEqual(b.path, "/Items/m1/Images/Backdrop")
        XCTAssertEqual(b.contentType, "image/png")
        XCTAssertNil(API.upload(itemId: "m1", type: "Primary", data: Data("GIF89a".utf8)))
    }

    func testDeleteAndCurrentImages() {
        XCTAssertEqual(API.deleteImage(itemId: "m1", type: "Backdrop", index: 2),
                       API.Request(method: "DELETE", path: "/Items/m1/Images/Backdrop/2"))
        let cur = API.currentImages(["ImageTags": ["Primary": "p", "Logo": "l"], "BackdropImageTags": ["b0", "b1"]])
        XCTAssertEqual(cur["Primary"], ["p"]); XCTAssertEqual(cur["Backdrop"], ["b0", "b1"]); XCTAssertEqual(cur["Logo"], ["l"])
        XCTAssertTrue(API.imagePath(itemId: "m1", type: "Backdrop", index: 1, tag: "b1", maxWidth: 480).hasPrefix("/Items/m1/Images/Backdrop/1?"))
    }

    func testImageTypesPerKind() {
        XCTAssertEqual(API.imageTypes("Movie").first, "Primary")
        XCTAssertTrue(API.imageTypes("Movie").contains("Disc"))
        XCTAssertFalse(API.imageTypes("Series").contains("Disc"))
        XCTAssertEqual(API.imageTypes("Episode"), ["Primary"])
        XCTAssertTrue(API.isMultiple("Backdrop")); XCTAssertFalse(API.isMultiple("Primary"))
    }

    // MARK: Missing posters

    /// Neither server filters on a MISSING image, so the query asks for every movie/show/collection and no
    /// HasPrimaryImage / ImageTypes filter; the filter runs here on the tags.
    func testMissingQueryHasNoServerImageFilter() {
        let r = API.missingPage(userId: "u1", libraryId: "L", start: 300, limit: 300)
        XCTAssertTrue(r.path.hasPrefix("/Users/u1/Items?"))
        let q = query(r.path)
        XCTAssertEqual(q["ParentId"], "L"); XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie,Series,BoxSet")
        XCTAssertEqual(q["StartIndex"], "300"); XCTAssertEqual(q["Limit"], "300")
        XCTAssertNil(q["HasPrimaryImage"]); XCTAssertNil(q["ImageTypes"])
    }

    func testMissingFilterClientSide() {
        let s = #"{"Items":[{"Id":"1","Name":"Has both","Type":"Movie","ImageTags":{"Primary":"p"},"BackdropImageTags":["b"]},{"Id":"2","Name":"No poster","Type":"Movie","ProductionYear":2001,"Path":"/m/a.mkv","ImageTags":{"Logo":"l"},"BackdropImageTags":["b"]},{"Id":"3","Name":"Nothing","Type":"Series"}],"TotalRecordCount":3}"#
        let poster = API.decodeMissing(Data(s.utf8), .poster)
        XCTAssertEqual(poster.rows.map(\.id), ["2", "3"])
        XCTAssertEqual(poster.pageCount, 3); XCTAssertEqual(poster.total, 3)
        XCTAssertEqual(poster.rows[0].year, 2001); XCTAssertEqual(poster.rows[0].path, "/m/a.mkv")
        XCTAssertEqual(API.decodeMissing(Data(s.utf8), .backdrop).rows.map(\.id), ["3"])
    }

    // MARK: Menu

    func testDetailMenuAdminOnly() {
        XCTAssertEqual(API.detailMenu(type: "Movie", admin: false), [])
        XCTAssertEqual(API.detailMenu(type: "Movie", admin: nil), [])   // role not known yet: nothing
        XCTAssertEqual(API.detailMenu(type: "Movie", admin: true), [.editMetadata, .refresh, .identify, .images, .web])
        XCTAssertEqual(API.detailMenu(type: "Series", admin: true), [.editMetadata, .refresh, .identify, .images, .web])
        XCTAssertEqual(API.detailMenu(type: "Season", admin: true), [.editMetadata, .refresh, .images, .web])
        XCTAssertEqual(API.detailMenu(type: "Episode", admin: true), [.editMetadata, .refresh, .images, .web])
        XCTAssertEqual(API.detailMenu(type: "BoxSet", admin: true), [.editMetadata, .refresh, .images, .web])
        XCTAssertEqual(API.detailMenu(type: "Person", admin: true), [])
    }

    func testLibraryMenu() {
        XCTAssertEqual(API.libraryMenu(kind: "movies", admin: true), [.missingPosters, .missingBackdrops])
        XCTAssertEqual(API.libraryMenu(kind: "tvshows", admin: true), [.missingPosters, .missingBackdrops])
        XCTAssertEqual(API.libraryMenu(kind: "movies", admin: false), [])
        XCTAssertEqual(API.libraryMenu(kind: "music", admin: true), [])
    }

    func testWebDashboardLinks() {
        XCTAssertEqual(API.webURL(server: "https://emby.x", itemId: "123", jellyfin: false)?.absoluteString,
                       "https://emby.x/web/index.html#!/item?id=123")
        XCTAssertEqual(API.webURL(server: "https://jf.x/", itemId: "abc", jellyfin: true)?.absoluteString,
                       "https://jf.x/web/#/details?id=abc")
    }

    func testPlainErrors() {
        XCTAssertNil(API.message(status: 204, action: "x"))
        XCTAssertTrue(API.message(status: 403, action: "refresh the metadata")!.contains("administrator"))
        XCTAssertTrue(API.message(status: 404, action: "x")!.contains("couldn't find"))
    }

    func testAdminIsLastInDetailRow() {
        XCTAssertEqual(DetailRowOrder.order.suffix(3), ["favorite", "admin", "rating"])
    }
}
