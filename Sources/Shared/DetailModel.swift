import Foundation
import Combine

/// An item page's data and decisions (the full item, a series' seasons and episodes, the chosen season, the
/// next episode, Included In, More Like This, the version/audio/subtitle/quality choices and what Play does),
/// shared by the Glass and Classic detail views; they keep only layout, styling and animation.
/// The views call `load` from `.task`, so SwiftUI still cancels it when the page goes away; a cancelled load
/// stops at its next step and writes nothing more.
@MainActor
final class DetailModel: ObservableObject {
    let item: Item
    @Published var full: Full?
    /// A series' episodes, or a collection's titles
    @Published var kids: [Item] = []
    @Published var seasonItems: [Item] = []
    /// Subtitle languages of the first episode (the Subtitles menu above a series' episodes)
    @Published var epLangs: [(code: String, name: String)] = []
    @Published var similar: [Item] = []
    @Published var includedIn: [Item] = []
    @Published var srcIdx = 0
    @Published var audioIdx = -1
    @Published var subIdx = -1
    @Published var quality: Int
    /// The season picked on the page (nil: the first one with something unwatched)
    @Published var season: Int? = nil
    @Published var nextEp: Item? = nil
    /// "Show all" / "Hide watched" in a season
    @Published var showAllEps = false

    private weak var source: DetailSource?
    private let defaults: UserDefaults

    init(item: Item, defaults: UserDefaults = .standard) {
        self.item = item
        self.defaults = defaults
        self.quality = defaults.integer(forKey: "defaultQuality")
    }

    func bind(_ source: DetailSource) { self.source = source }

    private func isPlayed(_ it: Item) -> Bool { source?.isPlayed(it) ?? false }

    // MARK: Loading

    /// Same requests in the same order as the pages always made: the item, then (series) episodes and seasons
    /// together, the next episode and the first episode's subtitle languages, (collection) its titles, then
    /// Included In and More Like This.
    func load() async {
        guard let source else { return }
        let f = await source.full(item.id)
        guard !Task.isCancelled else { return }
        full = f
        audioIdx = defaultAudio
        applyPreferredSub()
        if item.isSeries {
            async let eps = source.episodes(item.id)
            async let ss = source.seasons(item.id)
            let e = await eps
            guard !Task.isCancelled else { return }
            kids = e
            let s = await ss
            guard !Task.isCancelled else { return }
            seasonItems = s
            if let s = source.openSeason { season = s; source.openSeason = nil }
            let next = await source.nextUp(item.id)
            guard !Task.isCancelled else { return }
            nextEp = next ?? kids.first { !source.isPlayed($0) } ?? kids.first
            if let first = kids.first {
                let ff = await source.full(first.id)
                guard !Task.isCancelled else { return }
                epLangs = Self.subLangs(ff)
            }
        }
        else if item.isBox {
            let c = await source.children(item.id)
            guard !Task.isCancelled else { return }
            kids = c
        }
        if !item.isEpisode && !item.isBox {
            let c = await source.collections(containing: item.id)
            guard !Task.isCancelled else { return }
            includedIn = c
        }
        if !item.isEpisode {
            let s = await source.similar(item.id)
            guard !Task.isCancelled else { return }
            similar = s
        }
    }

    /// Another version was picked: its default audio, no subtitle (or the preferred language).
    func sourceChanged() { audioIdx = defaultAudio; subIdx = -1; applyPreferredSub() }

    /// A new season shows its unwatched episodes again.
    func seasonChanged() { showAllEps = false }

    // MARK: Versions and streams

    var sources: [MSource] { full?.MediaSources ?? [] }
    var src: MSource? { sources.indices.contains(srcIdx) ? sources[srcIdx] : nil }
    func streams(_ t: String) -> [MStream] { (src?.MediaStreams ?? []).filter { $0.`Type` == t } }
    var defaultAudio: Int {
        let a = streams("Audio")
        return (a.first(where: { $0.IsDefault == true }) ?? a.first)?.Index ?? -1
    }
    /// Series and collections: no pickers, Play hands the whole item over
    var simple: Bool { item.isSeries || item.isBox }

    /// Pre-selects the preferred subtitle language when "Always load" is on.
    func applyPreferredSub() {
        guard defaults.bool(forKey: "subAlways"), let lang = defaults.string(forKey: "subLang"), !lang.isEmpty,
              let idx = preferredSub(src?.MediaStreams ?? [], lang: lang) else { return }
        subIdx = idx
    }

    // MARK: Play / resume

    /// `from` nil means resume where it was left off; 0 starts over.
    func playNow(from: Double? = nil) {
        guard let source else { return }
        if item.isSeries, let ep = nextEp { playEpisode(ep, from: from); return }
        if simple { Task { await source.play(item) }; return }
        let audioChanged = audioIdx >= 0 && audioIdx != defaultAudio
        source.playing = PlayRequest(item: item, sourceId: src?.Id,
                                     audio: audioChanged ? audioIdx : nil,
                                     sub: subIdx >= 0 ? subIdx : nil,
                                     maxBitrate: quality > 0 ? quality : nil,
                                     start: from ?? source.resumeAt(item),
                                     noSub: subIdx < 0)
    }

