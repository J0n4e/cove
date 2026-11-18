import AVFoundation
import Foundation

// Embedded text subtitles (SubRip etc. inside an MKV) shown at once: the server puts the track inside the HLS
// stream as WebVTT segments (SubtitleMethod=Hls), AVPlayer reads it alongside the video, and Cove takes the text
// through AVPlayerItemLegibleOutput into its own caption view (AVPlayer's own rendering is suppressed). Before,
// the server had to extract the whole track from the file first, which can take minutes on a large film.
// External .srt files and Direct Play (MP4) keep the download path (PlayerModel.loadCues).

/// How a chosen subtitle track reaches the screen.
enum SubPath: Equatable {
    case none          // no track
    case burnIn        // image subtitle (PGS…) or a text one that couldn't be read: burned in by the server
    case file          // external .srt: downloaded as a file
    case inStream      // embedded text track inside the HLS stream
    case extraction    // embedded track the server extracts (Direct Play, or the stream had no rendition)
}

/// Codecs the server can turn into WebVTT for the HLS stream.
let inStreamTextCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text", "text"]

enum LegibleText {
    /// The caption text of the attributed strings the legible output gives: styling dropped, one line per line.
    static func plain(_ strings: [NSAttributedString]) -> String {
        strings.map { plain($0.string) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension PlayerModel {
    /// Which path a track takes. `directPlay`: the video plays the file as is (no HLS, so no renditions).
    nonisolated static func subPath(_ st: MStream?, burnIn: Bool, directPlay: Bool) -> SubPath {
        guard let st else { return .none }
        let codec = (st.Codec ?? "").lowercased()
        if burnIn || imageSubCodecs.contains(codec) { return .burnIn }
        if st.IsExternal == true { return .file }
        if directPlay || !inStreamTextCodecs.contains(codec) { return .extraction }
        return .inStream
    }

    /// ISO 639-2/B and 639-2/T codes → 639-1, so "rum", "ron" and "ro" (or "ro-RO") are the same language.
    nonisolated static let iso639: [String: String] = [
        "rum": "ro", "ron": "ro", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "dut": "nl", "nld": "nl",
        "chi": "zh", "zho": "zh", "cze": "cs", "ces": "cs", "gre": "el", "ell": "el", "per": "fa", "fas": "fa",
        "alb": "sq", "sqi": "sq", "arm": "hy", "hye": "hy", "baq": "eu", "eus": "eu", "bur": "my", "mya": "my",
        "geo": "ka", "kat": "ka", "ice": "is", "isl": "is", "mac": "mk", "mkd": "mk", "mao": "mi", "mri": "mi",
        "may": "ms", "msa": "ms", "slo": "sk", "slk": "sk", "wel": "cy", "cym": "cy", "tib": "bo", "bod": "bo",
        "eng": "en", "spa": "es", "ita": "it", "por": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "ara": "ar",
        "hun": "hu", "pol": "pl", "swe": "sv", "nor": "no", "nob": "nb", "nno": "nn", "dan": "da", "fin": "fi",
        "tur": "tr", "heb": "he", "hin": "hi", "tha": "th", "vie": "vi", "ukr": "uk", "bul": "bg", "hrv": "hr",
        "srp": "sr", "slv": "sl", "est": "et", "lav": "lv", "lit": "lt", "ind": "id", "cat": "ca", "glg": "gl",
        "bos": "bs", "fil": "fil", "tam": "ta", "tel": "te", "ben": "bn", "urd": "ur", "mal": "ml", "kan": "kn",
    ]

    /// A language tag reduced to its ISO 639-1 base ("ro-RO", "rum", "ron" → "ro"). nil when empty/undetermined.
    nonisolated static func normLang(_ s: String?) -> String? {
        guard let s else { return nil }
        let base = s.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
        if base.isEmpty || base == "und" || base == "zxx" || base == "mis" || base == "mul" { return nil }
        return iso639[base] ?? base
    }

    /// The rendition in the stream's subtitle group for a track. In order: same name as the DisplayTitle (Jellyfin
    /// names them so); among the renditions of the track's language (ISO codes normalised), the only one, else
    /// the one whose name contains the track's title (or the other way round); a name match on any rendition;
    /// then, when the stream was asked for this track (`requested`), the only rendition there is, else the
    /// playlist's DEFAULT one (`defaultIndex`; Emby marks the requested track so). nil: not in this stream.
    nonisolated static func pickLegible(_ options: [(name: String, lang: String?)], title: String?, lang: String?,
                                        requested: Bool = false, trackTitle: String? = nil,
                                        defaultIndex: Int? = nil, usable: [Bool]? = nil) -> Int? {
        // Closed captions in the video and macOS's own transcribed captions are not the server's subtitle
        // tracks: never take them for one (owner: Emby left Romanian SUBRIP out, Cove picked 'CC' and showed nothing)
        let ok = { (i: Int) -> Bool in usable.map { $0.indices.contains(i) ? $0[i] : true } ?? true }
        let options = options.enumerated().map { ok($0.offset) ? $0.element : (name: "", lang: Optional<String>.none) }
        let real = options.indices.filter(ok)
        if let title, let i = options.firstIndex(where: { $0.name == title }) { return i }
        let titles = [trackTitle, title].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func named(_ i: Int) -> Bool {
            let n = options[i].name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return false }
            return titles.contains { $0.contains(n) || n.contains($0) }
        }
        if let want = normLang(lang) {
            let same = options.indices.filter { normLang(options[$0].lang) == want }
            if same.count == 1 { return same[0] }
            let byName = same.filter(named)
            if byName.count == 1 { return byName[0] }
            if same.count > 1, requested, let d = defaultIndex, same.contains(d) { return d }
        }
        let byName = options.indices.filter(named)
        if byName.count == 1 { return byName[0] }
        guard requested else { return nil }
        if real.count == 1, options.count == 1 { return real[0] }
        if let d = defaultIndex, real.contains(d) { return d }
        return nil
    }

    enum InStreamSwitch: Equatable { case select, restart, extract }

    /// Switching to an embedded text track during playback: pick its rendition when the playing stream has it,
    /// else restart the HLS stream with that track, else (Direct Play, or the server showed no renditions
    /// before) download it.
    nonisolated static func inStreamSwitch(haveOption: Bool, hls: Bool, unsupported: Bool) -> InStreamSwitch {
        if haveOption { return .select }
        if hls && !unsupported { return .restart }
        return .extract
    }

    /// Whether each rendition is one of the server's subtitle tracks (not closed captions carried in the video,
    /// not macOS's automatically transcribed captions).
    var legibleUsable: [Bool] {
        (legibleGroup?.options ?? []).map { o in
            if o.mediaType == .closedCaption { return false }
            if o.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility),
               o.displayName.localizedCaseInsensitiveContains("transcribed") { return false }
            return !o.displayName.localizedCaseInsensitiveContains("transcribed") && o.displayName != "CC"
        }
    }

    var legibleOptions: [(name: String, lang: String?)] {
        (legibleGroup?.options ?? []).map { o in
            let title = AVMetadataItem.metadataItems(from: o.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
                .first?.stringValue
            let name = o.displayName.isEmpty ? (title ?? "") : o.displayName
            return (name, o.extendedLanguageTag ?? o.locale?.identifier)
        }
    }

    /// Hooks the legible output to a new HLS item that carries track `idx`.
    func attachInStream(_ item: AVPlayerItem, _ idx: Int, gen: Int) {
        inStreamSub = idx; inStreamDecided = false; inStreamFirst = true; inStreamT0 = Date()
        legible = LegibleSubtitles(item) { [weak self] text in
            guard let self, gen == self.startGen, self.inStreamSub != nil else { return }
            if self.inStreamFirst, !text.isEmpty {
                self.inStreamFirst = false
                self.dlog("subs: in-stream (HLS) first caption after \(String(format: "%.1f", Date().timeIntervalSince(self.inStreamT0)))s")
            }
            if text != self.caption { self.caption = text }
        }
    }

    /// Once the item is ready: select the track's rendition, or fall back to downloading it within ~4 s.
    func selectInStream(_ item: AVPlayerItem, gen: Int) {
        guard let idx = inStreamSub, !inStreamDecided else { return }
        Task { @MainActor [weak self] in
            let g = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard let self, gen == self.startGen, self.inStreamSub == idx, !self.inStreamDecided else { return }
            self.inStreamDecided = true
            self.legibleGroup = g
            let st = self.streams.first { $0.Index == idx }
            if let g {
                let names = self.legibleOptions.map { "'\($0.name)' [\($0.lang ?? "-")]" }.joined(separator: ", ")
                self.dlog("subs: HLS renditions for track \(idx) (\(st?.Language ?? "-"), '\(st?.DisplayTitle ?? "")'): \(names.isEmpty ? "none" : names)")
            }
            if let g, let k = Self.pickLegible(self.legibleOptions, title: st?.DisplayTitle, lang: st?.Language, requested: true,
                                               trackTitle: st?.Title, defaultIndex: g.defaultOption.flatMap { g.options.firstIndex(of: $0) },
                                               usable: self.legibleUsable) {
                item.select(g.options[k], in: g)
                self.dlog("subs: in-stream (HLS) track \(idx): \(g.options.count) rendition(s), selected '\(g.options[k].displayName)'")
            } else {
                self.inStreamFallback(idx, why: g == nil ? "no subtitle group in the stream" : "track not among \(g?.options.count ?? 0) rendition(s)")
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, gen == self.startGen, self.inStreamSub == idx, !self.inStreamDecided else { return }
            self.inStreamDecided = true
            self.inStreamFallback(idx, why: "no subtitle group after 4 s")
        }
    }

    /// The stream didn't bring the track: download it the old way (and don't try in-stream again for this film).
    private func inStreamFallback(_ idx: Int, why: String) {
        dlog("subs: in-stream unavailable (\(why)) → extraction")
        inStreamUnsupported = true
        stopInStream()
        if let emby = embyRef, let r = currentRequest { loadCues(emby, r.item.id, r.sourceId, idx, from: now) }
    }

    /// Stops reading captions from the stream (another path takes over, or subtitles off).
    func stopInStream() {
        if let g = legibleGroup { player?.currentItem?.select(nil, in: g) }
        legible?.detach()
        legible = nil; inStreamSub = nil
        caption = ""
    }

    /// Switches between embedded text tracks while one plays in-stream. Returns false when it couldn't.
    func switchInStream(_ idx: Int) -> Bool {
        guard let g = legibleGroup, let item = player?.currentItem else { return false }
        let st = streams.first { $0.Index == idx }
        guard let k = Self.pickLegible(legibleOptions, title: st?.DisplayTitle, lang: st?.Language, trackTitle: st?.Title,
                                       usable: legibleUsable) else { return false }
        if legible == nil { attachInStream(item, idx, gen: startGen) }
        inStreamSub = idx; inStreamDecided = true; caption = ""
        item.select(g.options[k], in: g)
        dlog("subs: in-stream (HLS) switched to track \(idx) '\(g.options[k].displayName)'")
        return true
    }
}

/// Reads the selected legible track's text and hides AVPlayer's own subtitle drawing.
@MainActor
final class LegibleSubtitles: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
    private weak var item: AVPlayerItem?
    private let onText: (String) -> Void

    init(_ item: AVPlayerItem, onText: @escaping (String) -> Void) {
        self.item = item
        self.onText = onText
        super.init()
        output.suppressesPlayerRendering = true
        output.advanceIntervalForDelegateInvocation = 0
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    func detach() {
        output.setDelegate(nil, queue: nil)
        item?.remove(output)
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let text = LegibleText.plain(strings)
        MainActor.assumeIsolated { onText(text) }
    }
}
