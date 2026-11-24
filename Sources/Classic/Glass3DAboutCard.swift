import SwiftUI
import AppKit

/// The detail page's "About" card (Glass3D): pure helpers, tested in AboutCardTests.
/// Layout (owner choices): ONE key-facts line on top, then a plain two-column list (grey labels, white values),
/// the links as the only pills, and the file path hidden behind a "Show file path" text link.
enum AboutCard {
    // MARK: Width

    /// The cast row's spacing between actor cards (ArrowScrollRow's default).
    static let castSpacing: CGFloat = 18
    /// About as wide as 4 cast cards in the cast row (cards + the 3 gaps between them).
    static func cardWidth(castCardWidth: CGFloat, spacing: CGFloat = castSpacing, cards: Int = 4) -> CGFloat {
        CGFloat(cards) * castCardWidth + CGFloat(max(cards - 1, 0)) * spacing
    }

    /// The file path stays hidden until "Show file path" is clicked.
    static let pathShownByDefault = false

    // MARK: Key facts line

    struct KeyFact: Equatable, Hashable {
        let text: String
        /// Small monochrome SF Symbol for well-known formats (4K, Dolby Vision, HDR10/HDR10+, Dolby Atmos, DTS:X)
        let icon: String?
    }

    /// Monochrome glyph for a well-known format; nil for everything else (text only).
    static func icon(forFact text: String) -> String? {
        switch text {
        case "4K": return "4k.tv"
        case "Dolby Vision": return "sparkles.tv"
        case "HDR10", "HDR10+": return "sun.max"
        case "Dolby Atmos": return "hifispeaker.2"
        case "DTS:X": return "speaker.wave.3"
        default: return nil
        }
    }

    /// '4K · HDR10 · Dolby Atmos 7.1 · 2h 14m · 58 GB' — only the facts that exist, in this order.
    static func keyFacts(video: MStream?, audio: [MStream], runTimeTicks: Int64?, size: Int64?) -> [KeyFact] {
        var out: [String] = []
        if let r = resolution(width: video?.Width, height: video?.Height) { out.append(r) }
        if let h = hdr(video?.VideoRange) { out.append(h) }
        if let a = audio.first(where: { $0.IsDefault == true }) ?? audio.first {
            let parts = [audioFormat(a), channels(a.ChannelLayout)].compactMap { $0 }
            if !parts.isEmpty { out.append(parts.joined(separator: " ")) }
        }
        if let rt = runtime(runTimeTicks) { out.append(rt) }
        if let s = size, s > 0 { out.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        return out.map { t in
            // The headline audio fact keeps its channels ("Dolby Atmos 7.1"); its icon follows the format name
            let base = ["Dolby Atmos", "DTS:X"].first { t.hasPrefix($0) } ?? t
            return KeyFact(text: t, icon: icon(forFact: base))
        }
    }

    /// "4K" / "1080p" / "720p" / "576p"…; width breaks ties for cropped (scope) films.
    static func resolution(width: Int?, height: Int?) -> String? {
        let h = height ?? 0, w = width ?? 0
        guard h > 0 || w > 0 else { return nil }
        if w >= 3200 || h >= 2000 { return "4K" }
        if w >= 1800 || h >= 1000 { return "1080p" }
        if w >= 1200 || h >= 700 { return "720p" }
        return "\(h)p"
    }

    /// Server VideoRange → "Dolby Vision" / "HDR10+" / "HDR10" / "HLG" / "HDR"; SDR and unknown → nil.
    static func hdr(_ range: String?) -> String? {
        guard let r = range?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty, r != "sdr" else { return nil }
        let n = r.replacingOccurrences(of: " ", with: "")
        if n.contains("dolbyvision") || n.contains("dovi") { return "Dolby Vision" }
        if n.contains("hdr10+") || n.contains("hdr10plus") { return "HDR10+" }
        if n.contains("hdr10") { return "HDR10" }
        if n.contains("hlg") { return "HLG" }
        if n.contains("hdr") { return "HDR" }
        return nil
    }

    /// "2h 14m" / "48m".
    static func runtime(_ ticks: Int64?) -> String? {
        guard let t = ticks, t > 0 else { return nil }
        let minutes = Int((Double(t) / 10_000_000 / 60).rounded())
        guard minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }

    /// Audio format name: object-based formats first (Dolby Atmos, DTS:X), then the codec.
    static func audioFormat(_ a: MStream) -> String? {
        let hay = [a.DisplayTitle, a.Title, a.Profile].compactMap { $0?.lowercased() }.joined(separator: " ")
        if hay.contains("atmos") { return "Dolby Atmos" }
        if hay.contains("dts:x") || hay.contains("dts-x") || hay.contains("dtsx") { return "DTS:X" }
        return codecName(audio: a.Codec, profile: a.Profile)
    }

    static func codecName(audio codec: String?, profile: String? = nil) -> String? {
        guard let c = codec?.trimmingCharacters(in: .whitespaces).lowercased(), !c.isEmpty else { return nil }
        switch c {
        case "truehd": return "Dolby TrueHD"
        case "eac3": return "Dolby Digital+"
        case "ac3": return "Dolby Digital"
        case "dts":
            let p = profile?.lowercased() ?? ""
            if p.contains("ma") { return "DTS-HD MA" }
            if p.contains("hra") || p.contains("hr") { return "DTS-HD HRA" }
            return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "vorbis": return "Vorbis"
        default: return c.uppercased()
        }
    }

    static func codecName(video codec: String?) -> String? {
        guard let c = codec?.trimmingCharacters(in: .whitespaces).lowercased(), !c.isEmpty else { return nil }
        switch c {
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "mpeg2video": return "MPEG-2"
        default: return c.uppercased()
        }
    }

    /// "5.1(side)" → "5.1", "stereo" → "Stereo".
    static func channels(_ layout: String?) -> String? {
        guard var l = layout?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return nil }
        if let p = l.firstIndex(of: "(") { l = String(l[..<p]) }
        return l.prefix(1).uppercased() + l.dropFirst()
    }

