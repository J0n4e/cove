import XCTest
import AppKit
@testable import Cove

/// Glass3D profile circle + menu: initials, menu content from state, picture request shapes, messages, multi-user keys.
@MainActor
final class ProfileMenuTests: XCTestCase {
    func testInitials() {
        XCTAssertEqual(ProfileInitials.of("Jonas Example"), "JE")
        XCTAssertEqual(ProfileInitials.of("jonas"), "J")
        XCTAssertEqual(ProfileInitials.of("anna.maria_lee"), "AM")
        XCTAssertEqual(ProfileInitials.of(""), "?")
        XCTAssertEqual(ProfileInitials.of("  "), "?")
        XCTAssertEqual(ProfileInitials.tooltip(user: "Jonas", server: "Home"), "Jonas on Home")
    }

    func input(admin: Bool?, picture: Bool = false, unread: Int = 0) -> ProfileMenuInput {
        ProfileMenuInput(name: "Jonas", jellyfin: false, admin: admin, hasPicture: picture,
                         servers: [.init(id: "http://a:8096", name: "A"), .init(id: "http://b:8096", name: "B")],
                         currentServer: "http://A:8096", online: ["http://a:8096": true],
                         otherUsers: [.init(key: "http://a:8096|u2", name: "Kid")], unread: unread)
    }

    func testSectionsInOrder() {
        let s = ProfileMenuSpec.sections(input(admin: true))
        XCTAssertEqual(s.map { $0.0 }, [.you, .servers, .users, .shortcuts, .app, .signOut])
        XCTAssertEqual(s.last?.1, [.signOut])
        XCTAssertEqual(ProfileMenuSpec.sections(input(admin: true), shown: [.you, .signOut]).map { $0.0 }, [.you, .signOut])
    }

    func testSubtitleAdminAndUser() {
        XCTAssertEqual(ProfileMenuSpec.subtitle(jellyfin: false, admin: true), "Emby · Admin")
        XCTAssertEqual(ProfileMenuSpec.subtitle(jellyfin: true, admin: false), "Jellyfin · User")
        XCTAssertEqual(ProfileMenuSpec.subtitle(jellyfin: true, admin: nil), "Jellyfin")
    }

    func testRemovePictureOnlyWithPicture() {
        XCTAssertEqual(ProfileMenuSpec.rows(.you, input(admin: false)), [.changePicture])
        XCTAssertEqual(ProfileMenuSpec.rows(.you, input(admin: false, picture: true)), [.changePicture, .removePicture])
    }

    func testServersCurrentCheckAndOnline() {
        let r = ProfileMenuSpec.rows(.servers, input(admin: true))
        XCTAssertEqual(r, [.server(id: "http://a:8096", name: "A", current: true, online: true),
                           .server(id: "http://b:8096", name: "B", current: false, online: nil),
                           .addServer])
    }

    func testUsersAndShortcutsAndUnread() {
        XCTAssertEqual(ProfileMenuSpec.rows(.users, input(admin: true)), [.switchUser, .otherUser(key: "http://a:8096|u2", name: "Kid")])
        XCTAssertEqual(ProfileMenuSpec.rows(.shortcuts, input(admin: false, unread: 3)), [.search, .myActivity, .favorites, .notifications(unread: 3)])
        XCTAssertEqual(ProfileMenuSpec.title(.notifications(unread: 3)), "Notifications (3)")
        XCTAssertEqual(ProfileMenuSpec.title(.notifications(unread: 0)), "Notifications")
        XCTAssertEqual(ProfileMenuSpec.rows(.app, input(admin: nil)), [.settings, .checkUpdates, .about, .help])
    }

