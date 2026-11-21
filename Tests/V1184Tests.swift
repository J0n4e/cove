import XCTest
@testable import Cove

/// v1.18.4 (Glass3D): poster badges as buttons, the rating at the end of the detail row, Now Playing redesign.
final class V1184Tests: XCTestCase {
    // MARK: Poster badges

    func testBadgeTooltips() {
        XCTAssertEqual(PosterBadges.favTip(false), "Add to Favorites")
        XCTAssertEqual(PosterBadges.favTip(true), "Remove from Favorites")
        XCTAssertEqual(PosterBadges.watchedTip(false), "Mark as watched")
        XCTAssertEqual(PosterBadges.watchedTip(true), "Mark as unwatched")
    }

    func testFavBadgeAlwaysShownNoHoverChange() {
        XCTAssertEqual(PosterBadges.favSymbol(fav: true, hover: false), "heart.fill")
        XCTAssertEqual(PosterBadges.favSymbol(fav: true, hover: true), "heart.fill")
        XCTAssertEqual(PosterBadges.favSymbol(fav: false, hover: true), "heart")
        XCTAssertEqual(PosterBadges.favSymbol(fav: false, hover: false), "heart")
    }

    func testWatchedBadgeContent() {
        XCTAssertEqual(PosterBadges.watchedContent(played: true, unwatched: 0, hover: false)?.text, "checkmark")
        XCTAssertEqual(PosterBadges.watchedContent(played: true, unwatched: 0, hover: false)?.outline, false)
        XCTAssertEqual(PosterBadges.watchedContent(played: false, unwatched: 0, hover: true)?.outline, true)
        XCTAssertEqual(PosterBadges.watchedContent(played: false, unwatched: 0, hover: false)?.outline, true)
        XCTAssertEqual(PosterBadges.watchedContent(played: false, unwatched: 5, hover: false)?.text, "5")
        XCTAssertEqual(PosterBadges.watchedContent(played: false, unwatched: 140, hover: true)?.text, "99+")
        XCTAssertTrue((22...24).contains(PosterBadges.size))
    }

    // MARK: Detail row

    func testRatingIsLastInDetailRow() {
        XCTAssertEqual(DetailRowOrder.order.last, "admin")   // the admin ⋯ after the rating
        XCTAssertEqual(DetailRowOrder.order.dropLast().last, "rating")
        XCTAssertEqual(Array(DetailRowOrder.order.prefix(2)), ["play", "resume"])
        let i = DetailRowOrder.order.firstIndex(of: "favorite")!
        XCTAssertEqual(DetailRowOrder.order.firstIndex(of: "rating"), i + 1)
        let c = DetailRowOrder.order.firstIndex(of: "cast")!
        XCTAssertEqual(DetailRowOrder.order.firstIndex(of: "airplay"), c + 1)   // AirPlay right after Cast
        XCTAssertEqual(DetailRowOrder.order.firstIndex(of: "trailer"), c + 2)
    }

    // MARK: Now Playing

    func testClientIcons() {
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Emby Web", device: "Samsung Browser Android"), "globe")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Jellyfin Web", device: "Firefox"), "globe")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Emby for Android TV", device: "SHIELD"), "tv")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Jellyfin Android TV", device: "Chromecast"), "tv")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Emby for iOS", device: "iPad Pro"), "ipad")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Emby for iOS", device: "iPhone"), "iphone")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Jellyfin Android", device: "Pixel 8"), "iphone")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Cove", device: "MacBook Pro"), "macbook")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Emby Theater", device: "DESKTOP-1"), "macbook")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: "Something", device: "Box"), "play.rectangle")
        XCTAssertEqual(NowPlayingStyle.clientIcon(client: nil, device: nil), "play.rectangle")
    }

    func testTimeLeft() {
        XCTAssertEqual(NowPlayingStyle.timeLeft(position: 2214, duration: 2496), "4:42 left")
        XCTAssertEqual(NowPlayingStyle.timeLeft(position: 0, duration: 3725), "1:02:05 left")
        XCTAssertEqual(NowPlayingStyle.timeLeft(position: 3000, duration: 2000), "0:00 left")
        XCTAssertNil(NowPlayingStyle.timeLeft(position: 10, duration: 0))
    }

    func testPlayMethod() {
        XCTAssertEqual(NowPlayingStyle.playMethod("DirectPlay").label, "Direct play")
        XCTAssertEqual(NowPlayingStyle.playMethod("DirectPlay").tint, .green)
        XCTAssertEqual(NowPlayingStyle.playMethod(nil).label, "Direct play")
        XCTAssertEqual(NowPlayingStyle.playMethod("DirectStream").label, "Direct stream")
        XCTAssertEqual(NowPlayingStyle.playMethod("DirectStream").tint, .blue)
        XCTAssertEqual(NowPlayingStyle.playMethod("Transcode").label, "Transcoding")
        XCTAssertEqual(NowPlayingStyle.playMethod("Transcode").tint, .orange)
    }

    func testHeaderAndWhoLine() {
        XCTAssertEqual(NowPlayingStyle.activeText(1), "1 active")
        XCTAssertEqual(NowPlayingStyle.whoLine(user: "catalin", device: "Samsung Browser Android"), "catalin · Samsung Browser Android")
        XCTAssertEqual(NowPlayingStyle.whoLine(user: nil, device: "Mac"), "Mac")
        XCTAssertEqual(NowPlayingStyle.whoLine(user: "", device: "Mac"), "Mac")
    }

    func testLivePosition() {
        XCTAssertEqual(NowPlayingStyle.livePosition(reported: 100, duration: 200, paused: false, elapsed: 3), 103)
        XCTAssertEqual(NowPlayingStyle.livePosition(reported: 100, duration: 200, paused: true, elapsed: 3), 100)
        XCTAssertEqual(NowPlayingStyle.livePosition(reported: 199, duration: 200, paused: false, elapsed: 5), 200)
    }
}
