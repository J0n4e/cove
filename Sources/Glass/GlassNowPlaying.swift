import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

// MARK: - Now Playing (active sessions on the server)

struct NowPlayingView: View {
    @Environment(\.classicGlass) private var classic
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @State private var sessions: [ActiveSession] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Now Playing").coveFont { s in classic ? .cv(TextScale.scaledSize(base: 22, scale: s), weight: .bold) : .title.bold() }
                    if !sessions.isEmpty { Text("\(sessions.count) active").foregroundColor(.secondary) }
                }
                if !loaded { Spinner().frame(maxWidth: .infinity).padding(60) }
                else if sessions.isEmpty && classic {
                    ClassicEmptyState(symbol: "play.slash", title: "Nothing is playing right now",
                                      message: "Playback on any device signed in to this server shows here.")
                } else if sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "play.slash").coveFont(size: 40).foregroundColor(.secondary)
                        Text("Nothing is playing right now").font(.headline)
                    }.frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(sessions) { SessionCard(s: $0) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .task {
            while !Task.isCancelled {
                sessions = await emby.nowPlaying()
                loaded = true
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct SessionCard: View {
    @Environment(\.classicGlass) private var classic   // Classic theme: glass card
    @EnvironmentObject var emby: Emby
    let s: ActiveSession

    func clock(_ ticks: Int64?) -> String { timeString(Double(ticks ?? 0) / 10_000_000) }

    var icon: String {
        let c = (s.Client ?? "").lowercased() + " " + (s.DeviceName ?? "").lowercased()
        if c.contains("cove") || c.contains("embyflix") || c.contains("mac") { return "desktopcomputer" }
        if c.contains("web") || c.contains("chrome") || c.contains("firefox") || c.contains("safari") { return "globe" }
        if c.contains("iphone") || c.contains("ios") || c.contains("android") { return "iphone" }
        if c.contains("tv") || c.contains("roku") || c.contains("kodi") { return "tv" }
        return "display"
    }

    var body: some View {
        let it = s.NowPlayingItem!
        let pos = Double(s.PlayState?.PositionTicks ?? 0), dur = Double(it.RunTimeTicks ?? 0)
        let transcoding = s.PlayState?.PlayMethod == "Transcode"
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                CachedImage(url: emby.image(it.SeriesId ?? it.Id, width: 160)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 64, height: 96).clipped().cornerRadius(classic ? 8 : 4)
                .modifier(PersonPhotoFrame(classic: classic, radius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(it.SeriesName ?? it.Name).coveFont { s in classic ? .cv(TextScale.scaledSize(base: 13, scale: s), weight: .bold) : .headline }.lineLimit(1)
                    if it.SeriesName != nil {
                        Text("S\(it.ParentIndexNumber ?? 0):E\(it.IndexNumber ?? 0) - \(it.Name)")
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if s.PlayState?.IsPaused == true { Image(systemName: "pause.fill").font(.caption) }
                        Text("\(clock(s.PlayState?.PositionTicks)) / \(clock(it.RunTimeTicks))").monospacedDigit()
                    }.foregroundColor(.secondary)
                    Text(transcoding ? "Transcode" : "Direct play")
                        .coveFont { s in classic ? .cv(TextScale.scaledSize(base: 10, scale: s), weight: .semibold) : .caption.weight(.semibold) }
                        .padding(.horizontal, classic ? 10 : 7).padding(.vertical, classic ? 3 : 2)
                        .background(Capsule().fill(transcoding ? Color.orange.opacity(0.25) : Color.green.opacity(0.25)))
                        .overlay { if classic { Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5) } }
                        .tip(s.TranscodingInfo?.TranscodeReasons?.joined(separator: ", ") ?? "")
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            // Progress: watched position, plus how far the server has transcoded
            if classic {
                // Glass3D: the glass line, as on the cards
                ClassicSessionLine(watched: dur > 0 ? min(1, pos / dur) : 0,
                                   converted: (s.TranscodingInfo?.CompletionPercentage).map { min(1, $0 / 100) })
                    .padding(.horizontal, 12)
            } else {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.15))
                    if let c = s.TranscodingInfo?.CompletionPercentage {
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: g.size.width * min(1, c / 100))
                    }
                    Rectangle().fill(classic ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.accentColor))
                        .opacity(classic ? 0.7 : 1)
                        .frame(width: dur > 0 ? g.size.width * min(1, pos / dur) : 0)
                }
            }.frame(height: 4)
            }
            HStack(spacing: 12) {
                Image(systemName: icon).coveFont(size: 26).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.Client ?? "Unknown") \(s.ApplicationVersion ?? "")").font(.callout.weight(.semibold))
                    Text([s.DeviceName, s.UserName].compactMap { $0 }.joined(separator: " · ")).foregroundColor(.secondary)
                    if let ip = s.RemoteEndPoint { Text(ip).font(.caption).foregroundColor(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .modifier(SessionSurface(classic: classic))
    }
}

/// A Now Playing card: a glass card in the Classic theme, a faint grey box otherwise.
struct SessionSurface: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            content.background(shape.fill(Color.black.opacity(0.3))).background(ClassicGlassBacking(shape: shape)).clipShape(shape)
        } else {
            content.background(Color.white.opacity(0.06)).cornerRadius(10)
        }
    }
}

/// Glass3D Now Playing progress: a slim glass capsule, how far the server converted in faint white, the watched part
/// in see-through accent with a glow.
struct ClassicSessionLine: View {
    let watched: Double
    let converted: Double?
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let accent = Theme.accent(accentName)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                ClassicGlassBacking(shape: Capsule())
                if let c = converted { Capsule().fill(Color.white.opacity(0.18)).frame(width: max(6, g.size.width * c)) }
                Capsule().fill(accent.opacity(0.5))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center)))
                    .frame(width: max(6, g.size.width * watched))
                    .shadow(color: accent.opacity(0.8), radius: 4)
            }
        }
        .frame(height: 6)
    }
}
