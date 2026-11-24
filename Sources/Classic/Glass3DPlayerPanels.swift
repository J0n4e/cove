import AVFoundation
import SwiftUI
import AppKit

// Glass3D player, polish round 3: the subtitles panel, the bar's menus, the shared panel heading and rows (the
// Episodes panel's style), the right-hand Liquid Glass control bar, speed chips, dropdown fields and the episode
// progress line. Kept out of ClassicPlayer.swift, whose body is at the type checker's limit.

// MARK: - Track labels (pure, tested)

enum Glass3DTrackLabel {
    /// A friendly codec name: SUBRIP → SubRip, PGSSUB → PGS, DVDSUB → VobSub…; anything else capitalised.
    static func codecName(_ codec: String?) -> String? {
        guard let c = codec?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        switch c.uppercased() {
        case "SUBRIP", "SRT": return "SubRip"
        case "ASS": return "ASS"
        case "SSA": return "SSA"
        case "PGSSUB", "PGS", "HDMV_PGS_SUBTITLE": return "PGS"
        case "DVDSUB", "DVD_SUBTITLE", "VOBSUB": return "VobSub"
        case "WEBVTT", "VTT": return "WebVTT"
        case "MOV_TEXT": return "Text"
        case "AAC": return "AAC"
        case "AC3": return "AC3"
        case "EAC3": return "E-AC3"
        case "DTS": return "DTS"
        case "TRUEHD": return "TrueHD"
        case "FLAC": return "FLAC"
        case "MP3": return "MP3"
        case "OPUS": return "Opus"
        default: return c.prefix(1).uppercased() + c.dropFirst().lowercased()
        }
    }

    /// Words that don't name a track on their own.
    private static let filler: Set<String> = ["UND", "UNDEFINED", "UNKNOWN", "DEFAULT", "EXTERNAL"]

