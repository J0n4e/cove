import XCTest
@testable import Cove

/// The player screen's shared logic (PlayerUIModel), used by the Glass and Classic players.
@MainActor
final class SharedPlayerUITests: XCTestCase {
    func stream(_ index: Int, _ title: String?) -> MStream {
        var json = "{\"Index\":\(index),\"Type\":\"Subtitle\""
        if let title { json += ",\"DisplayTitle\":\"\(title)\"" }
        return try! JSONDecoder().decode(MStream.self, from: Data((json + "}").utf8))
    }

    func item(_ id: String, season: Int? = nil, episode: Int? = nil, type: String = "Episode") -> Item {
        var json = "{\"Id\":\"\(id)\",\"Name\":\"n\(id)\",\"Type\":\"\(type)\",\"SeriesId\":\"s\""
        if let season { json += ",\"ParentIndexNumber\":\(season)" }
        if let episode { json += ",\"IndexNumber\":\(episode)" }
        return try! JSONDecoder().decode(Item.self, from: Data((json + "}").utf8))
    }

    // MARK: Option lists and the current choice

    func testSubtitleOptionsStartWithOff() {
        let opts = PlayerUIModel.subtitleOptions([stream(3, "English"), stream(5, nil)])
        XCTAssertEqual(opts.map(\.0), [nil, 3, 5])
        XCTAssertEqual(opts.map(\.1), ["Off", "English", "Track 5"])
        XCTAssertEqual(PlayerUIModel.selectedIndex(opts, nil), 0)
        XCTAssertEqual(PlayerUIModel.selectedIndex(opts, 5), 2)
        XCTAssertEqual(PlayerUIModel.selectedIndex(opts, 9), 0)   // not in the list: first entry
        XCTAssertEqual(PlayerUIModel.subtitleOptions([]).map(\.1), ["Off"])
    }

    func testAudioOptions() {
        let opts = PlayerUIModel.audioOptions([stream(1, "English AAC"), stream(2, nil)])
        XCTAssertEqual(opts.map(\.0), [1, 2])
        XCTAssertEqual(opts.map(\.1), ["English AAC", "Track 2"])
        XCTAssertEqual(PlayerUIModel.selectedIndex(opts, 2), 1)
    }

    func testQualityList() {
        XCTAssertEqual(PlayerUIModel.qualities.map(\.0), [0, 8_000_000, 4_000_000, 1_500_000])
        XCTAssertEqual(PlayerUIModel.qualities.map(\.1), ["Original", "1080p · 8 Mbps", "720p · 4 Mbps", "480p · 1.5 Mbps"])
        XCTAssertEqual(PlayerUIModel.selectedIndex(PlayerUIModel.qualities, 4_000_000), 2)
        XCTAssertEqual(PlayerUIModel.selectedIndex(PlayerUIModel.qualities, 123), 0)
        // The views' own names still point at the same list (Settings reads PlayerView.sizes etc.)
        XCTAssertEqual(PlayerView.qualities.map(\.0), PlayerUIModel.qualities.map(\.0))
        XCTAssertEqual(ClassicPlayerView.qualities.map(\.0), PlayerUIModel.qualities.map(\.0))
        XCTAssertEqual(PlayerView.sizes.map(\.0), ["smaller", "small", "normal", "large", "larger"])
    }

