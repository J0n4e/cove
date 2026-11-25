import XCTest
@testable import Cove

import ObjectiveC

/// Answers the app's server requests with recorded responses and remembers every request it saw. It only takes
/// `*.test` hosts. URLProtocol.registerClass alone doesn't reach sessions made from a configuration (Net.session),
/// so `install()` also puts ServerStub first in every `URLSessionConfiguration.default` made from then on; it must
/// run before Net.session is first used (nothing in the other test classes touches it).
final class ServerStub: URLProtocol {
    enum Reply { case json(Int, String), status(Int), fail(URLError.Code) }
    struct Seen { let url: URL; let method: String; let headers: [String: String]; let body: Data? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var log: [Seen] = []

    /// `path` matches the request path exactly (no query); unknown paths answer 404.
    static func on(_ path: String, _ r: Reply) { lock.withLock { routes[path] = r } }
    static var requests: [Seen] { lock.withLock { log } }
    static func reset() { lock.withLock { routes = [:]; log = [] } }

    private static let swizzled: Void = {
        let c: AnyClass = URLSessionConfiguration.self
        guard let a = class_getClassMethod(c, NSSelectorFromString("defaultSessionConfiguration")),
              let b = class_getClassMethod(c, #selector(URLSessionConfiguration.coveStubbedDefault)) else { return }
        method_exchangeImplementations(a, b)
    }()
    static func install() {
        _ = swizzled
        URLProtocol.registerClass(ServerStub.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let h = request.url?.host else { return false }
        return h.hasSuffix(".test")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            body = d
        }
        let reply: Reply = Self.lock.withLock {
            Self.log.append(Seen(url: url, method: request.httpMethod ?? "GET",
                                 headers: request.allHTTPHeaderFields ?? [:], body: body))
            return Self.routes[url.path] ?? .status(404)
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code):
            respond(url, code, Data())
        case .json(let code, let s):
            respond(url, code, Data(s.utf8))
        }
    }
    private func respond(_ url: URL, _ code: Int, _ data: Data) {
        let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLSessionConfiguration {
    /// Swapped with `defaultSessionConfiguration`, so calling it here runs the original.
    @objc dynamic class func coveStubbedDefault() -> URLSessionConfiguration {
        let c = coveStubbedDefault()
        c.protocolClasses = [ServerStub.self] + (c.protocolClasses ?? [])
        return c
    }
}

/// Request building, auth, decoding and error handling of Emby.swift against recorded Emby and Jellyfin answers.
/// Only talks to *.test hosts through ServerStub; nothing is saved to the preferences.
@MainActor
final class ServerTests: XCTestCase {
    static let host = "https://media.test:8920"
    let token = "tok-123"

    override class func setUp() {
        super.setUp()
        ServerStub.install()
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(ServerStub.self)
        super.tearDown()
    }
    override func setUp() async throws { ServerStub.reset() }
    override func tearDown() async throws { ServerStub.reset() }

    private func emby(jellyfin: Bool = false, server: String = ServerTests.host) -> Emby {
        let e = Emby()
        e.server = server; e.token = token; e.userId = "u1"; e.isJellyfin = jellyfin
        return e
    }
    private var lib: LibPref { LibPref(id: "lib1", name: "Movies", title: "Movies", style: "latest", kind: "movies") }

    private func query(_ u: URL) -> [String: String] {
        var q: [String: String] = [:]
        for i in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value }
        return q
    }
    private func last(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> ServerStub.Seen {
        try XCTUnwrap(ServerStub.requests.last { $0.url.path == path }, "no request to \(path)", file: file, line: line)
    }
    private func wait(_ cond: () -> Bool) async {
        for _ in 0..<100 where !cond() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: Request building and auth

    func testStubSeesAppSession() async {
        XCTAssertTrue((Net.session.configuration.protocolClasses ?? []).contains { ObjectIdentifier($0) == ObjectIdentifier(ServerStub.self) },
                      "Net.session was created before ServerStub.install()")
        ServerStub.on("/System/Info/Public", .json(200, Fixtures.embySystemInfoPublic))
        let j = await Emby.detectJellyfin(Self.host)
        XCTAssertEqual(j, false)
        XCTAssertTrue(ServerStub.requests.contains { $0.url.path == "/System/Info/Public" }, "ServerStub must see Net.session's requests")
    }

    func testDetectJellyfin() async {
        ServerStub.on("/System/Info/Public", .json(200, Fixtures.jellyfinSystemInfoPublic))
        let j = await Emby.detectJellyfin(Self.host)
        XCTAssertEqual(j, true)
        ServerStub.on("/System/Info/Public", .fail(.timedOut))
        let none = await Emby.detectJellyfin(Self.host)
        XCTAssertNil(none)
    }

    func testLibraryItemsRequestEmby() async throws {
        ServerStub.on("/Users/u1/Items", .json(200, Fixtures.embyLibraryPage))
        let e = emby()
        _ = await e.libraryItems(lib, limit: 50, start: 100, watch: "unwatched")
        let r = try last("/Users/u1/Items")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.host, "media.test"); XCTAssertEqual(r.url.port, 8920)
        let q = query(r.url)
        XCTAssertEqual(q["ParentId"], "lib1")
        XCTAssertEqual(q["StartIndex"], "100")
        XCTAssertEqual(q["Limit"], "50")
        XCTAssertEqual(q["SortBy"], "DateCreated")
        XCTAssertEqual(q["SortOrder"], "Descending")
        XCTAssertEqual(q["Filters"], "IsUnplayed")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["Fields"], "Overview,Genres,EndDate,Status,ProductionYear,ProviderIds,ChildCount,PrimaryImageAspectRatio")
        // Token only in headers for API calls, never in the link
        XCTAssertNil(q["api_key"]); XCTAssertNil(q["ApiKey"])
        XCTAssertEqual(r.headers["X-Emby-Token"], token)
        let auth = try XCTUnwrap(r.headers["Authorization"])
        XCTAssertTrue(auth.hasPrefix("MediaBrowser Client=\"Cove\""), auth)
        XCTAssertTrue(auth.contains("DeviceId=\"\(e.deviceId)\""), auth)
        XCTAssertTrue(auth.hasSuffix("Token=\"\(token)\""), auth)
    }

    func testLibraryItemsRequestJellyfinSameHeaders() async throws {
        ServerStub.on("/Users/u1/Items", .json(200, Fixtures.embyLibraryPage))
        let e = emby(jellyfin: true)
        _ = await e.libraryItems(lib, limit: 20, sort: "name", watch: "watched", favorites: true, groupCollections: true)
        let r = try last("/Users/u1/Items")
        let q = query(r.url)
        XCTAssertEqual(q["SortBy"], "SortName")
        XCTAssertEqual(q["SortOrder"], "Ascending")
        XCTAssertEqual(q["Filters"], "IsPlayed,IsFavorite")
        XCTAssertEqual(q["GroupItemsIntoCollections"], "true")
        XCTAssertEqual(q["StartIndex"], "0")
        // Jellyfin reads Authorization (with the token), Emby X-Emby-Token: both are always sent
        XCTAssertEqual(r.headers["X-Emby-Token"], token)
        XCTAssertTrue(r.headers["Authorization"]?.hasSuffix("Token=\"\(token)\"") ?? false)
        XCTAssertEqual(e.keyName, "ApiKey")
        XCTAssertEqual(emby().keyName, "api_key")
    }

    func testSortVariantsAndDescOverride() async throws {
        ServerStub.on("/Users/u1/Items", .json(200, Fixtures.embyLibraryPage))
        let e = emby()
        for (sort, by) in [("release", "PremiereDate,SortName"), ("top", "CommunityRating"), ("random", "Random")] {
            _ = await e.libraryItems(lib, limit: 10, sort: sort, desc: false)
            let q = query(try last("/Users/u1/Items").url)
            XCTAssertEqual(q["SortBy"], by); XCTAssertEqual(q["SortOrder"], "Ascending")
            XCTAssertNil(q["Filters"])
        }
        _ = await e.libraryItems(lib, limit: 10, genre: "Sci-Fi", letter: "#")
        let q = query(try last("/Users/u1/Items").url)
        XCTAssertEqual(q["Genres"], "Sci-Fi"); XCTAssertEqual(q["NameLessThan"], "A")
    }

    func testSearchEncodesPlus() async throws {
        ServerStub.on("/Users/u1/Items", .json(200, #"{"Items":[],"TotalRecordCount":0}"#))
        let r = await emby().search("Love + Death")
        XCTAssertEqual(r.count, 0)
        let u = try last("/Users/u1/Items").url
        XCTAssertTrue(u.absoluteString.contains("SearchTerm=Love%20%2B%20Death"), u.absoluteString)
        XCTAssertEqual(query(u)["SearchTerm"], "Love + Death")
    }

    func testLoginRequestAndWrongPassword() async throws {
        ServerStub.on("/Users/AuthenticateByName", .status(401))
        let e = emby()
        do {
            try await e.login(server: "https://login.test/web/index.html#!/home", user: "anna", pw: "p+w \"x\"")
            XCTFail("expected wrong password")
        } catch { XCTAssertTrue(error is LoginError, "\(error)") }
        let r = try XCTUnwrap(ServerStub.requests.last)
        XCTAssertEqual(r.url.absoluteString, "https://login.test/Users/AuthenticateByName")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertEqual(r.headers["X-Emby-Authorization"], e.authHeader)
        XCTAssertNil(r.headers["X-Emby-Token"])
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(r.body)) as? [String: String]
        XCTAssertEqual(body, ["Username": "anna", "Pw": "p+w \"x\""])
        // Nothing changed on failure
        XCTAssertEqual(e.server, Self.host); XCTAssertEqual(e.token, token)
    }

    func testLoginServerError() async {
        ServerStub.on("/Users/AuthenticateByName", .status(500))
        do { try await emby().login(server: "https://login.test", user: "a", pw: "b"); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
    }

    func testResumeUnreachableKeepsToken() async {
        ServerStub.on("/Users/u9", .fail(.notConnectedToInternet))
        let e = emby()
        let s = SavedServer(url: "https://other.test", name: "x", user: "a", token: "keep", userId: "u9")
        let r = await e.resume(s)
        XCTAssertEqual(r, .unreachable)
        XCTAssertEqual(ServerStub.requests.last?.headers["X-Emby-Token"], "keep")
        XCTAssertEqual(e.server, Self.host)
    }

    func testFavoriteAndPlayedRequests() async throws {
        let e = emby()
        await e.setFav("1001", true)
        XCTAssertEqual(try last("/Users/u1/FavoriteItems/1001").method, "POST")
        await e.setFav("1001", false)
        XCTAssertEqual(try last("/Users/u1/FavoriteItems/1001").method, "DELETE")
        await e.setPlayed("1002", true)
        let p = try last("/Users/u1/PlayedItems/1002")
        XCTAssertEqual(p.method, "POST"); XCTAssertEqual(p.headers["X-Emby-Token"], token)
        XCTAssertEqual(e.played["1002"], true); XCTAssertEqual(e.faved["1001"], false)
    }

    func testReportStoppedGoesToThePlaybacksOwnServer() async throws {
        let e = emby()
        let s = Emby.PlaySession(itemId: "1001", sourceId: "src1", method: "DirectPlay",
                                 url: URL(string: "https://old.test/Videos/1001/stream.mp4?PlaySessionId=ps42")!,
                                 server: "https://old.test", token: "old-token")
        await e.reportStopped(s, 600, duration: 6000, quick: true)
        let r = try XCTUnwrap(ServerStub.requests.last)
        XCTAssertEqual(r.url.absoluteString, "https://old.test/Sessions/Playing/Stopped")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["X-Emby-Token"], "old-token")
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.body)) as? [String: Any])
        XCTAssertEqual(b["ItemId"] as? String, "1001")
        XCTAssertEqual(b["PlaySessionId"] as? String, "ps42")
        XCTAssertEqual(b["MediaSourceId"] as? String, "src1")
        XCTAssertEqual(b["PlayMethod"] as? String, "DirectPlay")
        XCTAssertEqual((b["PositionTicks"] as? NSNumber)?.int64Value, 6_000_000_000)
        // Another server's item: local resume points untouched; DirectPlay: no encoding to kill
        XCTAssertNil(e.positions["1001"])
        XCTAssertFalse(ServerStub.requests.contains { $0.method == "DELETE" })
    }