    /// "62 Mbps" / "6.4 Mbps" / "640 kbps".
    static func bitrate(_ bps: Int?) -> String? {
        guard let b = bps, b > 0 else { return nil }
        let mb = Double(b) / 1_000_000
        if mb >= 10 { return "\(Int(mb.rounded())) Mbps" }
        if mb >= 1 { return String(format: "%.1f Mbps", mb) }
        return "\(Int((Double(b) / 1000).rounded())) kbps"
    }

    static func language(_ code: String?) -> String {
        guard let c = code?.trimmingCharacters(in: .whitespaces), !c.isEmpty, c.lowercased() != "und" else { return "Unknown language" }
        return Locale(identifier: "en").localizedString(forLanguageCode: c) ?? c
    }

    // MARK: Two-column list

    struct Row: Equatable, Identifiable {
        let label: String
        let lines: [String]
        var id: String { label }
    }

    /// "HEVC · 10-bit · 3840×1600 · 62 Mbps".
    static func videoLine(_ v: MStream) -> String? {
        var p: [String] = []
        if let c = codecName(video: v.Codec) { p.append(c) }
        if let d = v.BitDepth, d > 0 { p.append("\(d)-bit") }
        if let w = v.Width, let h = v.Height, w > 0, h > 0 { p.append("\(w)×\(h)") }
        if let b = bitrate(v.BitRate) { p.append(b) }
        return p.isEmpty ? nil : p.joined(separator: " · ")
    }

    /// "English · Dolby TrueHD · 7.1 · Default".
    static func audioLine(_ a: MStream) -> String {
        var p = [language(a.Language)]
        if let f = audioFormat(a) { p.append(f) }
        if let c = channels(a.ChannelLayout) { p.append(c) }
        if a.IsDefault == true { p.append("Default") }
        return p.joined(separator: " · ")
    }