    func testSpeedsAndLabels() {
        XCTAssertEqual(PlayerUIModel.speeds, [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
        XCTAssertEqual(PlayerUIModel.speeds.map(PlayerUIModel.speedLabel), ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"])
        XCTAssertEqual(PlayerUIModel.speedHelp(1), "Normal speed")
        XCTAssertEqual(PlayerUIModel.speedHelp(1.5), "1.5× speed")
        XCTAssertEqual(PlayerUIModel.bottomPositions.map(\.1), ["0%", "5%", "10%", "15%", "20%", "25%", "30%"])
    }

    // MARK: Time

    func testTimeFormat() {
        XCTAssertEqual(PlayerUIModel.fmt(0), "0:00")
        XCTAssertEqual(PlayerUIModel.fmt(59.9), "0:59")
        XCTAssertEqual(PlayerUIModel.fmt(61), "1:01")
        XCTAssertEqual(PlayerUIModel.fmt(3600), "1:00:00")
        XCTAssertEqual(PlayerUIModel.fmt(5403), "1:30:03")
        XCTAssertEqual(PlayerUIModel.fmt(-1), "0:00")
        XCTAssertEqual(PlayerUIModel.fmt(.nan), "0:00")
        XCTAssertEqual(PlayerUIModel.fmt(.infinity), "0:00")
    }

    func testHoverPreviewTime() {
        XCTAssertEqual(PlayerUIModel.previewTime(x: 50, width: 200, duration: 400), 100)
        XCTAssertEqual(PlayerUIModel.previewTime(x: -10, width: 200, duration: 400), 0)     // left of the bar
        XCTAssertEqual(PlayerUIModel.previewTime(x: 500, width: 200, duration: 400), 400)   // right of the bar
        XCTAssertEqual(PlayerUIModel.previewTime(x: 0.5, width: 0, duration: 400), 0)       // not measured yet
        // The bubble stays inside the timeline
        XCTAssertEqual(PlayerUIModel.previewOffset(x: 10, previewWidth: 96, width: 500), 0)
        XCTAssertEqual(PlayerUIModel.previewOffset(x: 250, previewWidth: 96, width: 500), 202)
        XCTAssertEqual(PlayerUIModel.previewOffset(x: 495, previewWidth: 96, width: 500), 404)
    }

    func testPreviewFollowsScrubOrPointer() {
        let ui = PlayerUIModel(style: .glass)
        ui.sliderW = 200
        XCTAssertNil(ui.previewX)
        ui.hoverX = 40
        XCTAssertEqual(ui.previewX, 40)
        ui.player.duration = 100
        ui.scrub = 25; ui.scrubbing = true
        XCTAssertEqual(ui.previewX, 50)
        XCTAssertEqual(ui.shownTime, 25)
        XCTAssertEqual(ui.remainingText, "-1:15")
    }

    // MARK: Auto-hide, keys

    func testHideDecision() {
        XCTAssertEqual(PlayerUIModel.hideDelay, 3)
        XCTAssertEqual(PlayerUIModel.hideDecision(playing: true, panelOpen: false, listOpen: false), .hide)
        XCTAssertEqual(PlayerUIModel.hideDecision(playing: false, panelOpen: false, listOpen: false), .keep)
        XCTAssertEqual(PlayerUIModel.hideDecision(playing: true, panelOpen: true, listOpen: false), .keep)
        XCTAssertEqual(PlayerUIModel.hideDecision(playing: true, panelOpen: false, listOpen: true), .waitAgain)
        XCTAssertEqual(PlayerUIModel.hideDecision(playing: false, panelOpen: true, listOpen: true), .waitAgain)
    }

    func testSeekStepAndEsc() {
        XCTAssertEqual(PlayerUIModel.seekDelta(.left, skipSeconds: 10), -10)
        XCTAssertEqual(PlayerUIModel.seekDelta(.right, skipSeconds: 10), 10)
        XCTAssertEqual(PlayerUIModel.seekDelta(.right, skipSeconds: 30), 30)
        XCTAssertEqual(PlayerUIModel.escAction(panelOpen: true, fullScreen: true), .closePanel)
        XCTAssertEqual(PlayerUIModel.escAction(panelOpen: false, fullScreen: true), .exitFullScreen)
        XCTAssertEqual(PlayerUIModel.escAction(panelOpen: false, fullScreen: false), .closePlayer)
    }

    func testKeyMonitorIsRemoved() {
        let ui = PlayerUIModel(style: .classic)
        ui.installKeyMonitor(toggleFullScreen: {}, close: {})
        XCTAssertTrue(ui.hasKeyMonitor)
        ui.installKeyMonitor(toggleFullScreen: {}, close: {})   // a second install replaces the first
        XCTAssertTrue(ui.hasKeyMonitor)
        ui.removeKeyMonitor()
        XCTAssertFalse(ui.hasKeyMonitor)
    }

    // MARK: Panels, episodes, up next

    func testPanelToggles() {
        let ui = PlayerUIModel(style: .glass)
        let ep = item("2", season: 2, episode: 1)
        ui.pickerSeason = 1
        ui.toggleEpisodes(ep)
        XCTAssertEqual(ui.panel, .episodes)
        XCTAssertEqual(ui.pickerSeason, 2)   // opens on the playing episode's season
        ui.toggleEpisodes(ep)
        XCTAssertNil(ui.panel)
        ui.toggleChapters(); XCTAssertEqual(ui.panel, .chapters)
        ui.toggleMediaPanel(); XCTAssertNil(ui.panel)   // the media button closes any open panel
        ui.toggleMediaPanel(); XCTAssertEqual(ui.panel, .subtitles)
        XCTAssertTrue(ui.controlsVisible)
        ui.tap(clickToPause: true)   // a click with a panel open only closes the panel
        XCTAssertNil(ui.panel)
    }

    func testEpisodeNeighboursAndSeasons() {
        let ui = PlayerUIModel(style: .glass)
        let a = item("a", season: 1, episode: 1), b = item("b", season: 1, episode: 2), c = item("c", season: 2, episode: 1)
        ui.episodes = [a, b, c]
        XCTAssertNil(ui.prevEp(a)?.Id)
        XCTAssertEqual(ui.nextEp(a)?.Id, "b")
        XCTAssertEqual(ui.prevEp(c)?.Id, "b")
        XCTAssertNil(ui.nextEp(c))
        XCTAssertTrue(ui.hasEpisodeList(a))
        XCTAssertEqual(ui.seasons, [1, 2])
        ui.pickerSeason = 1
        XCTAssertEqual(ui.seasonEpisodes.map(\.Id), ["a", "b"])
        XCTAssertEqual(PlayerUIModel.seasonName(0), "Specials")
        XCTAssertEqual(PlayerUIModel.seasonName(3), "Season 3")
        XCTAssertEqual(ui.shouldAutoPlayNext(autoNext: true, a)?.Id, "b")
        XCTAssertNil(ui.shouldAutoPlayNext(autoNext: false, a))
        ui.upNextCancelled = true
        XCTAssertNil(ui.shouldAutoPlayNext(autoNext: true, a))
    }

    func testUpNextWindow() {
        func show(_ t: Double, _ d: Double = 1200, ep: Bool = true, next: Bool = true, cancelled: Bool = false) -> Bool {
            PlayerUIModel.showUpNext(isEpisode: ep, hasNext: next, cancelled: cancelled, time: t, duration: d)
        }
        XCTAssertFalse(show(1169))
        XCTAssertTrue(show(1170))
        XCTAssertTrue(show(1199.4))
        XCTAssertFalse(show(1199.5))
        XCTAssertFalse(show(1180, ep: false))
        XCTAssertFalse(show(1180, next: false))
        XCTAssertFalse(show(1180, cancelled: true))
        XCTAssertFalse(show(100, 120))   // two minutes or shorter: never
        XCTAssertEqual(PlayerUIModel.secsLeft(time: 1180.2, duration: 1200), 20)
        XCTAssertEqual(PlayerUIModel.secsLeft(time: 1300, duration: 1200), 0)
    }

    func testSubtitleLiftAndMute() {
        XCTAssertEqual(PlayerUIModel.subLift(height: 1000, bottomPercent: 10, controlsVisible: false), 100)
        XCTAssertEqual(PlayerUIModel.subLift(height: 1000, bottomPercent: 10, controlsVisible: true), 190)
        XCTAssertEqual(PlayerUIModel.subLift(height: 1000, bottomPercent: 25, controlsVisible: true), 250)
        let saved = UserDefaults.standard.object(forKey: "playerVolume")
        defer { UserDefaults.standard.set(saved, forKey: "playerVolume") }
        let ui = PlayerUIModel(style: .glass)
        ui.player.volume = 0.4
        ui.toggleMute(); XCTAssertEqual(ui.player.volume, 0); XCTAssertEqual(ui.volumeIcon, "speaker.slash.fill")
        ui.toggleMute(); XCTAssertEqual(ui.player.volume, 1); XCTAssertEqual(ui.volumeIcon, "speaker.wave.2.fill")
    }
}