    /// The track's real name, or nil when it has none: its Title, else its DisplayTitle without the codec
    /// ("English (SUBRIP)" → "English", "Und - SUBRIP" / "(SUBRIP)" → nil).
    static func name(title: String?, displayTitle: String?, codec: String?) -> String? {
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        guard let d = displayTitle, !d.isEmpty else { return nil }
        var codecs = filler
        if let c = codec?.uppercased() { codecs.insert(c) }
        if let c = codecName(codec)?.uppercased() { codecs.insert(c) }
        // Parenthesised parts that are only a codec or filler go
        var s = ""
        var i = d.startIndex
        while i < d.endIndex {
            if d[i] == "(", let close = d[i...].firstIndex(of: ")") {
                let inner = d[d.index(after: i)..<close].trimmingCharacters(in: .whitespaces).uppercased()
                if !codecs.contains(inner) { s += d[i...close] }
                i = d.index(after: close)
            } else {
                s.append(d[i]); i = d.index(after: i)
            }
        }
        let parts = s.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !codecs.contains($0.uppercased()) }
        let out = parts.joined(separator: " - ")
        return out.isEmpty ? nil : out
    }

    /// One subtitle line: an unnamed track reads "Track 2 · SubRip" (its place in the list, 1-based); a named one
    /// keeps its name, with the codec as a smaller second line only when another track has the same name.
    static func subtitle(position: Int, title: String?, displayTitle: String?, codec: String?,
                         sameNameElsewhere: Bool) -> (title: String, detail: String?) {
        let codecText = codecName(codec)
        guard let n = name(title: title, displayTitle: displayTitle, codec: codec) else {
            return (["Track \(position)", codecText].compactMap { $0 }.joined(separator: " · "), nil)
        }
        return (n, sameNameElsewhere ? codecText : nil)
    }

    static func subtitles(_ streams: [MStream]) -> [(title: String, detail: String?)] {
        let names = streams.map { name(title: $0.Title, displayTitle: $0.DisplayTitle, codec: $0.Codec) }
        return streams.enumerated().map { k, st in
            let n = names[k]
            let dup = n != nil && names.filter { $0 == n }.count > 1
            return subtitle(position: k + 1, title: st.Title, displayTitle: st.DisplayTitle, codec: st.Codec,
                            sameNameElsewhere: dup)
        }
    }

    /// Where a subtitle comes from, after its format: an external file shows its codec as the file type
    /// ("SRT (file)"), an embedded track the friendly codec name ("SubRip (embedded)", "PGS (embedded)").
    static func subtitleSource(codec: String?, isExternal: Bool) -> String {
        if isExternal {
            let c = (codec ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            let type = c == "SUBRIP" ? "SRT" : c == "WEBVTT" ? "VTT" : c
            return type.isEmpty ? "File" : "\(type) (file)"
        }
        return "\(codecName(codec) ?? "Unknown format") (embedded)"
    }

    /// One subtitle line with its source: "Romanian · SRT (file)", "Romanian · SubRip (embedded)";
    /// an unnamed track reads "Track 2 · PGS (embedded)".
    static func sourcedSubtitle(position: Int, title: String?, displayTitle: String?, codec: String?,
                                isExternal: Bool) -> String {
        var n = name(title: title, displayTitle: displayTitle, codec: codec) ?? "Track \(position)"
        // "Romanian External" → "Romanian": the source is said after the dot
        let words = n.split(separator: " ").filter { !["EXTERNAL", "(EXTERNAL)"].contains($0.uppercased()) }
        if !words.isEmpty { n = words.joined(separator: " ") }
        return n + " · " + subtitleSource(codec: codec, isExternal: isExternal)
    }

    static func sourcedSubtitles(_ streams: [MStream]) -> [String] {
        streams.enumerated().map { k, st in
            sourcedSubtitle(position: k + 1, title: st.Title, displayTitle: st.DisplayTitle, codec: st.Codec,
                            isExternal: st.IsExternal == true)
        }
    }

    /// One audio track on one line: "English · AC3 · 5.1".
    static func audioLines(_ streams: [MStream]) -> [String] {
        audios(streams).map { a in [a.title, a.detail].compactMap { $0 }.joined(separator: " · ") }
    }

    /// One audio line: the name on line 1 (wraps to two lines, never cut), codec and channels on a smaller line 2
    /// unless the name already says them.
    static func audio(position: Int, title: String?, displayTitle: String?, codec: String?,
                      channels: String?) -> (title: String, detail: String?) {
        let t = name(title: title, displayTitle: displayTitle, codec: codec) ?? "Track \(position)"
        let ch = channels.flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() }
        let parts = [codecName(codec), ch].compactMap { $0 }
        let lower = t.lowercased()
        if let ch, lower.contains(ch.lowercased()) { return (t, nil) }   // "English - Dolby Digital - 5.1"
        return (t, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    static func audios(_ streams: [MStream]) -> [(title: String, detail: String?)] {
        streams.enumerated().map { k, st in
            audio(position: k + 1, title: st.Title, displayTitle: st.DisplayTitle, codec: st.Codec, channels: st.ChannelLayout)
        }
    }

    /// "+200 ms", "0 ms", "−100 ms".
    static func offsetText(_ ms: Int) -> String {
        ms > 0 ? "+\(ms) ms" : ms < 0 ? "−\(-ms) ms" : "0 ms"
    }

    /// The watched part of an episode in the Episodes panel: 0 for unstarted or watched ones.
    static func episodeFraction(position: Double, runtimeTicks: Int64?, played: Bool) -> Double {
        guard !played, let t = runtimeTicks, t > 0, position > 0 else { return 0 }
        return min(1, position / (Double(t) / 10_000_000))
    }
}

// MARK: - Panel pieces (the Episodes panel's style)

/// A panel heading as in the Episodes panel: the title at 18 bold, an optional control (picker) on the right.
struct Glass3DPanelHeading<Trailing: View>: View {
    let title: String
    var back: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            if let back {
                Button(action: back) { Image(systemName: "chevron.left").cvFont(14, weight: .bold).frame(width: 24, height: 24) }
                    .buttonStyle(.plainHand).helpLabel("Back")
            }
            Text(title).cvFont(18, weight: .bold).lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
    }
}