    // MARK: Decoding

    func testDecodeEmbyLibraryPage() async throws {
        ServerStub.on("/Users/u1/Items", .json(200, Fixtures.embyLibraryPage))
        let e = emby()
        let page = await e.libraryItems(lib, limit: 3)
        let l = try XCTUnwrap(page)
        XCTAssertEqual(l.TotalRecordCount, 143)
        XCTAssertEqual(l.Items.map(\.Id), ["1001", "1002", "2001"])
        let m = l.Items[0]
        XCTAssertEqual(m.Name, "The Matrix"); XCTAssertEqual(m.`Type`, "Movie")
        XCTAssertEqual(m.ProductionYear, 1999); XCTAssertEqual(m.CommunityRating, 8.2)
        XCTAssertEqual(m.RunTimeTicks, 81_720_000_000)
        XCTAssertEqual(m.UserData?.Played, false); XCTAssertEqual(m.UserData?.IsFavorite, true)
        XCTAssertEqual(m.UserData?.PlaybackPositionTicks, 12_340_000_000)
        XCTAssertEqual(m.ImageTags?["Primary"], "f00dcafe")
        XCTAssertEqual(m.ProviderIds?["Imdb"], "tt0133093")
        XCTAssertEqual(e.resumeAt(m), 1234)
        XCTAssertTrue(e.isFav(m)); XCTAssertFalse(e.isPlayed(m))
        XCTAssertTrue(e.isPlayed(l.Items[1]))
        XCTAssertNil(l.Items[1].backdropId)          // no backdrop of its own, no parent
        let show = l.Items[2]
        XCTAssertTrue(show.isSeries); XCTAssertFalse(show.playable)
        XCTAssertEqual(show.yearText, "2022 – Present")
        XCTAssertEqual(show.UserData?.UnplayedItemCount, 7)
        // Image tags remembered from the list, link carries the tag but never the token
        let img = try XCTUnwrap(e.image("1001"))
        XCTAssertEqual(img.absoluteString, "\(Self.host)/Items/1001/Images/Primary?maxWidth=400&quality=80&tag=f00dcafe")
        XCTAssertFalse(img.absoluteString.contains(token))
    }

