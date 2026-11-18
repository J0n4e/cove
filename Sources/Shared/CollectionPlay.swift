import Foundation

/// "Play collection" (a BoxSet's films one after another). Collection mode exists ONLY when it was started with
/// the collection page's Play collection / Resume <film> buttons: the PlayRequest then carries this queue. A film
/// played the usual way has no queue and behaves exactly as before (no Up next film card, no Collection panel).
struct CollectionQueue: Equatable {
    let id: String
    let name: String
    /// Every film of the collection, in the server's order (none skipped, watched ones included)
    let items: [Item]
    var index: Int

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var ids: [String] { items.map(\.Id) }

    /// The same queue, now at `film` (nil if the film isn't in it).
    func at(_ film: Item) -> CollectionQueue? {
        guard let i = items.firstIndex(where: { $0.Id == film.Id }) else { return nil }
        var q = self; q.index = i; return q
    }
}

enum CollectionPlay {
    /// Play collection: every film in the server's order, starting at film 1.
    static func queue(collection: Item, films: [Item], start: Int = 0) -> CollectionQueue? {
        guard !films.isEmpty else { return nil }
        return CollectionQueue(id: collection.Id, name: collection.Name, items: films,
                               index: min(max(0, start), films.count - 1))
    }

    /// The film in progress (a saved position, not watched), for the "Resume <film>" button: the first one in order.
    static func resumeIndex(films: [Item], position: (Item) -> Double, played: (Item) -> Bool) -> Int? {
        films.firstIndex { position($0) > 0 && !played($0) }
    }

    /// "Resume The Two Towers (1:12:30)"
    static func resumeLabel(_ film: Item, position: Double) -> String {
        "Resume \(film.Name) (\(clock(position)))"
    }

    nonisolated static func clock(_ t: Double) -> String {
        let s = max(0, Int(t)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Seconds before the end the Up next card appears when the server has no credits marker.
    nonisolated static let fallbackLead: Double = 300

    /// Where the credits start: the server's marker when it's inside the film, else 5 minutes before the end
    /// (never earlier than half the film, for short ones).
    nonisolated static func creditsStart(marker: Double?, duration: Double) -> Double {
        guard duration > 0 else { return .infinity }
        if let m = marker, m > 0, m < duration { return m }
        return max(duration - fallbackLead, duration / 2)
    }

    /// The Up next card in collection mode: from the credits to the very end, when there's a next film.
    nonisolated static func showUpNext(hasNext: Bool, cancelled: Bool, time: Double, duration: Double, marker: Double?) -> Bool {
        guard hasNext, !cancelled, duration > 120 else { return false }
        return time >= creditsStart(marker: marker, duration: duration) && time < duration - 0.5
    }

    /// "Up next · film 2 of 3"
    nonisolated static func cardHeading(nextIndex: Int, count: Int) -> String { "Up next · film \(nextIndex + 1) of \(count)" }

    /// "The Two Towers (2002)"
    nonisolated static func filmTitle(_ it: Item) -> String {
        it.ProductionYear.map { "\(it.Name) (\($0))" } ?? it.Name
    }

    /// The collection a SyncPlay group plays: the queue started here, when the group's playlist is exactly it.
    @MainActor static var groupQueue: CollectionQueue?

    nonisolated static func groupCollection(_ q: CollectionQueue?, playlist: [String], itemId: String) -> CollectionQueue? {
        guard let q, q.ids == playlist, let i = q.items.firstIndex(where: { $0.Id == itemId }) else { return nil }
        var r = q; r.index = i; return r
    }
}

/// Jellyfin 10.10+: the item's media segments (Intro, Outro…).
struct MediaSegmentList: Decodable {
    struct Segment: Decodable { let `Type`: String?; let StartTicks: Int64? }
    let Items: [Segment]?

    /// The start of the "Outro" (credits) segment, in seconds.
    var outroStart: Double? {
        (Items ?? []).first { ($0.`Type` ?? "").lowercased() == "outro" }
            .flatMap { $0.StartTicks }.map { Double($0) / 10_000_000 }
    }
}

extension Emby {
    /// Jellyfin's credits marker (MediaSegments "Outro"); nil on Emby (its markers come with the chapters) or
    /// when the server has none.
    func creditsSegment(_ itemId: String) async -> Double? {
        guard isJellyfin else { return nil }
        let r: MediaSegmentList? = try? await get("/MediaSegments/\(itemId)", ["includeSegmentTypes": "Outro"])
        return r?.outroStart
    }

    /// Play collection / Resume <film>: plays the queue at its index (a group gets the whole queue).
    func playCollection(_ q: CollectionQueue, start: Double) {
        guard let film = q.current else { return }
        if syncPlay.group.isInGroup {
            CollectionPlay.groupQueue = q
            syncPlay.group.playQueue(q.ids, index: q.index, startTicks: Int64(start * 10_000_000))
            return
        }
        let qual = UserDefaults.standard.integer(forKey: "defaultQuality")
        playing = PlayRequest(item: film, maxBitrate: qual > 0 ? qual : nil, start: start > 0 ? start : nil, collection: q)
    }
}

@MainActor
extension PlayerUIModel {
    /// Takes the request's collection queue (collection mode), before the list loads.
    func adopt(_ req: PlayRequest) { collection = req.collection }

    var inCollection: Bool { collection != nil }

    /// Loads the credits marker of a film played in collection mode (Jellyfin; Emby's comes with the chapters).
    func loadCredits(_ emby: Emby, _ item: Item) async {
        guard collection != nil else { return }
        creditsMarker = await emby.creditsSegment(item.Id)
    }

    /// The Up next card's first line.
    func upNextHeading(_ next: Item) -> String {
        guard let c = collection, let i = c.items.firstIndex(where: { $0.Id == next.Id }) else { return "Up next" }
        return CollectionPlay.cardHeading(nextIndex: i, count: c.items.count)
    }

    /// The Up next card's title: "S1:E2 · Name", or a film's "Name (year)".
    func upNextTitle(_ next: Item) -> String {
        collection != nil ? CollectionPlay.filmTitle(next)
            : "S\(next.ParentIndexNumber ?? 0):E\(next.IndexNumber ?? 0) · \(next.Name)"
    }

    /// The card's picture: a wide still for an episode, the film's backdrop in a collection.
    func upNextImage(_ emby: Emby, _ next: Item) -> URL? {
        collection != nil ? emby.image(next.backdropId ?? next.Id, (next.backdropId != nil ? "Backdrop" : "Primary"), width: 400)
            : emby.image(next.Id, "Primary", width: 400, plain: true)
    }

    var listTitle: String { collection != nil ? "Collection" : "Episodes" }
    var listHelp: String { collection != nil ? "Collection (E)" : "Episodes (E)" }

    /// The next film / episode request keeps the collection queue (still in collection mode).
    func queue(for next: Item) -> CollectionQueue? { collection?.at(next) }
}
