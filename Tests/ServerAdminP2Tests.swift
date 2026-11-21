import XCTest
@testable import Cove

/// Server management phase 2 (Users, Libraries) and English server texts.
final class ServerAdminP2Tests: XCTestCase {
    private func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
    private func query(_ path: String) -> [String: String] {
        var out: [String: String] = [:]
        for q in URLComponents(string: "http://x" + path)?.queryItems ?? [] { out[q.name] = q.value }
        return out
    }

    // MARK: English

    func testLanguageHeaders() {
        UserDefaults.standard.removeObject(forKey: "serverLanguage")
        XCTAssertEqual(Net.acceptLanguage, "en-US,en;q=0.9")
        XCTAssertEqual(Net.englishHeaders["X-Emby-Language"], "en-us")
        var r = URLRequest(url: URL(string: "http://x/ScheduledTasks")!)
        Net.setLanguage(&r)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept-Language"), "en-US,en;q=0.9")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Emby-Language"), "en-us")
        XCTAssertEqual(Net.session.configuration.httpAdditionalHeaders?["Accept-Language"] as? String, "en-US,en;q=0.9")
    }

    func testLanguageOverride() {
        UserDefaults.standard.set("de-DE", forKey: "serverLanguage")
        defer { UserDefaults.standard.removeObject(forKey: "serverLanguage") }
        XCTAssertEqual(Net.acceptLanguage, "de-DE,de;q=0.9")
    }

    @MainActor func testAuthorizeAddsLanguage() {
        var r = URLRequest(url: URL(string: "http://x/Users")!)
        Emby().authorize(&r, token: "t")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept-Language"), Net.acceptLanguage)
    }

    func testRemoteImagesLanguageAndSort() {
        let q = query(ItemAdminAPI.remoteImages(itemId: "a", type: "Primary").path)
        XCTAssertEqual(q["IncludeAllLanguages"], "false")
        XCTAssertEqual(q["Language"], "en")
        func img(_ u: String, _ l: String?) -> ItemAdminAPI.RemoteImage {
            .init(url: u, thumbnailURL: nil, provider: nil, width: nil, height: nil, language: l, rating: nil, votes: nil)
        }
        let s = ItemAdminAPI.sortImages([img("de", "de"), img("none", nil), img("en1", "en"), img("ro", "ro"), img("en2", "EN-us")])
        XCTAssertEqual(s.map(\.url), ["en1", "en2", "none", "de", "ro"])
    }

    func testRemoteSearchLanguage() {
        let b = json(ItemAdminAPI.remoteSearch(itemId: "i", type: "Movie", name: "X", year: nil, providerIds: [:])?.body)
        let info = b["SearchInfo"] as? [String: Any] ?? [:]
        XCTAssertEqual(info["MetadataLanguage"] as? String, "en")
        XCTAssertEqual(info["MetadataCountryCode"] as? String, "US")
        let b2 = json(ItemAdminAPI.remoteSearch(itemId: "i", type: "Movie", name: "X", year: nil, providerIds: [:],
                                                metadataLanguage: "fr", countryCode: "FR")?.body)
        XCTAssertEqual((b2["SearchInfo"] as? [String: Any])?["MetadataLanguage"] as? String, "fr")
    }

    func testLibraryLanguageFromAncestors() {
        let folders = Data(#"[{"Name":"Filme","ItemId":"ABC-1","LibraryOptions":{"PreferredMetadataLanguage":"de","MetadataCountryCode":"DE"}},{"Name":"TV","ItemId":"x"}]"#.utf8)
        let anc = Data(#"[{"Id":"abc1"},{"Id":"root"}]"#.utf8)
        let r = ItemAdminAPI.libraryLanguage(folders: folders, ancestors: anc)
        XCTAssertEqual(r?.language, "de"); XCTAssertEqual(r?.country, "DE")
        XCTAssertNil(ItemAdminAPI.libraryLanguage(folders: folders, ancestors: Data(#"[{"Id":"zzz"}]"#.utf8)))
    }

    // MARK: Users

    static let jellyfinUsers = #"""
    [{"Name":"bob","Id":"b1","HasPassword":true,"HasConfiguredPassword":true,"LastActivityDate":"2026-11-20T10:00:00.1234567Z",
      "PrimaryImageTag":"t","Policy":{"IsAdministrator":false,"IsDisabled":true,"IsHidden":false,"SyncPlayAccess":"JoinGroups","AuthenticationProviderId":"p"}},
     {"Name":"Alice","Id":"a1","HasPassword":false,"Policy":{"IsAdministrator":true}}]
    """#
    static let embyUsers = #"""
    [{"Name":"Me","Id":"m1","HasPassword":true,"HasConfiguredPassword":true,"LastLoginDate":"2026-11-19T10:00:00Z","Policy":{"IsAdministrator":true,"IsHidden":true}}]
    """#

    func testUserListJellyfin() {
        let u = AdminUser.decodeList(Data(Self.jellyfinUsers.utf8))!
        XCTAssertEqual(u.map(\.name), ["Alice", "bob"])
        XCTAssertTrue(u[0].isAdmin); XCTAssertFalse(u[0].hasPassword)
        XCTAssertTrue(u[1].isDisabled); XCTAssertTrue(u[1].hasPassword); XCTAssertNotNil(u[1].lastActivity)
        XCTAssertEqual(u[1].imageTag, "t")
        XCTAssertEqual(u[0].activityLine(), "Never signed in")
    }

    func testUserListEmby() {
        let u = AdminUser.decodeList(Data(Self.embyUsers.utf8))!
        XCTAssertEqual(u.count, 1); XCTAssertTrue(u[0].isHidden); XCTAssertNotNil(u[0].lastLogin)
        XCTAssertEqual(AdminUser.initials("Jon Snow"), "JS")
    }

    func testPolicyKeepsUnknownFields() {
        let original: [String: Any] = ["IsAdministrator": false, "EnableRemoteAccess": true, "AuthenticationProviderId": "X",
                                       "BlockedTags": ["a"], "EnabledFolders": ["f1"], "SyncPlayAccess": "JoinGroups", "FutureField": 7]
        var e = UserPolicyEdit.from(original)
        XCTAssertEqual(e.syncPlayAccess, "JoinGroups"); XCTAssertEqual(e.enabledFolders, ["f1"])
        e.enableRemoteAccess = false
        e.enableAllFolders = false; e.enabledFolders = ["f2"]
        e.maxParentalRating = 13
        e.syncPlayAccess = "None"
        let p = e.apply(to: original)
        XCTAssertEqual(p["AuthenticationProviderId"] as? String, "X")
        XCTAssertEqual(p["BlockedTags"] as? [String], ["a"])
        XCTAssertEqual(p["FutureField"] as? Int, 7)
        XCTAssertEqual(p["EnableRemoteAccess"] as? Bool, false)
        XCTAssertEqual(p["EnabledFolders"] as? [String], ["f2"])
        XCTAssertEqual(p["MaxParentalRating"] as? Int, 13)
        XCTAssertEqual(p["SyncPlayAccess"] as? String, "None")
        let body = json(UserAdminAPI.policy(userId: "u", p).body)
        XCTAssertEqual(body["FutureField"] as? Int, 7)
        // Emby has no SyncPlayAccess: never added
        var emby = UserPolicyEdit.from(["IsAdministrator": true]); emby.syncPlayAccess = "None"
        XCTAssertNil(emby.apply(to: ["IsAdministrator": true])["SyncPlayAccess"])
    }

    func testPolicySummary() {
        let old = UserPolicyEdit()
        var e = old; e.isAdministrator = true; e.enableAllFolders = false; e.enabledFolders = ["a", "b"]
        XCTAssertEqual(e.changes(from: old), ["Administrator: on", "Libraries: 2 selected"])
        XCTAssertEqual(old.changes(from: old), [])
    }

    func testPasswordRequests() {
        let r = UserAdminAPI.password(userId: "u1", new: "s3cret")
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/Users/u1/Password")
        let b = json(r.body)
        XCTAssertEqual(b["NewPw"] as? String, "s3cret"); XCTAssertEqual(b["ResetPassword"] as? Bool, false)
        XCTAssertEqual(b["CurrentPw"] as? String, "")
        XCTAssertEqual(json(UserAdminAPI.password(userId: "u1", new: "n", current: "o").body)["CurrentPw"] as? String, "o")
        let reset = json(UserAdminAPI.resetPassword(userId: "u1").body)
        XCTAssertEqual(reset["ResetPassword"] as? Bool, true); XCTAssertNil(reset["NewPw"])
    }

    func testCreateUserPerServer() {
        XCTAssertEqual(json(UserAdminAPI.create(name: " Ann ", password: "p", kind: .jellyfin).body)["Password"] as? String, "p")
        let e = json(UserAdminAPI.create(name: "Ann", password: "p", kind: .emby).body)
        XCTAssertEqual(e["Name"] as? String, "Ann"); XCTAssertNil(e["Password"])
        XCTAssertTrue(UserAdminAPI.createNeedsPasswordStep(.emby, password: "p"))
        XCTAssertFalse(UserAdminAPI.createNeedsPasswordStep(.jellyfin, password: "p"))
        XCTAssertEqual(UserAdminAPI.create(name: "A", password: "", kind: .emby).path, "/Users/New")
    }

    func testRenameKeepsRecord() {
        let u = AdminUser.decodeList(Data(Self.jellyfinUsers.utf8))![1]
        let b = json(UserAdminAPI.rename(u, to: "Robert").body)
        XCTAssertEqual(b["Name"] as? String, "Robert")
        XCTAssertEqual(b["Id"] as? String, "b1")
        XCTAssertNotNil(b["Policy"])
    }

    func testSelfProtection() {
        let users = AdminUser.decodeList(Data(#"[{"Id":"me","Name":"Me","Policy":{"IsAdministrator":true}},{"Id":"o","Name":"O","Policy":{"IsAdministrator":true}},{"Id":"u","Name":"U","Policy":{}}]"#.utf8))!
        let me = users.first { $0.id == "me" }!, other = users.first { $0.id == "o" }!, plain = users.first { $0.id == "u" }!
        XCTAssertFalse(UserAdminRules.canDelete(me, me: "me"))
        XCTAssertTrue(UserAdminRules.canDelete(other, me: "me"))
        var e = UserPolicyEdit.from(me.policy); e.isAdministrator = false
        XCTAssertNotNil(UserAdminRules.validate(e, user: me, me: "me", users: users))
        e = UserPolicyEdit.from(me.policy); e.isDisabled = true
        XCTAssertNotNil(UserAdminRules.validate(e, user: me, me: "me", users: users))
        e = UserPolicyEdit.from(other.policy); e.isAdministrator = false
        XCTAssertNil(UserAdminRules.validate(e, user: other, me: "me", users: users))
        // last admin
        let two = users.filter { $0.id != "o" }
        var p = UserPolicyEdit.from(plain.policy); p.isAdministrator = true
        XCTAssertNil(UserAdminRules.validate(p, user: plain, me: "me", users: two))
        XCTAssertTrue(UserAdminRules.deleteConfirmed("O", user: other))
        XCTAssertFalse(UserAdminRules.deleteConfirmed("o", user: other))
        XCTAssertFalse(UserAdminRules.deleteConfirmed("", user: other))
    }

    func testRatingsAndFolders() {
        let r = UserAdminAPI.decodeRatings(Data(#"[{"Name":"PG","Value":5},{"Name":"G","Value":1},{"Name":"TV-PG","Value":5}]"#.utf8))
        XCTAssertEqual(r.map(\.value), [1, 5]); XCTAssertEqual(r[1].name, "PG / TV-PG")
        let f = UserAdminAPI.decodeFolders(Data(#"{"Items":[{"Id":"f1","Name":"Movies"}]}"#.utf8))
        XCTAssertEqual(f.first?.name, "Movies")
        XCTAssertTrue(UserAdminAPI.sameId("ABCD-ef", "abcdef"))
    }

    // MARK: Libraries

    func testVirtualFolders() {
        let d = Data(#"""
        [{"Name":"Movies","CollectionType":"movies","ItemId":"m","Locations":["/mnt/m"],"RefreshStatus":"Idle","LibraryOptions":{"PreferredMetadataLanguage":"en"}},
         {"Name":"Mixed","ItemId":"x","Locations":[],"LibraryOptions":{"PathInfos":[{"Path":"D:\\Media"}]},"RefreshStatus":"Active","RefreshProgress":40}]
        """#.utf8)
        let l = AdminLibrary.decodeList(d)!
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0].typeTitle, "Movies"); XCTAssertEqual(l[0].paths, ["/mnt/m"]); XCTAssertEqual(l[0].metadataLanguage, "en")
        XCTAssertNil(l[1].collectionType); XCTAssertEqual(l[1].typeTitle, "Mixed")
        XCTAssertEqual(l[1].paths, ["D:\\Media"]); XCTAssertTrue(l[1].refreshing)
        XCTAssertTrue(LibraryAdminAPI.offersMissing(l[0]))
        XCTAssertEqual(LibraryAdminAPI.item(l[0])?.id, "m")
    }

    func testLibraryRequests() {
        let lib = AdminLibrary.decodeList(Data(#"[{"Name":"My Films & Co","CollectionType":"movies","ItemId":"m","Locations":["/a b"]}]"#.utf8))![0]
        let scan = query(LibraryAdminAPI.scan(lib).path)
        XCTAssertTrue(LibraryAdminAPI.scan(lib).path.hasPrefix("/Items/m/Refresh?"))
        XCTAssertEqual(scan["Recursive"], "true"); XCTAssertEqual(scan["MetadataRefreshMode"], "Default")
        let add = LibraryAdminAPI.addPath(library: lib.name, path: " /new ")
        XCTAssertEqual(add.method, "POST")
        XCTAssertEqual((json(add.body)["PathInfo"] as? [String: Any])?["Path"] as? String, "/new")
        XCTAssertEqual(json(add.body)["Name"] as? String, "My Films & Co")
        let rm = LibraryAdminAPI.removePath(library: lib.name, path: "/a b")
        XCTAssertEqual(rm.method, "DELETE"); XCTAssertEqual(query(rm.path)["name"], "My Films & Co"); XCTAssertEqual(query(rm.path)["path"], "/a b")
        let rn = query(LibraryAdminAPI.rename(lib.name, to: "Films").path)
        XCTAssertEqual(rn["name"], "My Films & Co"); XCTAssertEqual(rn["newName"], "Films")
        XCTAssertEqual(query(LibraryAdminAPI.delete("X").path)["name"], "X")
        XCTAssertEqual(LibraryAdminAPI.delete("X").method, "DELETE")
        XCTAssertEqual(query(LibraryAdminAPI.count(userId: "u", libraryId: "m", type: "movies").path)["IncludeItemTypes"], "Movie")
        XCTAssertEqual(LibraryAdminAPI.decodeCount(Data(#"{"Items":[],"TotalRecordCount":42}"#.utf8)), 42)
    }

    func testAddLibraryPerServer() {
        for kind in [ServerAdminKind.emby, .jellyfin] {
            let r = LibraryAdminAPI.addLibrary(name: "Kids", type: "tvshows", path: "/tv", kind: kind)
            let q = query(r.path)
            XCTAssertTrue(r.path.hasPrefix("/Library/VirtualFolders?"))
            XCTAssertEqual(q["collectionType"], "tvshows"); XCTAssertEqual(q["refreshLibrary"], "true"); XCTAssertEqual(q["paths"], "/tv")
            let o = json(r.body)["LibraryOptions"] as? [String: Any] ?? [:]
            XCTAssertEqual(o["PreferredMetadataLanguage"] as? String, "en")
            XCTAssertEqual(o["MetadataCountryCode"] as? String, "US")
        }
        XCTAssertNil(query(LibraryAdminAPI.addLibrary(name: "M", type: nil, path: "/m", kind: .emby).path)["collectionType"])
        XCTAssertFalse(LibraryAdminAPI.validName("a/b")); XCTAssertTrue(LibraryAdminAPI.validName("Films"))
    }

    // MARK: Model with a fake server

    @MainActor func testSaveSendsOnlyChangedPolicyAndBlocksSelfLockout() async {
        var sent: [(String, String, Data?)] = []
        let users = #"[{"Id":"me","Name":"Me","Policy":{"IsAdministrator":true,"X":1}},{"Id":"o","Name":"O","Policy":{"IsAdministrator":false,"X":2}}]"#
        let api = ServerAdminAPI(call: { _, _ in (nil, 0) }, userId: "me", send: { m, p, b in
            sent.append((m, p, b))
            if p == "/Users" { return (Data(users.utf8), 200) }
            if p == "/Users/o" { return (Data(#"{"Id":"o","Name":"O","Policy":{"IsAdministrator":false,"X":2}}"#.utf8), 200) }
            if p.hasPrefix("/Users/o/") { return (nil, 204) }
            return (nil, 404)
        })
        let m = ServerUsersModel(kind: .jellyfin, api: api)
        await m.load()
        XCTAssertEqual(m.users.count, 2)
        let o = m.users.first { $0.id == "o" }!
        let orig = UserPolicyEdit.from(o.policy)
        var e = orig; e.enableDownloads = false
        sent = []
        let r = await m.save(user: o, name: "O", edit: e, original: orig, newPassword: "pw", currentPassword: "", resetPassword: false)
        XCTAssertNil(r.error)
        XCTAssertTrue(r.done.contains("Password changed"))
        let pol = sent.first { $0.1 == "/Users/o/Policy" }
        XCTAssertEqual(json(pol?.2)["X"] as? Int, 2)
        XCTAssertEqual(json(pol?.2)["EnableContentDownloading"] as? Bool, false)
        XCTAssertNil(sent.first { $0.1 == "/Users/o" && $0.0 == "POST" })   // name unchanged: no rename
        let meU = m.users.first { $0.id == "me" }!
        var bad = UserPolicyEdit.from(meU.policy); bad.isAdministrator = false
        let r2 = await m.save(user: meU, name: "Me", edit: bad, original: UserPolicyEdit.from(meU.policy), newPassword: "", currentPassword: "", resetPassword: false)
        XCTAssertNotNil(r2.error)
        let d = await m.delete(meU)
        XCTAssertNotNil(d)
    }
}