extension Glass3DPanelHeading where Trailing == EmptyView {
    init(title: String, back: (() -> Void)? = nil) {
        self.init(title: title, back: back, trailing: { EmptyView() })
    }
}

/// A small section title inside a panel; the only place a panel shows a symbol.
struct Glass3DPanelSection: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).cvFont(11, weight: .semibold)
            Text(title.uppercased()).cvFont(11, weight: .semibold).kerning(0.6)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }
}

/// A panel row at the Episodes panel's size: title (wraps to two lines), optional smaller second line, a check.
struct Glass3DPanelRow: View {
    let title: String
    var detail: String? = nil
    var checked = false
    var chevron = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).cvFont(14, weight: .medium).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).cvFont(12).foregroundColor(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if checked { Image(systemName: "checkmark").cvFont(12, weight: .bold) }
                if chevron { Image(systemName: "chevron.right").cvFont(11, weight: .bold).foregroundColor(.secondary) }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle(glass: true))
        .padding(.horizontal, 6)
    }
}

/// The same panel row's size for a control line (Subtitle Offset).
struct Glass3DPanelControlRow<Controls: View>: View {
    let title: String
    @ViewBuilder var controls: () -> Controls
    var body: some View {
        HStack(spacing: 10) {
            Text(title).cvFont(14, weight: .medium).lineLimit(1)
            Spacer(minLength: 6)
            controls()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 36)
        .padding(.horizontal, 6)
    }
}

/// A small round glass step button (−, +, reset) used inside a control row.
struct Glass3DStepButton: View {
    let icon: String
    let help: String
    var dim = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).cvFont(11, weight: .bold)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.07)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0.3 : 0.14), lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plainHand)
        .opacity(dim ? 0.35 : 1)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .helpLabel(help)
    }
}

/// A speed chip: a capsule, the chosen one lit in the accent, a little brighter under the pointer.
struct Glass3DSpeedChip: View {
    let label: String
    let on: Bool
    let help: String
    let action: () -> Void
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    var body: some View {
        let accent = Theme.accent(accentName)
        Button(action: action) {
            Text(label).cvFont(12, weight: .semibold)
                .frame(maxWidth: .infinity).frame(height: 30)
                .foregroundColor(.white)
                .background(Capsule().fill(on ? accent.opacity(hover ? 0.65 : 0.55) : Color.white.opacity(hover ? 0.14 : 0.06)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.4 : hover ? 0.28 : 0.15), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .helpLabel(help)
    }
}

/// A dropdown field (subtitle appearance): the field radius (8), a faint glass fill that brightens under the pointer,
/// opening the app's glass list.
struct Glass3DFieldPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Environment(\.dropdownCenter) private var center
    @State private var frame: CGRect = .zero
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous)
        Button {
            guard let center else { return }
            if center.list != nil { center.close(); return }
            let sel = options.firstIndex { $0.0 == selection } ?? 0
            center.list = .init(anchor: frame, options: options.map(\.1), selected: sel) { i in selection = options[i].0 }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "—").lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").cvFont(9, weight: .bold).opacity(0.7)
            }
            .cvFont(13, weight: .medium)
            .foregroundColor(.white)
            .padding(.horizontal, 12).frame(height: 32)
            .background(shape.fill(Color.white.opacity(hover ? 0.14 : 0.07)))
            .overlay(shape.strokeBorder(Color.white.opacity(hover ? 0.3 : 0.15), lineWidth: 0.75))
            .contentShape(shape)
        }
        .buttonStyle(.plainHand)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .named("dropdownLayer")) }
                .onChange(of: g.frame(in: .named("dropdownLayer"))) { _, f in frame = f }
        })
    }
}