    func testDecodeJellyfinEpisodesWithMissingFields() async throws {
        ServerStub.on("/Shows/5e7e/Episodes", .json(200, Fixtures.jellyfinEpisodes))
        let e = emby(jellyfin: true)
        let eps = await e.episodes("5e7e")
        let q = query(try last("/Shows/5e7e/Episodes").url)
        XCTAssertEqual(q["UserId"], "u1")
        XCTAssertEqual(eps.count, 2)
        let a = eps[0], b = eps[1]
        XCTAssertTrue(a.isEpisode); XCTAssertEqual(a.IndexNumber, 1); XCTAssertEqual(a.ParentIndexNumber, 1)
        XCTAssertEqual(a.posterId, "5e7e5e7e5e7e5e7e5e7e5e7e5e7e5e7e")
        XCTAssertEqual(a.heroTitle, "Severance")
        XCTAssertEqual(a.backdropId, "5e7e5e7e5e7e5e7e5e7e5e7e5e7e5e7e")
        XCTAssertTrue(e.isPlayed(a))
        XCTAssertNil(b.ProductionYear); XCTAssertNil(b.CommunityRating); XCTAssertNil(b.Overview)
        XCTAssertEqual(b.yearText, " ")
        XCTAssertEqual(e.resumeAt(b), 900)
        // Series poster tag learned from the episode
        XCTAssertTrue(e.image("5e7e5e7e5e7e5e7e5e7e5e7e5e7e5e7e")?.absoluteString.hasSuffix("&tag=spt0000001") ?? false)
    }