    func testEmbyUploadShape() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let s = ProfileImageAPI.upload(userId: "abc", jpeg: jpeg, jellyfin: false, version: "4.8.0.0")
        XCTAssertEqual(s.method, "POST")
        XCTAssertEqual(s.path, "/Users/abc/Images/Primary")
        XCTAssertEqual(s.contentType, "image/jpeg")
        XCTAssertEqual(s.body, Data(jpeg.base64EncodedString().utf8))
        XCTAssertEqual(ProfileImageAPI.remove(userId: "abc", jellyfin: false, version: nil).path, "/Users/abc/Images/Primary")
        XCTAssertEqual(ProfileImageAPI.remove(userId: "abc", jellyfin: false, version: nil).method, "DELETE")
    }

    func testJellyfinUploadShapePerVersion() {
        let jpeg = Data([1, 2, 3])
        let new = ProfileImageAPI.upload(userId: "u1", jpeg: jpeg, jellyfin: true, version: "10.10.7")
        XCTAssertEqual(new.path, "/UserImage?userId=u1")
        XCTAssertEqual(new.body, Data(jpeg.base64EncodedString().utf8))   // Jellyfin reads base64 on every version
        XCTAssertEqual(new.contentType, "image/jpeg")
        XCTAssertEqual(ProfileImageAPI.upload(userId: "u1", jpeg: jpeg, jellyfin: true, version: "10.8.13").path, "/Users/u1/Images/Primary")
        XCTAssertEqual(ProfileImageAPI.upload(userId: "u1", jpeg: jpeg, jellyfin: true, version: nil).path, "/UserImage?userId=u1")
        XCTAssertEqual(ProfileImageAPI.remove(userId: "u1", jellyfin: true, version: "10.9.0").path, "/UserImage?userId=u1")
        XCTAssertTrue(ProfileImageAPI.jellyfinHasUserImage("11.0.0"))
        XCTAssertFalse(ProfileImageAPI.jellyfinHasUserImage("10.8.99"))
    }

    func testMessages() {
        XCTAssertNil(ProfileImageAPI.message(status: 204, server: "Home"))
        XCTAssertEqual(ProfileImageAPI.message(status: 403, server: "Home"), "The server doesn't allow you to change your picture.")
        XCTAssertTrue(ProfileImageAPI.message(status: 500, server: "Home")!.contains("Home"))
    }

    func testMultiUserTokenKeys() {
        XCTAssertEqual(ProfileUserStore.entryKey(server: "HTTP://Nas:8096", userId: "u1"), "http://nas:8096|u1")
        let p = ProfileUserStore.split("http://nas:8096|u1")
        XCTAssertEqual(p?.server, "http://nas:8096"); XCTAssertEqual(p?.userId, "u1")
        let all: [String: ProfileUserStore.Entry] = [
            "http://nas:8096|u1": .init(user: "Me", token: "t1"),
            "http://nas:8096|u2": .init(user: "Kid", token: "t2"),
            "http://other|u3": .init(user: "Else", token: "t3")]
        let o = ProfileUserStore.others(all, server: "http://NAS:8096", currentUserId: "u1")
        XCTAssertEqual(o.map { $0.userId }, ["u2"])
        XCTAssertEqual(o.first?.entry.user, "Kid")
    }

    func testStoreRoundTripSealed() {
        let d = UserDefaults(suiteName: "ProfileMenuTests-\(UUID().uuidString)")!
        ProfileUserStore.remember(server: "http://a", userId: "u1", user: "Me", token: "t1", d)
        ProfileUserStore.remember(server: "http://a", userId: "u2", user: "Kid", token: "t2", d)
        XCTAssertEqual(ProfileUserStore.all(d).count, 2)
        XCTAssertNil(String(data: d.data(forKey: ProfileUserStore.key) ?? Data(), encoding: .utf8).flatMap { $0.contains("t1") ? $0 : nil })
        ProfileUserStore.forget(server: "http://a", userId: "u1", d)
        XCTAssertEqual(ProfileUserStore.all(d).keys.sorted(), ["http://a|u2"])
        ProfileUserStore.prune(keeping: [], d)
        XCTAssertTrue(ProfileUserStore.all(d).isEmpty)
    }

    func testCropRect() {
        // 1000x500 landscape in a 250 viewport at zoom 1: the centred 500x500 square
        let r = ProfileCrop.rect(image: CGSize(width: 1000, height: 500), viewport: 250, zoom: 1, offset: .zero)
        XCTAssertEqual(r, CGRect(x: 250, y: 0, width: 500, height: 500))
        // dragged far right: clamped to the left edge
        let l = ProfileCrop.rect(image: CGSize(width: 1000, height: 500), viewport: 250, zoom: 1, offset: CGSize(width: 9999, height: 0))
        XCTAssertEqual(l.origin.x, 0)
        // zoom 2: a quarter-area square
        XCTAssertEqual(ProfileCrop.rect(image: CGSize(width: 500, height: 500), viewport: 250, zoom: 2, offset: .zero).width, 250)
    }

    func testJpegOutputIs512() {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let data = ProfileCrop.jpeg(ctx.makeImage()!, crop: CGRect(x: 100, y: 0, width: 600, height: 600))
        let rep = data.flatMap { NSBitmapImageRep(data: $0) }
        XCTAssertEqual(rep?.pixelsWide, 512); XCTAssertEqual(rep?.pixelsHigh, 512)
        XCTAssertEqual(data?.prefix(2), Data([0xFF, 0xD8]))
    }
}