// MARK: - Subtitles panel

/// The Subtitles panel opened from the bar's Subtitles button, in the Episodes panel's style: the tracks (with
/// where each comes from), then Subtitle Offset and Subtitle Appearance at the bottom. Audio, quality and speed
/// live in their own bar buttons. As tall as its content, at most the room the player gives it (then it scrolls).
struct Glass3DSubtitlesPanel: View {
    @ObservedObject var ui: PlayerUIModel
    @ObservedObject var model: PlayerModel
    let emby: Emby
    let openAppearance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Glass3DPanelHeading(title: "Subtitles")
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }.classicScrollBars()   // thin overlay bars, only while scrolling
            }
        }
        .frame(width: 340)
        .modifier(PanelSurface(classic: true))
        .environment(\.colorScheme, .dark)
        .onTapGesture {}   // keep taps inside the panel
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Glass3DPanelRow(title: "Off", checked: model.sub == nil) { ui.setSub(emby, nil) }
            let subs = model.subStreams
            let subLabels = Glass3DTrackLabel.sourcedSubtitles(subs)
            ForEach(Array(subs.enumerated()), id: \.element.Index) { k, st in
                Glass3DPanelRow(title: subLabels[k], checked: model.sub == st.Index) { ui.setSub(emby, st.Index) }
            }
            divider
            Glass3DPanelControlRow(title: "Subtitle Offset") {
                Glass3DStepButton(icon: "minus", help: "Show subtitles 100 ms earlier") { model.subOffset -= 100 }
                Text(Glass3DTrackLabel.offsetText(model.subOffset)).cvFont(12) { $0.monospacedDigit() }
                    .foregroundColor(.secondary).frame(minWidth: 58)
                Glass3DStepButton(icon: "plus", help: "Show subtitles 100 ms later") { model.subOffset += 100 }
                Glass3DStepButton(icon: "arrow.counterclockwise", help: "Reset offset", dim: model.subOffset == 0) {
                    model.subOffset = 0
                }
            }
            Glass3DPanelRow(title: "Subtitle Appearance", chevron: true, action: openAppearance)
        }
        .padding(.bottom, 8)
    }

    var divider: some View { Divider().padding(.horizontal, 20).padding(.vertical, 6) }
}

// MARK: - Bar menus (audio; quality & speed)

enum Glass3DBarMenus {
    /// The Quality & speed list: a "Quality" header, the qualities, a "Speed" header, the speeds 0.5×…2×.
    static func qualitySpeedOptions() -> [String] {
        ["Quality"] + PlayerUIModel.qualities.map(\.1) + ["Speed"] + PlayerUIModel.speeds.map(PlayerUIModel.speedLabel)
    }
    static var qualitySpeedHeaders: Set<Int> { [0, PlayerUIModel.qualities.count + 1] }
    /// The ticked lines: the current quality and the current speed.
    static func qualitySpeedChecked(quality: Int, speed: Float) -> Set<Int> {
        var c: Set<Int> = []
        if let q = PlayerUIModel.qualities.firstIndex(where: { $0.0 == quality }) { c.insert(q + 1) }
        if let r = PlayerUIModel.speeds.firstIndex(of: speed) { c.insert(PlayerUIModel.qualities.count + 2 + r) }
        return c
    }
    enum Pick: Equatable { case quality(Int), speed(Float), nothing }
    static func qualitySpeedPick(_ i: Int) -> Pick {
        let q = PlayerUIModel.qualities
        if i >= 1 && i <= q.count { return .quality(q[i - 1].0) }
        let r = i - q.count - 2
        if r >= 0 && r < PlayerUIModel.speeds.count { return .speed(PlayerUIModel.speeds[r]) }
        return .nothing
    }
}

// MARK: - Episodes panel progress

/// The Resume ring on a partly watched episode's thumbnail (Episodes panel); the row itself is the button.
struct Glass3DEpisodeProgress: View {
    let fraction: Double
    var body: some View { ResumeRingMark(fraction: fraction, size: 24, inset: 4) }
}