    func testLatestDropsNonVideoJellyfinItems() async throws {
        ServerStub.on("/Users/u1/Items/Latest", .json(200, Fixtures.jellyfinLatest))
        let r = await emby(jellyfin: true).latest(lib, limit: 20)
        XCTAssertEqual(r.map(\.Id), ["m1", "s1"])
        XCTAssertEqual(query(try last("/Users/u1/Items/Latest").url)["ParentId"], "lib1")
    }

    func testDecodeFullWithMediaSources() async throws {
        ServerStub.on("/Users/u1/Items/1001", .json(200, Fixtures.embyFullMovie))
        let full = await emby().full("1001")
        let f = try XCTUnwrap(full)
        XCTAssertEqual(f.OfficialRating, "R"); XCTAssertEqual(f.CriticRating, 83)
        XCTAssertEqual(f.Studios?.map(\.Name), ["Warner Bros. Pictures"])
        XCTAssertEqual(f.People?.first?.Role, "Neo"); XCTAssertNil(f.People?.last?.Role)
        XCTAssertEqual(f.Chapters?.last?.start, 300); XCTAssertEqual(f.Chapters?.last?.isMarker, true)
        XCTAssertEqual(f.UserData?.LastPlayedDate, "2026-09-30T19:00:00.0000000Z")
        let src = try XCTUnwrap(f.MediaSources?.first)
        XCTAssertEqual(src.Id, "src1"); XCTAssertEqual(src.Container, "mkv"); XCTAssertEqual(src.Size, 28_547_219_456)
        let streams = try XCTUnwrap(src.MediaStreams)
        XCTAssertEqual(streams.map(\.Index), [0, 1, 2, 3])
        XCTAssertEqual(streams[0].VideoRange, "HDR 10"); XCTAssertEqual(streams[0].Width, 3840)
        // Text subtitle preferred over the picture one in the same language
        XCTAssertEqual(preferredSub(streams, lang: "Romanian"), 3)
        let q = query(try last("/Users/u1/Items/1001").url)
        XCTAssertTrue(q["Fields"]?.hasPrefix("Overview,People,Genres,Studios,MediaSources,MediaStreams") ?? false)
    }

