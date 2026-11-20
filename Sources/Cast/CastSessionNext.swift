import Foundation

// Cast phase 2: continue on the TV. The next episode (autoplay setting "autoNext", as local playback) or the next
// film of the collection queue (collection mode) loads on the same receiver session at the end (MEDIA_STATUS
// FINISHED) or on Up next's Play now, with the remembered audio/subtitles. Decisions in CastContinue.swift.

@MainActor
extension CastSession {
    var autoNext: Bool { UserDefaults.standard.object(forKey: "autoNext") as? Bool ?? true }

    /// The item that would play next (nil: autoplay off, not an episode/collection, end of the queue).
    var nextItem: Item? {
        guard let item else { return nil }
        return CastContinue.next(after: item, episodes: episodes, collection: collection, autoNext: autoNext)
    }

    /// The queue position for the remote ("Film 2 of 4" / "S2:E5").
    var position: String? { item.flatMap { CastContinue.position($0, collection: collection) } }

    /// Seconds to the end, for "Starts in 12s".
    var secsLeft: Int { PlayerUIModel.secsLeft(time: time, duration: duration) }

    /// The series' episodes and the credits marker, loaded beside the LOAD (they only matter near the end).
    func loadContinuation(_ emby: Emby, _ item: Item, chapters: [Chapter]) {
        creditsMarker = chapters.first { $0.MarkerType == "CreditsStart" }?.start
        Task {
            if creditsMarker == nil, let m = await emby.creditsSegment(item.Id), self.item?.Id == item.Id { creditsMarker = m }
            if collection == nil, item.isEpisode, episodes.isEmpty, let sid = item.SeriesId {
                let list = await emby.episodes(sid)
                if self.item?.Id == item.Id { episodes = list }
            }
        }
    }

    /// Every second: the Up next card from the credits on.
    func updateUpNext() {
        let n = nextItem
        let show = phase == .active && !reconnecting &&
            CastContinue.showUpNext(hasNext: n != nil, cancelled: upNextCancelled, collection: collection != nil,
                                    time: time, duration: duration, marker: creditsMarker)
        let want = show ? n : nil
        if want?.Id != upNext?.Id { upNext = want }
    }

    /// Up next's Play now.
    func playNextNow() { _ = playNext() }

    func cancelUpNext() { upNextCancelled = true; upNext = nil }

    /// The video ended on the TV: true when the next item was loaded.
    func playNextAtEnd() -> Bool { upNextCancelled ? false : playNext() }

    private func playNext() -> Bool {
        guard let n = nextItem, let device, let emby else { return false }
        DebugLog.write("cast: next \(collection != nil ? "film" : "episode") on the TV")
        upNext = nil
        cast(n, to: device, emby: emby, sourceId: nil, audio: nil, sub: nil, start: 0,
             collection: collection?.at(n), pickTracks: true)
        return true
    }
}