// MARK: - Right-hand control bar

/// One button of the right-hand bar. `menu` makes it open the glass list instead; `syncPlayOnly` hides it outside
/// a SyncPlay group.
struct Glass3DBarItem: Identifiable {
    struct Menu {
        let options: [String]; let selected: Int; let pick: (Int) -> Void
        var checked: Set<Int>? = nil
        var headers: Set<Int> = []
    }
    /// The bar's order (owner): Episodes/Collection · Chapters · Subtitles · Audio · Quality & speed ·
    /// (Watch together) · Info · PiP · Cast · AirPlay · Full screen.
    static let order = ["episodes", "chapters", "subtitles", "audio", "quality", "syncplay", "info", "pip", "cast", "airplay", "fullscreen"]
    static func ordered(_ items: [Glass3DBarItem]) -> [Glass3DBarItem] {
        items.sorted { (order.firstIndex(of: $0.id) ?? order.count) < (order.firstIndex(of: $1.id) ?? order.count) }
    }
    let id: String
    let icon: String
    var on = false
    let help: String
    var menu: Menu? = nil
    var syncPlayOnly = false
    /// "airplay": the AVPlayer the system route picker routes (Glass3DAirPlay.swift)
    var routePlayer: AVPlayer? = nil
    var action: () -> Void = {}
}

/// The right-hand controls as one Liquid Glass bar (macOS 26+; material before), thin dividers between buttons.
struct Glass3DControlBar: View {
    @ObservedObject var group: SyncPlayGroup
    let items: [Glass3DBarItem]
    let poke: () -> Void
    @AppStorage(TvTarget.key) private var tvTarget = TvTarget.cast
    @ObservedObject private var castSession = CastSession.shared

    var body: some View {
        let shown = PlayerBarItems.items(items, tvTarget: tvTarget, casting: castSession.isCasting)
            .filter { !$0.syncPlayOnly || group.isActive }
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { k, it in
                if k > 0 {
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 20).allowsHitTesting(false)
                }
                if it.id == "airplay" { Glass3DAirPlayButton(player: it.routePlayer, help: it.help) }
                else if it.id == "cast" { Glass3DCastBarButton { open in Glass3DBarButton(item: it, poke: poke, hideTip: open) } }
                else { Glass3DBarButton(item: it, poke: poke) }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .modifier(Glass3DBarSurface())
        .environment(\.colorScheme, .dark)
    }
}

private struct Glass3DBarSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                content
                    .background(Capsule().fill(Color.black.opacity(0.18)))
                    .background(ClassicGlassBacking(shape: Capsule()))
                    .glassEffect(.clear, in: Capsule())
            }
        } else {
            content
                .background(Capsule().fill(Color.black.opacity(0.25)))
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    .allowsHitTesting(false))
        }
    }
}

private struct Glass3DBarButton: View {
    let item: Glass3DBarItem
    let poke: () -> Void
    /// The Cast menu is open above it: its tooltip would show through the menu
    var hideTip = false
    @AppStorage("accent") private var accentName = "red"
    @Environment(\.dropdownCenter) private var center
    @State private var hover = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            if let m = item.menu {
                if let center {
                    if center.list != nil { center.close() }
                    else { center.list = .init(anchor: frame, options: m.options, selected: m.selected, pick: m.pick,
                                               checked: m.checked, headers: m.headers, closeOnLeave: true) }
                }
            } else {
                item.action()
            }
            poke()
        } label: {
            Image(systemName: item.icon).cvFont(17, weight: .medium)
                .foregroundColor(item.on ? Theme.accent(accentName) : .white)
                .frame(width: 42, height: 38)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0)).padding(.vertical, 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .helpLabel(hideTip ? "" : item.help)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .named("dropdownLayer")) }
                .onChange(of: g.frame(in: .named("dropdownLayer"))) { _, f in frame = f }
        })
    }
}