    func testCollectionsUseEachServersCall() async throws {
        ServerStub.on("/Items/1001/Collections", .json(200, #"{"Items":[{"Id":"bx","Name":"Matrix Collection","Type":"BoxSet"}]}"#))
        let j = await emby(jellyfin: true).collections(containing: "1001")
        XCTAssertEqual(j.map(\.Id), ["bx"])
        ServerStub.on("/Users/u1/Items", .json(200, #"{"Items":[{"Id":"bx","Name":"Matrix Collection","Type":"BoxSet"}]}"#))
        _ = await emby().collections(containing: "1001")
        XCTAssertEqual(query(try last("/Users/u1/Items").url)["ListItemIds"], "1001")
    }

    // MARK: Error mapping

    func testServerErrorSetsFailureAndReturnsNil() async {
        ServerStub.on("/Users/u1/Items", .status(500))
        let e = emby()
        let r = await e.libraryItems(lib, limit: 10)
        XCTAssertNil(r)
        XCTAssertEqual(e.lastFailure, Emby.describe(URLError(.badServerResponse), server: e.currentServerName))
        // A later success clears it
        ServerStub.on("/Users/u1/Items", .json(200, Fixtures.embyLibraryPage))
        _ = await e.libraryItems(lib, limit: 10)
        XCTAssertNil(e.lastFailure)
    }

    func testNetworkFailureMessage() async {
        ServerStub.on("/Users/u1/Items", .fail(.cannotConnectToHost))
        let e = emby()
        let none = await e.libraryItems(lib, limit: 10)
        XCTAssertNil(none)
        XCTAssertTrue(e.lastFailure?.hasPrefix("Can't reach") ?? false, e.lastFailure ?? "nil")
    }

    func testMalformedJSONDoesNotCrash() async {
        ServerStub.on("/Users/u1/Items", .json(200, Fixtures.malformed))
        ServerStub.on("/Shows/s/Episodes", .json(200, "<html>proxy error</html>"))
        let e = emby()
        let none = await e.libraryItems(lib, limit: 10)
        XCTAssertNil(none)
        let eps = await e.episodes("s")
        XCTAssertEqual(eps.count, 0)
        XCTAssertEqual(e.lastFailure, Emby.describe(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "")),
                                                    server: e.currentServerName))
    }

    func testUnauthorizedChecksSessionAndExpires() async {
        ServerStub.on("/Users/u1/Items", .status(401))
        ServerStub.on("/Users/u1", .status(401))
        let e = emby()
        let none = await e.libraryItems(lib, limit: 10)
        XCTAssertNil(none)
        XCTAssertNil(e.lastFailure)                   // a 401 isn't shown as a failure
        await wait { e.sessionExpired }
        XCTAssertTrue(e.sessionExpired)
        XCTAssertEqual(ServerStub.requests.last { $0.url.path == "/Users/u1" }?.headers["X-Emby-Token"], token)
    }

    func testUnauthorizedEndpointWithValidSessionDoesNotExpire() async {
        ServerStub.on("/Sessions", .status(401))
        ServerStub.on("/Users/u1", .json(200, #"{"Id":"u1","Name":"anna"}"#))
        let e = emby()
        let now = await e.nowPlaying()
        XCTAssertEqual(now.count, 0)
        await wait { ServerStub.requests.contains { $0.url.path == "/Users/u1" } }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(e.sessionExpired)
    }

    func testPlaybackInfoStatusMapping() {
        XCTAssertEqual(Emby.playbackInfoStatus(nil), .ok)
        XCTAssertEqual(Emby.playbackInfoStatus(200), .ok)
        XCTAssertEqual(Emby.playbackInfoStatus(401), .sessionEnded)
        XCTAssertEqual(Emby.playbackInfoStatus(500), .serverError(500))
        XCTAssertEqual(Emby.playbackInfoStatus(403), .serverError(403))
    }

    private func movie(_ id: String = "1001") -> Item {
        try! JSONDecoder().decode(Item.self, from: Data(#"{"Id":"\#(id)","Name":"M","Type":"Movie"}"#.utf8))
    }

    func testResolveStream401() async {
        ServerStub.on("/Items/1001/PlaybackInfo", .status(401))
        ServerStub.on("/Users/u1", .status(401))
        let e = emby()
        let u = await e.resolveStream(PlayRequest(item: movie()))
        XCTAssertNil(u)
        XCTAssertEqual(e.lastStreamError, "Your session on the server has ended. Sign in again.")
        await wait { e.sessionExpired }
        XCTAssertTrue(e.sessionExpired)
    }

    func testResolveStream500() async {
        ServerStub.on("/Items/1001/PlaybackInfo", .status(500))
        let e = emby()
        let none = await e.resolveStream(PlayRequest(item: movie()))
        XCTAssertNil(none)
        XCTAssertEqual(e.lastStreamError, "The server couldn't prepare this video (HTTP 500).")
    }

    func testResolveStreamNetworkFailureFallsBack() async throws {
        ServerStub.on("/Items/1001/PlaybackInfo", .fail(.timedOut))
        let e = emby(jellyfin: true)
        let got = await e.resolveStream(PlayRequest(item: movie(), sourceId: "src1"))
        let u = try XCTUnwrap(got)
        XCTAssertNil(e.lastStreamError)
        XCTAssertEqual(u.path, "/Videos/1001/master.m3u8")
        let q = query(u)
        XCTAssertEqual(q["MediaSourceId"], "src1"); XCTAssertEqual(q["ApiKey"], token); XCTAssertNil(q["api_key"])
    }

    func testResolveStreamMalformedFallsBack() async throws {
        ServerStub.on("/Items/1001/PlaybackInfo", .json(200, Fixtures.malformed))
        let got = await emby().resolveStream(PlayRequest(item: movie()), reencode: true)
        let u = try XCTUnwrap(got)
        XCTAssertEqual(u.path, "/Videos/1001/master.m3u8")
        XCTAssertEqual(query(u)["api_key"], token)
        XCTAssertEqual(query(u)["AllowVideoStreamCopy"], "false")
    }

    func testResolveStreamDirectPlayEmby() async throws {
        ServerStub.on("/Items/1001/PlaybackInfo", .json(200, Fixtures.embyPlaybackInfoDirect))
        let e = emby()
        let got = await e.resolveStream(PlayRequest(item: movie(), sourceId: "src1"))
        let u = try XCTUnwrap(got)
        XCTAssertEqual(u.absoluteString, "\(Self.host)/Videos/1001/stream.mp4?Static=true&MediaSourceId=src1&api_key=\(token)")
        let r = try last("/Items/1001/PlaybackInfo")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["X-Emby-Token"], token)
        let q = query(r.url)
        XCTAssertEqual(q["UserId"], "u1"); XCTAssertEqual(q["IsPlayback"], "true"); XCTAssertEqual(q["MediaSourceId"], "src1")
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.body)) as? [String: Any])
        let p = try XCTUnwrap(b["DeviceProfile"] as? [String: Any])
        XCTAssertEqual(p["Name"] as? String, "Cove Mac")
        XCTAssertEqual((p["DirectPlayProfiles"] as? [Any])?.count, 1)
    }

    func testResolveStreamTranscodeJellyfin() async throws {
        ServerStub.on("/Items/e7f1/PlaybackInfo", .json(200, Fixtures.jellyfinPlaybackInfoTranscode))
        let e = emby(jellyfin: true)
        let req = PlayRequest(item: movie("e7f1"), sourceId: "src9", sub: 3)
        let got = await e.resolveStream(req, maxWidth: 1920)
        let u = try XCTUnwrap(got)
        XCTAssertEqual(u.host, "media.test"); XCTAssertEqual(u.scheme, "https"); XCTAssertEqual(u.port, 8920)
        XCTAssertEqual(u.path, "/videos/e7f1/master.m3u8")
        let q = query(u)
        XCTAssertEqual(q["ApiKey"], token); XCTAssertNil(q["api_key"])
        XCTAssertEqual(q["SubtitleStreamIndex"], "3"); XCTAssertEqual(q["SubtitleMethod"], "Encode")
        XCTAssertEqual(q["MaxWidth"], "1920")
        XCTAssertEqual(q["VideoBitrate"], String(Emby.defaultConversionBitrate))
        XCTAssertEqual(q["PlaySessionId"], "abc123")
        // Chosen subtitle: no direct play offered
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(try last("/Items/e7f1/PlaybackInfo").body)) as? [String: Any])
        XCTAssertEqual(((b["DeviceProfile"] as? [String: Any])?["DirectPlayProfiles"] as? [Any])?.count, 0)
    }

