import SwiftUI

// The top glass toolbar (Top bar navigation): crisp labels and icons, a steady tinted glass bar with a hairline
// outline, one icon size/weight/frame, the soft selected capsule, Activity's markers on its icon, and the More (⋯)
// menu that takes the less-used sections when the window is too narrow. Pure decisions are in
// ToolbarOverflow / LibraryIcon / ToolbarBadges (tested in Tests/ToolbarRefineTests.swift).

extension Glass3DTokens {
    enum Toolbar {
        /// One SF Symbol size and weight for every section icon, drawn in a fixed square frame so icons of
        /// different shapes share one baseline and centre.
        static let iconSize: CGFloat = 15
        static let iconWeight: Font.Weight = Glass3DTokens.Icon.weight
        static let iconFrame: CGFloat = 20
        /// Section names
        static let labelSize: CGFloat = 14
        /// One section's height inside the bar, and the bar's height
        static let itemHeight: CGFloat = 36
        static let barHeight: CGFloat = 44
        /// Fixed width reserved on each side of the bar (Back on the left, the profile circle on the right)
        static let sideSlot: CGFloat = 44
        /// Steady tint of the bar: the app background under the glass, so changing artwork behind it doesn't
        /// change how readable the white labels are (macOS 26 Liquid Glass and the 14/15 fallback alike)
        static let tint = 0.55
        /// The bar's hairline outline
        static let hairline: CGFloat = 0.5
        static let outline = Glass3DTokens.Stroke.strong
        /// Selected section: a soft capsule with a subtle white fill, a breath of accent and a hairline
        static let selectedFill = 0.16
        static let selectedAccent = 0.14
        static let selectedStroke = 0.30
        /// Hover on an unselected section: a fainter fill (no scaling)
        static let hoverFill = 0.07
        /// At most this very faint shadow under labels/icons (legibility over bright imagery only)
        static let labelShadow = Shadow(radius: 1, y: 0.5, opacity: 0.25)
        /// Activity's markers on its icon: the streams count circle (top-right) and the unread dot (top-left)
        static let countSize: CGFloat = 14
        static let dotSize: CGFloat = 6
    }
}

// MARK: - Pure decisions (tested)

/// Which sections stay in the bar and which go into More (⋯) when the window is too narrow.
/// Rules: everything shows when it fits (no More button, no layout change). Otherwise sections leave from the END
/// of the bar order, skipping Home, Activity (the owner's last pill stays last visible) and the selected section,
/// until the rest plus the More button fit. More keeps the bar's order.
enum ToolbarOverflow {
    struct Split: Equatable {
        var visible: [String]
        var overflow: [String]
    }
    static let home = "home", activity = "nowplaying"

    static func width(_ ids: [String], _ widths: [String: CGFloat], spacing: CGFloat) -> CGFloat {
        guard !ids.isEmpty else { return 0 }
        return ids.reduce(CGFloat(0)) { $0 + (widths[$1] ?? 0) } + spacing * CGFloat(ids.count - 1)
    }

    static func split(_ ids: [String], widths: [String: CGFloat], available: CGFloat, spacing: CGFloat,
                      moreWidth: CGFloat, selected: String) -> Split {
        // Not measured yet (0 / infinite): show everything, as before
        guard available > 0, available.isFinite, width(ids, widths, spacing: spacing) > available else {
            return Split(visible: ids, overflow: [])
        }
        let pinned: Set<String> = [home, activity, selected]
        var visible = ids
        var out: [String] = []
        for id in ids.reversed() where !pinned.contains(id) {
            if width(visible, widths, spacing: spacing) + spacing + moreWidth <= available { break }
            visible.removeAll { $0 == id }
            out.append(id)
        }
        return Split(visible: visible, overflow: ids.filter { out.contains($0) })
    }
}

/// The SF Symbol of a library in the top bar, sidebar and page title.
enum LibraryIcon {
    static func symbol(kind: String?, name: String = "") -> String {
        // Documentary libraries (owner's choice): a video camera, not a folder. Servers have no documentary type,
        // so they are recognised by name (Documentaries, Dokumentationen, Documentaires, Documentari…).
        let n = name.lowercased()
        if n.contains("documentar") || n.contains("dokumentar") || n.contains("documentair")
            || n.contains("dokumentation") { return "video" }
        switch kind {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "boxsets": return "square.stack"
        case "music": return "music.note"
        case "musicvideos": return "music.note.tv"
        case "homevideos": return "video"
        case "books": return "book"
        case "playlists": return "music.note.list"
        case "livetv": return "antenna.radiowaves.left.and.right"
        default: return "folder"   // mixed / untyped folders
        }
    }
}

/// Activity's two markers: the streams count circle only while something plays, the unread dot only while
/// notifications are unread.
enum ToolbarBadges {
    static func showCount(streams: Int) -> Bool { streams > 0 }
    static func showDot(unread: Int) -> Bool { unread > 0 }
}

// MARK: - Views

extension View {
    /// A section icon: one size, weight and fixed frame.
    func toolbarIcon() -> some View {
        cvFont(Glass3DTokens.Toolbar.iconSize, weight: Glass3DTokens.Toolbar.iconWeight)
            .frame(width: Glass3DTokens.Toolbar.iconFrame, height: Glass3DTokens.Toolbar.iconFrame)
    }
}

