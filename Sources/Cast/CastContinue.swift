import Foundation

// Cast phase 2, pure logic (no network, no UI), unit-tested in Tests/CastContinueTests.swift: what plays next on
// the TV (next episode / next film of the collection), when the Up next card shows, which audio and subtitle
// tracks a cast uses (the same memory as local playback), the reconnect decision from the receiver's replies and
// the saved cast restored after a relaunch.

enum CastContinue {
    /// The item after `current`: the next film of the collection queue (no skipping, no shuffle) in collection
    /// mode, else the next episode of the series list. Nil at the end, or with autoplay off.
    static func next(after current: Item, episodes: [Item], collection: CollectionQueue?, autoNext: Bool) -> Item? {
        guard autoNext else { return nil }
        let list = collection?.items ?? (current.isEpisode ? episodes : [])
        guard let i = list.firstIndex(where: { $0.Id == current.Id }), i + 1 < list.count else { return nil }
        return list[i + 1]
    }

    /// Seconds an episode's Up next card shows before the end without a credits marker (as in the local player).
    static let episodeLead: Double = 30

    /// When the Up next card appears: in collection mode at the credits (CollectionPlay's rule: the marker, else
    /// 5 min before the end but never before half); an episode at its credits marker, else its last 30 s.
    static func upNextStart(collection: Bool, marker: Double?, duration: Double) -> Double {
        guard duration > 0 else { return .infinity }
        if collection { return CollectionPlay.creditsStart(marker: marker, duration: duration) }
        if let m = marker, m > duration / 2, m < duration { return m }
        return duration - episodeLead
    }

    static func showUpNext(hasNext: Bool, cancelled: Bool, collection: Bool, time: Double, duration: Double, marker: Double?) -> Bool {
        guard hasNext, !cancelled, duration > 120 else { return false }
        return time >= upNextStart(collection: collection, marker: marker, duration: duration) && time < duration - 0.5
    }

    /// The remote's queue position: "Film 2 of 4" in collection mode, "S2:E5" for an episode.
    static func position(_ item: Item, collection: CollectionQueue?) -> String? {
        if let c = collection, let i = c.items.firstIndex(where: { $0.Id == item.Id }) { return "Film \(i + 1) of \(c.items.count)" }
        if item.isEpisode { return "S\(item.ParentIndexNumber ?? 0):E\(item.IndexNumber ?? 0)" }
        return nil
    }

    /// The Up next card's lines (the local card's wording).
    static func heading(_ next: Item, collection: CollectionQueue?) -> String {
        guard let c = collection, let i = c.items.firstIndex(where: { $0.Id == next.Id }) else { return "Up next" }
        return CollectionPlay.cardHeading(nextIndex: i, count: c.items.count)
    }

    static func title(_ next: Item, collection: CollectionQueue?) -> String {
        collection != nil ? CollectionPlay.filmTitle(next) : "S\(next.ParentIndexNumber ?? 0):E\(next.IndexNumber ?? 0) · \(next.Name)"
    }

    /// The SeriesLang key of a cast: "box:<collectionId>" in collection mode, else the episode's series.
    static func memoryKey(_ item: Item, collection: CollectionQueue?) -> String? {
        SeriesLang.key(PlayRequest(item: item, collection: collection))
    }
}

// MARK: - Tracks