    // MARK: The token stays with the server

    func testTokenNotAddedForAnotherHost() async throws {
        ServerStub.on("/Items/1001/PlaybackInfo", .json(200, Fixtures.playbackInfoTranscode(at: "https://cdn.elsewhere.test")))
        let got = await emby().resolveStream(PlayRequest(item: movie()))
        let u = try XCTUnwrap(got)
        XCTAssertEqual(u.host, "cdn.elsewhere.test")
        XCTAssertFalse(u.absoluteString.contains(token), u.absoluteString)
    }

    func testTokenNotAddedForHttpOnSameHost() async throws {
        // https server; reply points at http on the same host and port
        ServerStub.on("/Items/1001/PlaybackInfo", .json(200, Fixtures.playbackInfoTranscode(at: "http://media.test:8920")))
        let got = await emby().resolveStream(PlayRequest(item: movie()))
        let u = try XCTUnwrap(got)
        XCTAssertEqual(u.scheme, "http")
        XCTAssertFalse(u.absoluteString.contains(token), u.absoluteString)
        // Same origin with the default port written out does get it
        ServerStub.on("/Items/1001/PlaybackInfo", .json(200, Fixtures.playbackInfoTranscode(at: "https://plain.test:443")))
        let got2 = await emby(server: "https://plain.test").resolveStream(PlayRequest(item: movie()))
        let ok = try XCTUnwrap(got2)
        XCTAssertEqual(query(ok)["api_key"], token)
    }

    func testSameOriginRules() {
        let s = URL(string: "https://media.test")!
        XCTAssertTrue(Net.sameOrigin(URL(string: "https://MEDIA.test:443/x")!, s))
        XCTAssertFalse(Net.sameOrigin(URL(string: "http://media.test:443/x")!, s))
        XCTAssertFalse(Net.sameOrigin(URL(string: "https://media.test:8920/x")!, s))
        XCTAssertFalse(Net.sameOrigin(URL(string: "https://evil.test/x")!, s))
    }

    func testImageLinksNeverCarryToken() {
        let e = emby(jellyfin: true)
        let u = e.image("x1", "Backdrop", width: 1280, plain: true)!
        XCTAssertEqual(u.absoluteString, "\(Self.host)/Items/x1/Images/Backdrop?maxWidth=1280&quality=80&EnableImageEnhancers=false")
        XCTAssertFalse(u.absoluteString.contains(token))
    }
}
