// Classic theme: the original Cove screens from v1.9.2 (main), used when Settings → General → Theme is Classic.
// Names carry a "Classic" prefix so they live next to the Apple TV screens.

import IOKit.pwr_mgt
import SwiftUI
import AVKit

// MARK: - Theme

// Background color, accent colors (Theme) and \.appBG are shared with the Apple TV theme (Views.swift).

struct ClassicPillStyle: ViewModifier {
    @AppStorage("accent") private var name = "red"
    let active: Bool
    func body(content: Content) -> some View {
        content.cvFont(12, weight: .medium)
            .padding(.horizontal, Glass3DTokens.Space.l).padding(.vertical, Glass3DTokens.Space.s)
            .classicGlassPill()
    }
}

extension View {
    /// Glass card finish that follows the rounded corners (posters, episode thumbnails, preview card).
    /// `size`: the card's fixed size, if it has one, so the finish is drawn once and reused (see Raster).
    func classicThinBorder(_ radius: CGFloat, size: CGSize? = nil) -> some View { modifier(ClassicGlassCard(radius: radius, size: size)) }
    func classicPill(active: Bool = false) -> some View { modifier(ClassicPillStyle(active: active)) }
    func classicOnAccent() -> some View { modifier(OnAccent()) }
    func classicCircleButton() -> some View {
        self.cvFont(15, weight: .regular).frame(width: 44, height: 44)
            .background(Color.white.opacity(0.14)).clipShape(Circle())
    }
}

extension View {
    /// Black outline around text (four hairline shadows plus a soft one) so it reads on any picture.
    func classicBlackOutline(_ w: CGFloat = 1) -> some View {
        self.shadow(color: .black, radius: 0, x: w, y: 0).shadow(color: .black, radius: 0, x: -w, y: 0)
            .shadow(color: .black, radius: 0, x: 0, y: w).shadow(color: .black, radius: 0, x: 0, y: -w)
            .shadow(color: .black.opacity(0.7), radius: 4)
    }
}

/// Top bar and switch hover: the chosen hover look (Settings) shaped like the selected section's pill, no pill itself.
struct SectionHoverGlow: ViewModifier {
    let on: Bool
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background {
                // The chosen hover look, as the buttons
                ClassicHoverEffect(shown: on && hover)
                    .opacity(on && hover ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
    }
}

/// The player's side panel: dark glass framed like the buttons in the Classic theme, the frosted panel otherwise.
struct PanelSurface: ViewModifier {
    let classic: Bool
    @Environment(\.appBG) private var bg
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.hero, style: .continuous)
        if classic {
            content.background(shape.fill(bg.opacity(0.75))).clipShape(shape)
                .modifier(ClassicClearGlass(shape: shape))
                .g3Shadow(Glass3DTokens.Menu.shadow)   // the level-3 shadow
        } else {
            content.background(.ultraThinMaterial.opacity(0.95)).background(Color(white: 0.15).opacity(0.85))
                .cornerRadius(Glass3DTokens.Radius.panel)
        }
    }
}

/// Classic progress on a card, bottom-right, styled like the glass Play button: a glass ring (dark see-through
/// track lit from the top, light-catching rims) and the watched part in see-through accent with a shine and a glow.
/// Drawn by hand (no system glass), so a row of cards stays smooth to scroll.
struct ClassicProgressCircle: View {
    let progress: Double   // 0...1
    var size: CGFloat = 26
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.displayScale) private var scale
    var body: some View {
        // Drawn once per whole percent, size and accent (see Raster): it's eight layers with glowing shadows
        let pct = Int((min(1, max(0.03, progress)) * 100).rounded())
        Raster.view("ring\(pct)|\(size)|\(accentName)", scale: scale, pad: 12) { drawing(CGFloat(pct) / 100) }
    }
    @ViewBuilder func drawing(_ p: CGFloat) -> some View {
        let accent = Theme.accent(accentName)
        let w: CGFloat = 5
        ZStack {
            // glass track
            Circle().stroke(Color.black.opacity(0.4), lineWidth: w)
            Circle().stroke(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                            lineWidth: w)
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5).frame(width: size + w, height: size + w)
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5).frame(width: size - w, height: size - w)
            // watched part
            Group {
                Circle().trim(from: 0, to: p)
                    .stroke(accent.opacity(0.42), style: StrokeStyle(lineWidth: w - 1, lineCap: .round))
                    .shadow(color: accent.opacity(0.9), radius: 4)
                    .shadow(color: accent.opacity(0.5), radius: 8)
                Circle().trim(from: 0, to: p)
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: size + 1.5, height: size + 1.5)
            }.rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .frame(width: size + w, height: size + w)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

