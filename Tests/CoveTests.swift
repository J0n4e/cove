import XCTest
@testable import Cove

/// Checks for the parts that don't need a server or the UI.
@MainActor
final class CoveTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Emby.normalize("  myserver:8096/ "), "http://myserver:8096")
        XCTAssertEqual(Emby.normalize("https://a.b//"), "https://a.b")
        XCTAssertEqual(Emby.normalize("HTTP://A.B"), "HTTP://A.B")
    }

    func testSameOrigin() {
        let u = { (s: String) in URL(string: s)! }
        XCTAssertTrue(Net.sameOrigin(u("http://Host:8096/a"), u("http://host:8096/b")))
        XCTAssertTrue(Net.sameOrigin(u("https://host/a"), u("https://host:443")))
        XCTAssertFalse(Net.sameOrigin(u("http://host/a"), u("https://host/a")))
        XCTAssertFalse(Net.sameOrigin(u("http://host:8096"), u("http://other:8096")))
    }

    func testWithoutVideoCopy() {
        let s = Emby.withoutVideoCopy("http://h/v.mp4?a=1&allowvideostreamcopy=true")
        XCTAssertTrue(s.contains("a=1"))
        XCTAssertTrue(s.contains("AllowVideoStreamCopy=false"))
        XCTAssertFalse(s.contains("allowvideostreamcopy=true"))
    }

    func testSavedServerRoundTrip() throws {
        let a = [SavedServer(url: "http://Host:8096", name: "Home", user: "me", token: "t", userId: "u")]
        let b = try JSONDecoder().decode([SavedServer].self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, b)
        XCTAssertEqual(b[0].id, "http://host:8096")
    }

    /// Lists saved by older versions (no token / user id) must still load.
    func testSavedServerOldFormat() throws {
        let old = #"[{"url":"http://h","name":"n","user":"x"}]"#.data(using: .utf8)!
        let b = try JSONDecoder().decode([SavedServer].self, from: old)
        XCTAssertNil(b[0].token)
    }

    func testNavOrder() {
        let f = NavOrder.favorites, n = NavOrder.nowPlaying
        // Nothing saved: both sections in their usual place
        XCTAssertEqual(NavOrder.rows("", libIds: ["a", "b"]), [f, n, "a", "b"])
        // Saved after a library, kept there even when the libraries are reordered
        let r = NavOrder.rows("a,\(f),b,\(n)", libIds: ["b", "a"])
        XCTAssertEqual(r, ["b", n, "a", f])
        XCTAssertEqual(NavOrder.top(r), [])
        XCTAssertEqual(NavOrder.after("a", r), [f])
        // The library it followed is gone: back to the usual place
        XCTAssertEqual(NavOrder.rows("x,\(f),\(n)", libIds: ["a"]), [f, n, "a"])
    }

    func testIsPrivate() {
        for h in ["localhost", "nas", "nas.local", "192.168.1.10", "10.0.0.5", "172.20.1.1", "100.64.0.1", "fd00::1", "[::1]"] {
            XCTAssertTrue(ConnectionSecurity.isPrivate(h), h)
        }
        // Look-alikes and disguised numbers are not the home network
        for h in ["", "134744072", "0x7f000001", "010.0.0.1", "192.168.1.1.nip.io", "10.0.0.1.evil.com", "8.8.8.8", "example.com"] {
            XCTAssertFalse(ConnectionSecurity.isPrivate(h), h)
        }
    }

    func testYouTubeID() {
        let id = { (s: String) in Trailer.youTubeID(URL(string: s)!) }
        XCTAssertEqual(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("http://youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(id("https://vimeo.com/123456"))
        XCTAssertNil(id("https://www.youtube.com/watch?v=x'%3Balert(1)"))
        XCTAssertNil(id("https://notyoutube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testSafeLink() {
        XCTAssertNotNil(SafeLink.url("https://www.imdb.com/title/tt0111161"))
        XCTAssertNotNil(SafeLink.url(" http://example.com "))
        for s in ["file:///etc/passwd", "smb://server/share", "javascript:alert(1)", "vnc://host", "https://", ""] {
            XCTAssertNil(SafeLink.url(s), s)
        }
    }

    func testInternalPrefs() {
        for k in ["servers", "token", "did", "jellyfin-http://nas:8096", "imageCacheNoHeaders"] { XCTAssertTrue(InternalPrefs.contains(k), k) }
        for k in ["accent", "subLang", "playerVolume", "libs-abc"] { XCTAssertFalse(InternalPrefs.contains(k), k) }
    }

    func testParseSRT() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\n\r\n2\n00:00:03,000 --> 00:00:04,000\nTwo\nlines\n"
        let c = Cue.parseSRT(srt)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.first?.start ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(c.first?.end ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(c.last?.text, "Two\nlines")
    }

    func testTranscodingProfile() {
        // HEVC must come in fMP4 (AVPlayer rejects HEVC in MPEG-TS); conversion stays H.264 (listed first)
        let h = Emby.transcodingProfile(hevc: true)
        XCTAssertEqual(h["Container"] as? String, "mp4")
        XCTAssertEqual(h["VideoCodec"] as? String, "h264,hevc")
        let t = Emby.transcodingProfile(hevc: false)
        XCTAssertEqual(t["Container"] as? String, "ts")
        XCTAssertEqual(t["VideoCodec"] as? String, "h264")
    }

    func testCapConversion() {
        let u = "https://s/videos/1/master.m3u8?VideoBitrate=96000000&MaxWidth=3840&x=1"
        let c = URLComponents(string: Emby.capConversion(u, maxWidth: 2560, maxBitrate: 40_000_000))!
        func v(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        XCTAssertEqual(v("VideoBitrate"), "40000000")
        XCTAssertEqual(v("MaxWidth"), "2560")
        XCTAssertEqual(v("x"), "1")
        // a lower value already asked for is kept
        let d = URLComponents(string: Emby.capConversion("https://s/a?VideoBitrate=8000000", maxWidth: nil, maxBitrate: 40_000_000))!
        XCTAssertEqual(d.queryItems?.first { $0.name == "VideoBitrate" }?.value, "8000000")
        XCTAssertNil(d.queryItems?.first { $0.name == "MaxWidth" })
    }

    func testTraktIds() {
        let ids = Trakt.ids(["Imdb": "tt0133093", "tmdb": "603", "Tvdb": "", "TvRage": "1", "Tmdb2": "x"])
        XCTAssertEqual(ids, ["imdb": "tt0133093", "tmdb": "603"])
        XCTAssertEqual(Trakt.ids(["Imdb": "0133093", "Tmdb": "abc"]), [:])
        XCTAssertEqual(Trakt.keys(kind: "movie", ids: ids), ["movie:imdb:tt0133093", "movie:tmdb:603"])
    }

    func testSealedPrefs() {
        let name = "test.sealed.\(UUID().uuidString)"
        defer { SealedPrefs.set(nil, for: name) }
        SealedPrefs.set("abc123secret", for: name)
        XCTAssertEqual(SealedPrefs.get(name), "abc123secret")
        let raw = UserDefaults.standard.data(forKey: name) ?? Data()
        XCTAssertNil(raw.range(of: Data("abc123secret".utf8)))
        SealedPrefs.set(nil, for: name)
        XCTAssertNil(SealedPrefs.get(name))
    }

    func testTraktURLKeepsQuery() {
        let u = Trakt.url("/sync/history/movies?start_at=2026-01-01T00:00:00Z&limit=100&page=2")
        XCTAssertEqual(u.path, "/sync/history/movies")
        XCTAssertEqual(URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "2")
    }

    func testPosterGridCentering() {
        // 1,000 wide, 150 posters, 14 apart: 6 columns of (1000 - 70) / 6 = 155, so 2.5 either side
        XCTAssertEqual(PosterGrid.centering(width: 1000, item: 150, spacing: 14), 2.5, accuracy: 0.001)
        // Exactly fits: no extra room
        XCTAssertEqual(PosterGrid.centering(width: 150 * 4 + 14 * 3, item: 150, spacing: 14), 0, accuracy: 0.001)
        // Narrower than one poster: one column, never negative
        XCTAssertEqual(PosterGrid.centering(width: 100, item: 150, spacing: 14), 0)
    }

    /// A failed subtitle download only burns the track in when it was the whole track and nothing came before.
    func testCueStep() {
        let c = [Cue(start: 1, end: 2, text: "x")]
        XCTAssertEqual(PlayerModel.cueStep(c, piece: true, haveCues: false), .use)
        XCTAssertEqual(PlayerModel.cueStep(c, piece: false, haveCues: true), .use)
        XCTAssertEqual(PlayerModel.cueStep(nil, piece: true, haveCues: false), .askAll)
        XCTAssertEqual(PlayerModel.cueStep(nil, piece: false, haveCues: true), .keep)
        XCTAssertEqual(PlayerModel.cueStep(nil, piece: false, haveCues: false), .burnIn)
    }

    // MARK: Update swap script

    /// Runs the real swap script on dummy apps. Returns the exit status.
    private func runSwap(_ dir: URL, target: URL, new: URL) throws -> Int32 {
        let script = dir.appendingPathComponent("swap.sh")
        try Updater.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // pid 999999: no such process, so it doesn't wait. `true` instead of `open`.
        p.arguments = [script.path, "999999", target.path, new.path, work.path, "true"]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeApp(_ url: URL, _ marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cove-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testSwapSuccess() throws {
        let d = try tempDir()
        let apps = d.appendingPathComponent("Applications")
        let t = apps.appendingPathComponent("Cove.app"), n = d.appendingPathComponent("New.app")
        try makeApp(t, "old"); try makeApp(n, "new")
        try makeApp(apps.appendingPathComponent("Cove.app.old"), "stale")   // leftover from an earlier attempt
        XCTAssertEqual(try runSwap(d, target: t, new: n), 0)
        XCTAssertEqual(marker(t), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path + ".old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("work").path))
    }

    /// The app can't be moved aside (read-only folder): the original stays exactly where it was.
    func testSwapMoveAsideFails() throws {
        let d = try tempDir()
        let apps = d.appendingPathComponent("Applications")
        let t = apps.appendingPathComponent("Cove.app"), n = d.appendingPathComponent("New.app")
        try makeApp(t, "old"); try makeApp(n, "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
        XCTAssertNotEqual(try runSwap(d, target: t, new: n), 0)
        XCTAssertEqual(marker(t), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path + ".old"))
    }

    /// Copying the new app fails (it isn't there): the original is put back.
    func testSwapCopyFails() throws {
        let d = try tempDir()
        let apps = d.appendingPathComponent("Applications")
        let t = apps.appendingPathComponent("Cove.app")
        try makeApp(t, "old")
        XCTAssertNotEqual(try runSwap(d, target: t, new: d.appendingPathComponent("Missing.app")), 0)
        XCTAssertEqual(marker(t), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path + ".old"))
    }

    func testShouldShowWhatsNew() {
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: nil, current: "1.16"))       // fresh install
        XCTAssertTrue(WhatsNew.shouldShow(lastSeen: "1.15.13", current: "1.16"))
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: "1.16", current: "1.16"))
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: "1.16", current: "1.15"))    // downgrade
        XCTAssertTrue(WhatsNew.shouldShow(lastSeen: "v1.17.1", current: "v1.17.2"))
        XCTAssertTrue(WhatsNew.sameVersion("v1.16", "1.16.0"))
    }

    func testSkipVersion() {
        XCTAssertTrue(Updater.suppressed("v1.18.0", skipped: "v1.18.0", interactive: false))
        XCTAssertFalse(Updater.suppressed("v1.18.0", skipped: "v1.18.0", interactive: true))   // Check for Updates
        XCTAssertFalse(Updater.suppressed("v1.18.1", skipped: "v1.18.0", interactive: false))  // a newer one
        XCTAssertFalse(Updater.suppressed("v1.18.0", skipped: nil, interactive: false))
    }

    func testReleaseNoteLinks() {
        let u = { (s: String) in URL(string: s) }
        XCTAssertEqual(ReleaseNotes.safeLink(u("https://github.com/J0n4e/cove")), u("https://github.com/J0n4e/cove"))
        XCTAssertNil(ReleaseNotes.safeLink(u("javascript:alert(1)")))
        XCTAssertNil(ReleaseNotes.safeLink(u("file:///etc/passwd")))
        XCTAssertNil(ReleaseNotes.safeLink(u("http://example.com")))
        XCTAssertNil(ReleaseNotes.safeLink(nil))
    }

    func testRenderNotes() {
        let r = ReleaseNotes.render("## Fixes\n\n- **One** [ok](https://a.b) [bad](javascript:x)\n- `two`")
        XCTAssertTrue(r.string.contains("Fixes\n"))
        XCTAssertTrue(r.string.contains("•  One"))
        var links: [URL] = []
        r.enumerateAttribute(.link, in: NSRange(location: 0, length: r.length)) { v, _, _ in if let l = v as? URL { links.append(l) } }
        XCTAssertEqual(links, [URL(string: "https://a.b")!])
        XCTAssertEqual(ReleaseNotes.render("  ").string, "No release notes.")
    }

    // MARK: Playback state

    func testPlaybackInfoStatus() {
        XCTAssertEqual(Emby.playbackInfoStatus(200), .ok)
        XCTAssertEqual(Emby.playbackInfoStatus(204), .ok)
        XCTAssertEqual(Emby.playbackInfoStatus(nil), .ok)
        XCTAssertEqual(Emby.playbackInfoStatus(401), .sessionEnded)
        XCTAssertEqual(Emby.playbackInfoStatus(500), .serverError(500))
        XCTAssertEqual(Emby.playbackInfoStatus(404), .serverError(404))
    }

    func testEffectiveStart() {
        XCTAssertEqual(PlayerModel.effectiveStart(keep: 120, requestStart: 30), 120)   // restart keeps its position
        XCTAssertEqual(PlayerModel.effectiveStart(keep: nil, requestStart: 30), 30)    // new film: its own resume point
        XCTAssertEqual(PlayerModel.effectiveStart(keep: 0, requestStart: 30), 30)
        XCTAssertEqual(PlayerModel.effectiveStart(keep: nil, requestStart: nil), 0)
        XCTAssertEqual(PlayerModel.effectiveStart(keep: nil, requestStart: -1), 0)
    }

    // MARK: Trakt renewal

    func testSingleFlightRunsOnceForConcurrentCallers() async throws {
        let flight = SingleFlight<Int>()
        var runs = 0
        let op: @MainActor () async throws -> Int = {
            runs += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return 42
        }
        let results = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { g in
            for _ in 0..<8 { g.addTask { @MainActor in try await flight.run(op) } }
            var all: [Int] = []
            for try await v in g { all.append(v) }
            return all
        }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(results, Array(repeating: 42, count: 8))
        XCTAssertFalse(flight.isRunning)
        _ = try await flight.run(op)            // a later call starts a new one
        XCTAssertEqual(runs, 2)
    }

    func testSingleFlightSharesErrors() async {
        struct Boom: Error {}
        let flight = SingleFlight<Void>()
        var runs = 0
        let op: @MainActor () async throws -> Void = { runs += 1; try await Task.sleep(nanoseconds: 20_000_000); throw Boom() }
        let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { g in
            for _ in 0..<3 { g.addTask { @MainActor in do { try await flight.run(op); return false } catch { return error is Boom } } }
            var n = 0
            for await failed in g where failed { n += 1 }
            return n
        }
        XCTAssertEqual(failures, 3)
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(flight.isRunning)
    }

    func testTraktSignsOutOnlyWhenRenewalIsRefused() {
        XCTAssertTrue(Trakt.shouldSignOut(renewStatus: 400))
        XCTAssertTrue(Trakt.shouldSignOut(renewStatus: 401))
        XCTAssertFalse(Trakt.shouldSignOut(renewStatus: nil))     // network error
        for s in [0, 403, 429, 500, 502, 503] { XCTAssertFalse(Trakt.shouldSignOut(renewStatus: s)) }
    }

    // MARK: Updater downgrade

    func testValidReleaseTag() {
        for ok in ["v1.17.2", "v1.0", "v2.0.0.1"] { XCTAssertTrue(Updater.isValidReleaseTag(ok), ok) }
        for bad in ["V1.17.2", "1.17.2", "99", "v99", "v1.17.2-beta", "v1..2", "", "v1.2.3.4.5", " v1.2", "v1.2\n"] {
            XCTAssertFalse(Updater.isValidReleaseTag(bad), bad)
        }
    }

    func testVerifyBundle() {
        let id = "eu.jonae.cove"
        func info(_ i: String, _ v: String) -> [String: Any] { ["CFBundleIdentifier": i, "CoveVersion": v] }
        XCTAssertNil(Updater.verifyBundle(info: info(id, "v1.17.3"), expectedId: id, tag: "v1.17.3", current: "v1.17.2"))
        // Wrong bundle id
        XCTAssertNotNil(Updater.verifyBundle(info: info("com.evil.app", "v1.17.3"), expectedId: id, tag: "v1.17.3", current: "v1.17.2"))
        XCTAssertNotNil(Updater.verifyBundle(info: info(id, "v1.17.3"), expectedId: nil, tag: "v1.17.3", current: "v1.17.2"))
        // Version doesn't match the tag (old signed zip republished under a new tag)
        XCTAssertNotNil(Updater.verifyBundle(info: info(id, "v1.10.0"), expectedId: id, tag: "v1.17.3", current: "v1.17.2"))
        XCTAssertNotNil(Updater.verifyBundle(info: ["CFBundleIdentifier": id], expectedId: id, tag: "v1.17.3", current: "v1.17.2"))
        // Not newer than the running version
        XCTAssertNotNil(Updater.verifyBundle(info: info(id, "v1.17.2"), expectedId: id, tag: "v1.17.2", current: "v1.17.2"))
        XCTAssertNotNil(Updater.verifyBundle(info: info(id, "v1.16.0"), expectedId: id, tag: "v1.16.0", current: "v1.17.2"))
        // Invalid tag
        XCTAssertNotNil(Updater.verifyBundle(info: info(id, "V99"), expectedId: id, tag: "V99", current: "v1.17.2"))
        let e = Updater.verifyBundle(info: info(id, "v1.0"), expectedId: id, tag: "v1.17.3", current: "v1.17.2") as? Updater.Err
        XCTAssertEqual(e?.msg, Updater.mismatchMessage)
    }

    // MARK: Update location message

    func testCantReplaceMessage() {
        let tr = Updater.cantReplaceMessage(appPath: "/private/var/folders/d9/x/T/AppTranslocation/0FDF3AAA/d/Cove.app")
        XCTAssertTrue(tr.contains("Applications folder"))
        XCTAssertFalse(tr.contains("/private/var"))          // no random hidden path
        let ro = Updater.cantReplaceMessage(appPath: "/Volumes/Disk/Cove.app")
        XCTAssertTrue(ro.contains("/Volumes/Disk"))
        XCTAssertTrue(ro.contains("Applications folder"))
    }

    // MARK: Playback fallback

    func testPlaybackFailureAction() {
        // First player failure (e.g. CoreMedia -12927 on direct play): convert and continue
        XCTAssertEqual(PlayerModel.failureAction(.player, alreadyConverted: false), .retryConverted)
        // The converted stream failed too: show the error (no loop)
        XCTAssertEqual(PlayerModel.failureAction(.player, alreadyConverted: true), .showError)
        // PlaybackInfo 401 / server error / no stream: show the error, never retry
        XCTAssertEqual(PlayerModel.failureAction(.streamRequest, alreadyConverted: false), .showError)
        XCTAssertEqual(PlayerModel.failureAction(.streamRequest, alreadyConverted: true), .showError)
    }

    // MARK: Subtitle cache

    private func subtitleCache() throws -> SubtitleCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return SubtitleCache(dir: dir)
    }

    private func put(_ c: SubtitleCache, _ key: String, bytes: Int, age: TimeInterval = 0) throws -> URL {
        let f = c.file(key)
        try Data(repeating: 65, count: bytes).write(to: f)
        let d = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: f.path)
        var v = URLResourceValues(); v.contentAccessDate = d
        var u = f; try? u.setResourceValues(v)
        return f
    }

    func testSubtitleCacheTotalAndClear() throws {
        let c = try subtitleCache()
        _ = try put(c, "http://a|1|s|0", bytes: 1000)
        _ = try put(c, "http://a|2|s|0", bytes: 3000)
        XCTAssertGreaterThanOrEqual(c.totalBytes(), 4000)
        c.clear()
        XCTAssertEqual(c.totalBytes(), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: c.dir.path).isEmpty)
    }

    func testSubtitleCachePrune() throws {
        let c = try subtitleCache()
        let old = try put(c, "http://a|old|s|0", bytes: 100, age: 100 * 86400)
        let oldest = try put(c, "http://a|1|s|0", bytes: 50_000, age: 3000)
        let newer = try put(c, "http://a|2|s|0", bytes: 50_000, age: 1000)
        c.prune(maxBytes: 80_000, maxAge: 90 * 86400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
    }

    func testSubtitleCacheRemoveServer() throws {
        let c = try subtitleCache()
        let a = try put(c, "http://a:8096|1|s|0", bytes: 10)
        let b = try put(c, "http://b:8096|1|s|0", bytes: 10)
        XCTAssertEqual(SubtitleCache.key(ofFile: a.lastPathComponent), "http://a:8096|1|s|0")
        try Data().write(to: c.dir.appendingPathComponent("not-base64!.srt"))
        c.removeServer("http://a:8096")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    // MARK: Token storage

    private func isolatedDefaults() -> UserDefaults {
        let name = "cove.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testSealedTokenStoreRoundTrip() {
        let d = isolatedDefaults()
        let list = [SavedServer(url: "https://A.example", name: "A", user: "u", token: "tokA", userId: "1"),
                    SavedServer(url: "http://b.local:8096", name: "B", user: "v", token: "tokB", userId: "2")]
        XCTAssertTrue(ServerStore.save(list, to: d))
        XCTAssertEqual(ServerStore.sealedTokens(d), ["https://a.example": "tokA", "http://b.local:8096": "tokB"])
        let raw = String(decoding: d.data(forKey: "servers")!, as: UTF8.self)
        XCTAssertFalse(raw.contains("tokA")); XCTAssertFalse(raw.contains("tokB")); XCTAssertFalse(raw.contains("\"token\""))
        XCTAssertFalse(String(decoding: d.data(forKey: "serverTokens")!, as: UTF8.self).contains("tokA"))
        XCTAssertEqual(ServerStore.load(from: d, server: "https://a.example", userId: "1"), list)
        XCTAssertEqual(SealedPrefs.get("serverTokens", in: isolatedDefaults()), nil)
    }

    func testPlaintextTokensMigrate() throws {
        let d = isolatedDefaults()
        let old = [SavedServer(url: "https://a.example", name: "A", user: "u", token: "tokA", userId: "1"),
                   SavedServer(url: "https://b.example", name: "B", user: "v", token: nil, userId: "2")]
        d.set(try JSONEncoder().encode(old), forKey: "servers")
        d.set("tokB", forKey: "token")              // legacy key for the current server
        let list = ServerStore.load(from: d, server: "https://b.example", userId: "2")
        XCTAssertEqual(list.map(\.token), ["tokA", "tokB"])
        XCTAssertNil(d.object(forKey: "token"))
        let raw = String(decoding: d.data(forKey: "servers")!, as: UTF8.self)
        XCTAssertFalse(raw.contains("tokA")); XCTAssertFalse(raw.contains("tokB"))
        XCTAssertEqual(ServerStore.sealedTokens(d), ["https://a.example": "tokA", "https://b.example": "tokB"])
        // Second launch reads the sealed copy
        XCTAssertEqual(ServerStore.load(from: d, server: "https://b.example", userId: "2").map(\.token), ["tokA", "tokB"])
        // Signing out of every server removes the sealed store
        XCTAssertTrue(ServerStore.save(list.map { var x = $0; x.token = nil; return x }, to: d))
        XCTAssertNil(d.object(forKey: "serverTokens"))
    }

    func testLegacyTokenOnlyMigrates() {
        let d = isolatedDefaults()
        d.set("tokL", forKey: "token")
        let list = ServerStore.load(from: d, server: "https://old.example", userId: "9")
        XCTAssertEqual(list.first?.token, "tokL")
        XCTAssertNil(d.object(forKey: "token"))
        XCTAssertEqual(ServerStore.sealedTokens(d), ["https://old.example": "tokL"])
    }
}