enum CastTracks {
    /// The tracks a cast uses when the caller didn't pick any (detail page series/collection, next episode/film),
    /// with the local player's rules: the default audio, or the language remembered for the series/collection;
    /// subtitles: "Always load preferred subtitle language" wins, else the remembered language or "off"; an
    /// external SRT before an embedded SUBRIP (bestTextSub). `wantedSub`: the detail page's episode Subtitles
    /// menu ("off" or a language), which comes first.
    static func pick(_ streams: [MStream], memory: [String: String]?, wantedSub: String? = nil,
                     subAlways: Bool, subLang: String?) -> (audio: Int?, sub: Int?) {
        let auds = streams.filter { $0.`Type` == "Audio" }
        var audio = (auds.first { $0.IsDefault == true } ?? auds.first)?.Index
        if let l = memory?["audio"], let st = auds.first(where: { ($0.Language ?? "").lowercased() == l.lowercased() }) {
            audio = st.Index
        }
        var sub: Int?
        if let w = wantedSub, !w.isEmpty {
            if w == "off" { return (audio, nil) }
            sub = preferredSub(streams, lang: w)
        } else if subAlways, let l = subLang, !l.isEmpty {
            sub = preferredSub(streams, lang: l)
        } else if let l = memory?["sub"], l != "off" {
            sub = preferredSub(streams, lang: l)
        }
        return (audio, sub)
    }

    /// What a track change on the remote writes to the memory (as the local player's setSub / setAudio).
    static func subMemory(_ idx: Int?, streams: [MStream]) -> String {
        idx.flatMap { i in streams.first { $0.Index == i } }.map(subLangName) ?? "off"
    }

    static func audioMemory(_ idx: Int, streams: [MStream]) -> String? {
        streams.first { $0.Index == idx }?.Language.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Reconnect

enum CastReconnect {
    /// Wait before each reconnect attempt; the last one repeats until `giveUpAfter`.
    static let backoff: [Double] = [1, 2, 4, 8, 15]
    static let giveUpAfter: Double = 120

    /// The wait before attempt `n` (0-based), nil once ~2 minutes have passed.
    static func delay(attempt n: Int, elapsed: Double) -> Double? {
        guard elapsed < giveUpAfter else { return nil }
        return backoff[min(n, backoff.count - 1)]
    }

    enum Receiver: Equatable {
        /// Our receiver app still runs: CONNECT to its transport and ask for the media status.
        case attach(transportId: String, sessionId: String?)
        case takenOver(String?)
        case idle
    }

    /// After reconnecting, from RECEIVER_STATUS: is our app (CC1AD845) still the one running, with our session?
    static func receiver(_ st: CastReceiverStatus, session: String?) -> Receiver {
        if let tid = st.transportId {
            if let s = session, let now = st.sessionId, s != now { return .takenOver(nil) }   // another sender's
            return .attach(transportId: tid, sessionId: st.sessionId)
        }
        return st.otherApp.map { .takenOver($0) } ?? .idle
    }

    /// From MEDIA_STATUS after attaching: our media still loaded (playing, paused or buffering, and its stream
    /// carries our PlaySessionId when known). Nil status = nothing loaded.
    static func mediaAlive(_ st: CastMediaStatus?, playSessionId: String?) -> Bool {
        guard let st, st.playerState != "IDLE" else { return false }
        if let ps = playSessionId, let c = st.contentId { return c.contains(ps) }
        return true
    }

    static let takenOverMessage = "The TV is now showing something else."
    static let endedMessage = "Casting ended."
    static func lostMessage(_ name: String) -> String { "Lost the connection to \(name). Casting ended." }
}

// MARK: - Saved cast (relaunch)

/// The running cast, kept in UserDefaults so a relaunch can show the remote again when the TV still plays it.
struct SavedCast: Codable, Equatable {
    var server: String
    var deviceId: String
    var deviceName: String
    var itemId: String
    var sourceId: String?
    var receiverSession: String?
    var playSessionId: String
    var audio: Int?
    var sub: Int?
    var position: Double
    var collectionId: String?
    var collectionName: String?
    var collectionIds: [String]?

    static let key = "castActive"

    static func load(_ d: UserDefaults = .standard) -> SavedCast? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedCast.self, from: $0) }
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
    static func clear(_ d: UserDefaults = .standard) { d.removeObject(forKey: key) }

    /// Worth trying after a relaunch: the same server, and the device was found on the network.
    func restorable(server s: String, devices: [CastDevice]) -> CastDevice? {
        guard s == server else { return nil }
        return devices.first { $0.id == deviceId }
    }
}