struct ClassicPosterCard: View {
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    let item: Item
    @State private var hover = false
    // Settings → Libraries → Poster labels
    @AppStorage("posterShowTitle") private var showTitle = true
    @AppStorage("posterShowYear") private var showYear = true
    @AppStorage("posterLabelAlign") private var labelAlign = "center"
    var centered: Bool { labelAlign == "center" }
    var body: some View {
        let played = emby.isPlayed(item)
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                ZStack(alignment: .topTrailing) {
                    CachedImage(url: emby.image(item.posterId, width: 360)) { p in
                        p.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack { Color(white: 0.15); Text(item.Name).cvFont(10, weight: .regular).padding(Glass3DTokens.Space.s) }
                    }
                    .frame(width: 150, height: 225).clipped()
                    .watchedDim(played)
                }
                .overlay {
                    // the Resume ring (owner: no bottom progress lines)
                    if !played { ResumeRingMark(fraction: emby.progressFraction(item)) }
                }
                .cornerRadius(Glass3DTokens.Radius.field)
                .modifier(ClassicLightCard(radius: Glass3DTokens.Radius.field, hover: hover, accent: Theme.accent(accentName), size: CGSize(width: 150, height: 225)))
                // Soft light following the pointer on the hovered poster, under the badges (owner: no tilt)
                .posterShine(hover: hover, radius: Glass3DTokens.Radius.field)
                // ♡ ★ ✓ as on the library grid: after the clip and the glass edge, so their soft shadow isn't cut off
                // and the lit hover edge / sheen never wash over their dark glass (the grid masks them out too)
                .overlay { PosterBadgesOverlay(item: item, hover: hover).environment(\.posterBadgeHalo, hover) }
                .modifier(HoverLift(hover: hover))
                if showTitle || showYear {
                    VStack(alignment: centered ? .center : .leading, spacing: 2) {
                        if showTitle { Text(item.Name).cvFont(12, weight: .regular).lineLimit(1) }
                        if showYear { Text(item.yearText).cvFont(10, weight: .regular).foregroundColor(.secondary) }
                    }
                    .multilineTextAlignment(centered ? .center : .leading)
                    .frame(width: 150, alignment: centered ? .center : .leading)
                }
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
            .scrollHover($hover)   // not while scrolling past
            .zIndex(hover ? 1 : 0)
        }.buttonStyle(.plainHand)
    }
}

extension View {
    /// `play`: size of the play button shown on hover (0 = none).
    func classicHoverLift(play: CGFloat = 0, playTip: String? = nil, onPlay: (() -> Void)? = nil) -> some View {
        modifier(SelfHoverLift(play: play, onPlay: onPlay, playTip: playTip))
    }
}

/// A page's name at the top left (a library, Favorites): its icon and name in 3D lettering.
struct ClassicPageTitle: View {
    let text: String
    var icon: String? = nil
    static func icon(_ kind: String?) -> String {
        switch kind {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "boxsets": return "square.stack"
        case "music": return "music.note"
        case "homevideos": return "video"
        default: return "folder"
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Text3D(image: Image(systemName: icon), size: 18) }
            Text3D(text: text, size: 22)
        }
    }
}

/// Lettering with depth: glossy white (light on top, shade at the bottom), grey layers stepped down-right under
/// it as its thickness, and a soft shadow.
struct Text3D: View {
    var text: String = ""
    var image: Image? = nil
    var size: CGFloat
    /// The grey thickness under the letters (off: just the glossy face and its shadow).
    var thick = false
    var weight: Font.Weight = .heavy
    @ViewBuilder var glyph: some View {
        if let image { image.cvFont(size * 0.85, weight: .bold) } else { Text(text).cvFont(size, weight: weight) }
    }
    var body: some View {
        let depth = max(2, Int(size / 6))
        ZStack {
            // Thickness: dark layers stepped down-right
            if thick { ForEach(1...depth, id: \.self) { i in
                glyph.foregroundColor(Color(white: 0.5 - Double(i) * 0.05))   // grey, so it shows on a black page
                    .offset(x: CGFloat(i) * 0.7, y: CGFloat(i) * 1.0)
            } }
            glyph.foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.92), Color(white: 0.62)],
                                                 startPoint: .top, endPoint: .bottom))
        }
        .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 3)
    }
}