    /// "English (Forced)", "English (SDH)", "Romanian".
    static func subtitleLabel(_ s: MStream) -> String {
        let hay = [s.DisplayTitle, s.Title].compactMap { $0?.lowercased() }.joined(separator: " ")
        var marks: [String] = []
        if s.IsForced == true || hay.contains("forced") { marks.append("Forced") }
        if s.IsHearingImpaired == true || hay.contains("sdh") || hay.contains("hearing impaired") { marks.append("SDH") }
        let lang = language(s.Language)
        return marks.isEmpty ? lang : "\(lang) (\(marks.joined(separator: ", ")))"
    }

    /// All subtitle tracks: one comma-separated line when short, else one per line.
    static func subtitleLines(_ subs: [MStream], maxLine: Int = 48) -> [String] {
        let labels = subs.map(subtitleLabel)
        guard !labels.isEmpty else { return [] }
        let joined = labels.joined(separator: ", ")
        return joined.count <= maxLine ? [joined] : labels
    }

    /// "MKV · 58 GB · Added 12 Mar 2025".
    static func fileLine(container: String?, size: Int64?, added: Date?) -> String? {
        var p: [String] = []
        if let c = container?.trimmingCharacters(in: .whitespaces), !c.isEmpty { p.append(c.uppercased()) }
        if let s = size, s > 0 { p.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        if let d = added { p.append("Added " + d.formatted(date: .abbreviated, time: .omitted)) }
        return p.isEmpty ? nil : p.joined(separator: " · ")
    }

    /// The list rows in order: Video, Audio (every track), Subtitles (every track), File, then Genres / Studios.
    static func rows(streams: [MStream], container: String?, size: Int64?, added: Date?, hasFile: Bool,
                     genres: [String] = [], studios: [String] = []) -> [Row] {
        var r: [Row] = []
        if let v = streams.first(where: { $0.`Type` == "Video" }), let l = videoLine(v) { r.append(Row(label: "Video", lines: [l])) }
        let audio = streams.filter { $0.`Type` == "Audio" }
        if !audio.isEmpty { r.append(Row(label: "Audio", lines: audio.map(audioLine))) }
        let subs = subtitleLines(streams.filter { $0.`Type` == "Subtitle" })
        if !subs.isEmpty { r.append(Row(label: "Subtitles", lines: subs)) }
        if hasFile {
            if let f = fileLine(container: container, size: size, added: added) { r.append(Row(label: "File", lines: [f])) }
        } else if let d = added {
            r.append(Row(label: "Added", lines: [d.formatted(date: .abbreviated, time: .omitted)]))
        }
        if !genres.isEmpty { r.append(Row(label: "Genres", lines: [genres.joined(separator: ", ")])) }
        if !studios.isEmpty { r.append(Row(label: "Studios", lines: [studios.joined(separator: ", ")])) }
        return r
    }

    // MARK: Links

    /// SF symbol for a known link provider.
    static func linkIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "imdb": return "film"
        case "themoviedb", "tmdb": return "popcorn"
        case "thetvdb", "tvdb": return "tv"
        case "trakt": return "checkmark.circle"
        default: return "link"
        }
    }

    /// Short label for a link pill ("TheMovieDb" → "TMDB").
    static func linkLabel(_ name: String) -> String {
        switch name.lowercased() {
        case "imdb": return "IMDb"
        case "themoviedb", "tmdb": return "TMDB"
        case "thetvdb", "tvdb": return "TVDB"
        case "trakt": return "Trakt"
        default: return name
        }
    }
}