/// Activity's markers anchored on its icon (or its name when only names show): the red count circle on the
/// top-right corner (streams playing) and the small red dot on the top-left (unread notifications), so both can
/// show at once. `enabled` false = no markers (every other section).
struct ToolbarActivityMarkers: ViewModifier {
    var streams: Int
    var enabled = true
    @ObservedObject private var store = NotificationCenterStore.shared
    func body(content: Content) -> some View {
        let t = Glass3DTokens.Toolbar.self
        content
            .overlay(alignment: .topTrailing) {
                if enabled && ToolbarBadges.showCount(streams: streams) {
                    CountBadge(count: streams, size: t.countSize)
                        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                        .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] }
                        .help(streams == 1 ? "1 stream playing" : "\(streams) streams playing")
                }
            }
            .overlay(alignment: .topLeading) {
                if enabled && ToolbarBadges.showDot(unread: store.unread) {
                    UnreadDot(size: t.dotSize)
                        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                        .alignmentGuide(.leading) { $0[HorizontalAlignment.center] }
                        .help(NotificationTabLabel.unreadHelp(store.unread))
                }
            }
    }
}

/// The soft capsule behind the selected section (and behind More when the selection is inside it). The bar is
/// always drawn dark (see ToolbarBarSurface), so the white fill + hairline reads in light and dark appearance.
struct ToolbarSelectedCapsule: View {
    let on: Bool
    var hover = false
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        let t = Glass3DTokens.Toolbar.self
        ZStack {
            if on {
                Capsule().fill(Color.white.opacity(t.selectedFill))
                Capsule().fill(Theme.accent(accentName).opacity(t.selectedAccent))
                Capsule().strokeBorder(Color.white.opacity(t.selectedStroke), lineWidth: t.hairline)
            } else if hover {
                Capsule().fill(Color.white.opacity(t.hoverFill))
            }
        }
        .allowsHitTesting(false)
    }
}

/// One section's label: fixed-frame icon (accent when selected), crisp name, a very faint shadow token only.
struct ToolbarItemLabel: View {
    let title: String
    let icon: String
    /// "both", "names" or "icons" (Settings → General → Top bar)
    let labels: String
    let on: Bool
    var activity = false
    var streams = 0
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false
    var body: some View {
        let t = Glass3DTokens.Toolbar.self
        HStack(spacing: Glass3DTokens.Space.s) {
            if labels != "names" {
                Image(systemName: icon).toolbarIcon()
                    .foregroundStyle(on ? Theme.accent(accentName) : Color.white)
                    .modifier(ToolbarActivityMarkers(streams: streams, enabled: activity))
            }
            if labels != "icons" {
                Text(title).cvFont(t.labelSize, weight: on ? .semibold : .medium).lineLimit(1)
                    .foregroundStyle(Color.white)
                    .modifier(ToolbarActivityMarkers(streams: streams, enabled: activity && labels == "names"))
            }
        }
        .g3Shadow(t.labelShadow)
        .fixedSize()
        .padding(.horizontal, Glass3DTokens.Space.l).frame(height: t.itemHeight)
        .background { ToolbarSelectedCapsule(on: on, hover: hover) }
        .contentShape(Capsule())
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
    }
}

/// The bar's surface: the same glass as before (Liquid Glass on macOS 26, the frosted fallback on 14/15) over a
/// steady dark tint of the app background, with a hairline outline. Always drawn in the dark scheme so the light
/// appearance never turns it into white-on-white.
struct ToolbarBarSurface: ViewModifier {
    @Environment(\.appBG) private var bg
    func body(content: Content) -> some View {
        let t = Glass3DTokens.Toolbar.self
        content
            .background(Capsule().fill(bg.opacity(t.tint)))
            .modifier(ClassicClearGlass(shape: Capsule(), interactive: false))
            .overlay(Capsule().strokeBorder(Color.white.opacity(t.outline), lineWidth: t.hairline).allowsHitTesting(false))
            .environment(\.colorScheme, .dark)
    }
}

/// Widths of the sections, measured off-screen so the overflow split knows what fits.
struct ToolbarWidthsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func toolbarMeasure(_ id: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: ToolbarWidthsKey.self, value: [id: g.size.width]) })
    }
}

/// The More (⋯) button at the end of the bar: opens the shared glass list with the sections that didn't fit
/// (✓ on the selected one); shows the selected capsule when the current section is inside it.
struct ToolbarMoreButton: View {
    /// (id, title) of the sections in More, in bar order
    let items: [(String, String)]
    let selected: String
    let pick: (String) -> Void
    @Environment(\.dropdownCenter) private var center
    @State private var frame: CGRect = .zero
    @State private var hover = false
    var body: some View {
        let on = items.contains { $0.0 == selected }
        Button {
            guard let center else { return }
            if center.list != nil { center.close(); return }
            let checked = Set(items.indices.filter { items[$0].0 == selected })
            center.list = .init(anchor: frame, options: items.map(\.1), selected: -1,
                                pick: { i in if items.indices.contains(i) { pick(items[i].0) } },
                                checked: checked)
        } label: {
            Image(systemName: "ellipsis").toolbarIcon()
                .foregroundStyle(Color.white)
                .g3Shadow(Glass3DTokens.Toolbar.labelShadow)
                .padding(.horizontal, Glass3DTokens.Space.m).frame(height: Glass3DTokens.Toolbar.itemHeight)
                .background { ToolbarSelectedCapsule(on: on, hover: hover) }
                .contentShape(Capsule())
                .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        }
        .buttonStyle(.plainHand)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .named("dropdownLayer")) }
                .onChange(of: g.frame(in: .named("dropdownLayer"))) { _, f in frame = f }
        })
        .tip(on ? "More — \(items.first { $0.0 == selected }?.1 ?? "")" : "More")
        .focusEffectDisabled()
        .accessibilityLabel("More sections")
    }
}
