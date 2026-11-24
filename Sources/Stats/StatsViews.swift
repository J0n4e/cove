import SwiftUI

// Shared pieces of the Stats tabs (Glass3D): glass cards, the state cards, the gate that picks between the
// plugin's data, the non-admin fallback and the "plugin missing" card.

extension View {
    /// A Glass3D glass card: faint white fill, thin outline, panel radius.
    func statsCard() -> some View {
        glassCard(padding: Glass3DTokens.Space.xl, radius: Glass3DTokens.Radius.panel)
    }
}

/// Section heading inside the Stats tabs.
struct StatsHeading: View {
    let text: String
    var body: some View {
        Text(text).cvFont(Glass3DTokens.Text.cardTitle + 2, weight: .bold).modifier(Glass3DReadableText())
    }
}

/// A centred glass card with an icon, a sentence and an optional link.
struct StatsStateCard: View {
    let symbol: String
    let title: String
    let message: String
    var link: (label: String, url: URL)? = nil
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        VStack(spacing: Glass3DTokens.Space.m) {
            Image(systemName: symbol).cvFont(34, weight: .light).foregroundColor(Theme.accent(accentName))
            Text(title).cvFont(Glass3DTokens.Text.cardTitle, weight: .bold).modifier(Glass3DReadableText())
                .multilineTextAlignment(.center)
            Text(message).cvFont(Glass3DTokens.Text.meta + 1).foregroundColor(Glass3DTokens.Grey.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if let link {
                Link(destination: link.url) {
                    Text(link.label).cvFont(Glass3DTokens.Text.meta + 1, weight: .semibold)
                        .padding(.horizontal, Glass3DTokens.Space.l).frame(height: 30).classicGlassPill(iconOnly: false)
                }.buttonStyle(.plainHand)
            }
        }
        .frame(maxWidth: 520).statsCard().frame(maxWidth: .infinity).padding(.top, Glass3DTokens.Space.xxl)
    }
}

enum StatsLinks {
    static let emby = URL(string: "https://github.com/faush01/playback_reporting")!
    static let jellyfin = URL(string: "https://github.com/jellyfin/jellyfin-plugin-playbackreporting")!
}

/// Picks what a Stats tab shows: loading, the plugin's data, the non-admin fallback, plugin missing, an error.
struct StatsGate<Content: View>: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject var model: StatsModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch model.availability {
            case nil: SkeletonShimmer().padding(.vertical, Glass3DTokens.Space.xxl)
            case .available: content()
            case .notAdmin: StatsFallbackView(model: model)
            case .pluginMissing:
                StatsStateCard(symbol: "puzzlepiece.extension", title: "Playback Reporting isn't installed",
                               message: "Stats come from the server's Playback Reporting plugin. An admin can install it from Dashboard → Plugins → Catalog; plays are recorded from then on.",
                               link: (label: "About the plugin", url: emby.isJellyfin ? StatsLinks.jellyfin : StatsLinks.emby))
            case .failed:
                StatsStateCard(symbol: "exclamationmark.triangle", title: "Stats couldn't be loaded",
                               message: "The server didn't answer. Open this tab again to retry.")
            }
        }
        .task(id: emby.server + "|" + emby.userId) { await model.start(emby) }
    }
}

/// Non-admins: the plugin only answers admins, so show what the normal API knows (recently played).
struct StatsFallbackView: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject var model: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.l) {
            HStack(spacing: Glass3DTokens.Space.m) {
                Image(systemName: "info.circle").foregroundColor(Glass3DTokens.Grey.secondary)
                Text("Full stats need an admin account on this server (the Playback Reporting plugin only answers admins). Here is what you played recently.")
                    .cvFont(Glass3DTokens.Text.meta + 1).foregroundColor(Glass3DTokens.Grey.secondary)
            }
            .statsCard()
            StatsHeading(text: "Recently played")
            if !model.fallbackLoaded { SkeletonShimmer().padding(.vertical, Glass3DTokens.Space.xl) }
            else if model.fallback.isEmpty {
                StatsStateCard(symbol: "clock", title: "Nothing played yet", message: "Movies and episodes you finish show here.")
            } else {
                LazyVStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    ForEach(model.fallback) { StatsFallbackRow(item: $0) }
                }
            }
        }
        .task { await model.loadFallback(emby) }
    }
}

private struct StatsFallbackRow: View {
    @EnvironmentObject var emby: Emby
    let item: Item
    var body: some View {
        Button { emby.openPage(item) } label: {
            HStack(spacing: Glass3DTokens.Space.m) {
                StatsThumb(id: item.isEpisode ? item.Id : item.posterId, wide: item.isEpisode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.heroTitle).cvFont(Glass3DTokens.Text.cardTitle - 1, weight: .semibold).lineLimit(1)
                        .modifier(Glass3DReadableText())
                    if item.isEpisode {
                        Text("S\(item.ParentIndexNumber ?? 0):E\(item.IndexNumber ?? 0) · \(item.Name)")
                            .cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Glass3DTokens.Space.s).contentShape(Rectangle())
        }.buttonStyle(.plainHand)
    }
}

/// A small poster (2:3) or episode still (16:9).
struct StatsThumb: View {
    @EnvironmentObject var emby: Emby
    let id: String?
    var wide = false
    var height: CGFloat? = nil   // History: 44 pt rows; nil keeps the 54/60 pt default
    var body: some View {
        let h = height ?? (wide ? 54 : 60)
        CachedImage(url: id.flatMap { emby.image($0, width: 200) }) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { Color.white.opacity(0.08) }
        .frame(width: wide ? h * 16 / 9 : h * 2 / 3, height: h)
        .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb, style: .continuous)
            .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.5))
    }
}

/// Opens a play's item; a deleted item (no answer) does nothing.
@MainActor
enum StatsOpen {
    static func item(_ id: String, _ emby: Emby) {
        Task { if let it = await emby.itemRecord(id) { emby.openPage(it) } }
    }
}