/// The card's content (inside the one outer GlassCard; no inner boxes).
struct AboutCardContent: View {
    let facts: [AboutCard.KeyFact]
    let rows: [AboutCard.Row]
    let links: [(String, URL)]
    let path: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
            if !facts.isEmpty { AboutKeyFactsLine(facts: facts) }
            if !rows.isEmpty { AboutRowsList(rows: rows) }
            if !links.isEmpty {
                FlowLayout(hSpacing: Glass3DTokens.Space.s, vSpacing: Glass3DTokens.Space.s) {
                    ForEach(Array(links.enumerated()), id: \.offset) { AboutLinkPill(name: $0.element.0, url: $0.element.1) }
                }
            }
            if let p = path, !p.isEmpty { AboutPathReveal(path: p) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two columns: grey labels left, white values right (one line per track).
struct AboutRowsList: View {
    let rows: [AboutCard.Row]
    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Glass3DTokens.Space.l, verticalSpacing: Glass3DTokens.Space.s) {
            ForEach(rows) { r in
                GridRow {
                    Text(r.label).cvFont(Glass3DTokens.Text.meta, weight: .semibold)
                        .foregroundColor(Glass3DTokens.Grey.secondary)
                        .gridColumnAlignment(.leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(r.lines.enumerated()), id: \.offset) { l in
                            Text(l.element).cvFont(13)
                                .foregroundColor(.white)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// '4K · HDR10 · Dolby Atmos 7.1 · 2h 14m · 58 GB' with small monochrome glyphs; wraps when narrow.
struct AboutKeyFactsLine: View {
    let facts: [AboutCard.KeyFact]
    var body: some View {
        FlowLayout(hSpacing: Glass3DTokens.Space.s, vSpacing: Glass3DTokens.Space.xs) {
            ForEach(Array(facts.enumerated()), id: \.offset) { e in
                AboutKeyFactView(fact: e.element, leadingDot: e.offset > 0)
            }
        }
    }
}

struct AboutKeyFactView: View {
    let fact: AboutCard.KeyFact
    let leadingDot: Bool
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.xs) {
            if leadingDot {
                Text("·").cvFont(13, weight: .semibold).foregroundColor(Glass3DTokens.Grey.tertiary).accessibilityHidden(true)
            }
            if let s = fact.icon {
                Image(systemName: s).cvFont(11, weight: .semibold)
                    .foregroundColor(Glass3DTokens.Grey.secondary)
                    .accessibilityHidden(true)
            }
            Text(fact.text).cvFont(13, weight: .semibold).foregroundColor(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fact.text)
    }
}

/// A link pill (IMDb, TMDB…) with the top bar's hover glow; opens the same URL as before.
struct AboutLinkPill: View {
    let name: String
    let url: URL
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: Glass3DTokens.Space.xs) {
                Image(systemName: AboutCard.linkIcon(name)).cvFont(10, weight: .semibold)
                Text(AboutCard.linkLabel(name)).cvFont(Glass3DTokens.Text.meta, weight: .semibold)
            }
            .foregroundColor(Glass3DTokens.Grey.primary)
            .padding(.horizontal, Glass3DTokens.Space.m).frame(height: 26)
            .modifier(SectionHoverGlow(on: true))
            .clipShape(Capsule())
            .modifier(ClassicClearGlass(shape: Capsule()))
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .helpLabel("Open on \(name)")
    }
}

/// "Show file path" text link; when open it shows the click-to-copy path and "Hide file path".
struct AboutPathReveal: View {
    let path: String
    @State private var shown = AboutCard.pathShownByDefault
    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
            Button {
                withAnimation(Glass3DTokens.Motion.fast) { shown.toggle() }
            } label: {
                Text(shown ? "Hide file path" : "Show file path").cvFont(Glass3DTokens.Text.meta, weight: .semibold)
                    .foregroundColor(Glass3DTokens.Grey.secondary)
                    .underline()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainHand)
            if shown { AboutPathLine(path: path).transition(.opacity) }
        }
    }
}

/// The file path: one monospaced grey line, middle-truncated; click copies, full path in the tooltip.
struct AboutPathLine: View {
    let path: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            withAnimation(Glass3DTokens.Motion.fast) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Glass3DTokens.Motion.fast) { copied = false } }
        } label: {
            HStack(spacing: Glass3DTokens.Space.xs) {
                Text(path).cvFont(11) { $0.monospaced() }
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc").cvFont(9, weight: .semibold)
                    .opacity(copied ? 1 : 0.7)
            }
            .foregroundColor(Glass3DTokens.Grey.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .helpLabel(copied ? "Copied" : "\(path)\nClick to copy")
    }
}