    /// The item the big Play button acts on (next-up episode for a series).
    var playTarget: Item? { item.isSeries ? nextEp : (simple ? nil : item) }

    /// Where the Play target was left off (0 = not started); when > 0 a Resume button shows beside Play.
    var resumePoint: Double { playTarget.map { source?.resumeAt($0) ?? 0 } ?? 0 }

    /// The Play button starts from the beginning when there is a resume point (Resume sits next to it).
    var playLabel: String {
        if item.isSeries, let ep = nextEp { return "Play S\(ep.ParentIndexNumber ?? 0):E\(ep.IndexNumber ?? 0)" }
        return "Play"
    }

    /// Plays an episode with the subtitle language chosen for episodes (text formats like SRT preferred).
    /// `from` nil means resume where it was left off.
    func playEpisode(_ ep: Item, from: Double? = nil) {
        guard let source else { return }
        let q = defaults.integer(forKey: "defaultQuality")
        let maxBitrate: Int? = q > 0 ? q : nil
        let start: Double = from ?? source.resumeAt(ep)
        // Subtitles menu: "off" = explicitly none; empty = the default (the preferred language from Settings when
        // "Always load preferred subtitle language" is on, ignoring what was remembered for the series); else a language
        let epSubLang = defaults.string(forKey: "episodeSubLang") ?? ""
        if epSubLang == "off" { source.playing = PlayRequest(item: ep, maxBitrate: maxBitrate, start: start, noSub: true); return }
        let preferred: String = defaults.bool(forKey: "subAlways") ? (defaults.string(forKey: "subLang") ?? "").lowercased() : ""
        let wanted: String = epSubLang.isEmpty ? preferred : epSubLang
        if wanted.isEmpty { source.playing = PlayRequest(item: ep, maxBitrate: maxBitrate, start: start); return }
        Task {
            let f = await source.full(ep.id)
            let src = f?.MediaSources?.first
            let all = src?.MediaStreams ?? []
            let subs = all.filter { $0.`Type` == "Subtitle" && subLangName($0).lowercased() == wanted }
            let text = ["srt", "subrip", "vtt", "ass", "ssa"]
            var pick = (subs.first { text.contains(($0.Codec ?? "").lowercased()) } ?? subs.first)?.Index
            if pick == nil { pick = preferredSub(all, lang: wanted) }
            source.playing = PlayRequest(item: ep, sourceId: src?.Id, sub: pick, maxBitrate: maxBitrate, start: start)
        }
    }

    /// Subtitle languages found in an item, keyed by language code.
    static func subLangs(_ f: Full?) -> [(code: String, name: String)] {
        var out: [(code: String, name: String)] = []
        for st in f?.MediaSources?.first?.MediaStreams ?? [] where st.`Type` == "Subtitle" {
            let name = subLangName(st)
            if out.contains(where: { $0.code == name.lowercased() }) { continue }
            out.append((name.lowercased(), name))
        }
        return out
    }

    // MARK: Seasons and episodes

    /// Season numbers in order, Specials (0) last.
    var seasonNumbers: [Int] {
        let set = Set(kids.map { $0.ParentIndexNumber ?? 0 })
        return set.sorted { (a: Int, b: Int) -> Bool in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }

    var currentSeason: Int {
        if let season { return season }
        if let firstUnwatched = kids.first(where: { !isPlayed($0) })?.ParentIndexNumber { return firstUnwatched }
        return seasonNumbers.first ?? 0
    }

    func seasonTitle(_ n: Int) -> String {
        if n == 0 { return "Specials" }
        return seasonItem(n)?.Name ?? "Season \(n)"
    }

    func seasonItem(_ n: Int) -> Item? { seasonItems.first { ($0.IndexNumber ?? 0) == n } }

    func episodes(inSeason n: Int) -> [Item] { kids.filter { ($0.ParentIndexNumber ?? 0) == n } }

    /// All episodes of the season being shown.
    /// currentSeason is worked out once: inside the filter it re-scanned every episode for each episode,
    /// which made every redraw of a long series slow (switching back to Cove, leaving full screen).
    var seasonEpisodes: [Item] { episodes(inSeason: currentSeason) }

    /// The season has both watched and unwatched episodes, so "hide watched" makes sense.
    var canFilterWatched: Bool {
        let all: [Item] = seasonEpisodes
        let open: Int = all.filter { !isPlayed($0) }.count
        return open > 0 && open < all.count
    }

    /// Unwatched episodes only, unless the season is fully watched / fully unwatched or "Show all" is on.
    var shownEpisodes: [Item] {
        let all: [Item] = seasonEpisodes
        if canFilterWatched && !showAllEps { return all.filter { !isPlayed($0) } }
        return all
    }

    /// Unwatched episodes in a season (nil while episodes are loading).
    func unwatched(_ n: Int) -> Int? {
        let eps = episodes(inSeason: n)
        return eps.isEmpty ? nil : eps.filter { !isPlayed($0) }.count
    }

    /// A collection's movies in release order (by year, then date), for Classic's banner deck.
    var boxMovies: [Item] {
        kids.sorted { ($0.ProductionYear ?? 9999, $0.PremiereDate ?? "") < ($1.ProductionYear ?? 9999, $1.PremiereDate ?? "") }
    }
}
