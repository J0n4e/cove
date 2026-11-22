import SwiftUI
import AppKit

/// The detail page's "About" card (Glass3D): pure helpers, tested in AboutCardTests.
enum AboutCard {
    enum Tile: String, CaseIterable, Equatable {
        case lastPlayed, added, genres, studios, file, links
    }

    /// Which tiles have data, in display order (tiles without data are hidden).
    static func tiles(lastPlayed: Date?, added: Date?, genres: [String], studios: [String],
                      hasFile: Bool, links: Int) -> [Tile] {
        var t: [Tile] = []
        if lastPlayed != nil { t.append(.lastPlayed) }
        if added != nil { t.append(.added) }
        if !genres.isEmpty { t.append(.genres) }
        if !studios.isEmpty { t.append(.studios) }
        if hasFile { t.append(.file) }
        if links > 0 { t.append(.links) }
        return t
    }

    /// "MKV · 16.4 GB · 1080p" from what the item already carries (no extra fetching).
    static func fileSummary(container: String?, size: Int64?, videoHeight: Int?, videoWidth: Int? = nil) -> String {
        var parts: [String] = []
        if let c = container?.trimmingCharacters(in: .whitespaces), !c.isEmpty { parts.append(c.uppercased()) }
        if let s = size, s > 0 { parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        if let r = resolution(width: videoWidth, height: videoHeight) { parts.append(r) }
        return parts.joined(separator: " · ")
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

    /// Keeps the start and the end of a long path: "/mnt/filme/Th…/Movie (2016).mkv".
    static func middleTruncate(_ s: String, max: Int) -> String {
        guard max > 1, s.count > max else { return s }
        let keep = max - 1
        let head = keep / 2, tail = keep - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }

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

/// One About tile: small symbol + tiny grey uppercase label + the content.
struct AboutTileView<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).cvFont(10, weight: .semibold)
                Text(label.uppercased()).cvFont(10, weight: .semibold).tracking(0.6)
            }
            .foregroundColor(Glass3DTokens.Grey.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A small still glass chip (genre / studio).
struct AboutChip: View {
    let text: String
    var body: some View {
        Text(text).cvFont(Glass3DTokens.Text.meta, weight: .semibold)
            .foregroundColor(Glass3DTokens.Grey.primary)
            .lineLimit(1)
            .padding(.horizontal, 10).frame(height: 24)
            .modifier(ClassicClearGlass(shape: Capsule(), interactive: false))
    }
}

/// A link pill (IMDb, TMDB…) with the top bar's hover glow; opens the same URL as before.
struct AboutLinkPill: View {
    let name: String
    let url: URL
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 5) {
                Image(systemName: AboutCard.linkIcon(name)).cvFont(10, weight: .semibold)
                Text(AboutCard.linkLabel(name)).cvFont(Glass3DTokens.Text.meta, weight: .semibold)
            }
            .foregroundColor(Glass3DTokens.Grey.primary)
            .padding(.horizontal, 11).frame(height: 26)
            .modifier(SectionHoverGlow(on: true))
            .clipShape(Capsule())
            .modifier(ClassicClearGlass(shape: Capsule()))
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .helpLabel("Open on \(name)")
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
            HStack(spacing: 5) {
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
