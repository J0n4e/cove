import SwiftUI

// The Classic toolbar style (Settings → Appearance → Toolbar style, the default): the top bar exactly as before the
// Clean style existed: glossy 3D lettering, tab hover, the old glass, the old icons, the red streams count after
// Activity's name with the unread dot inside its pill, and on a narrow window icons only, then sideways scrolling.
// The Clean style lives in Glass3DToolbar.swift.

/// The classic centre of the top bar: names → icons only → sideways scroll as the window narrows.
struct ClassicTopNavCenterClassic: View {
    var body: some View {
        // On a narrow window the sections don't all fit: the pill then scrolls sideways instead of
        // spilling past the window edge, where its buttons can't be clicked and Back gets squeezed out
        // Too narrow for the names: icons only (names on hover); scrolling only if even those don't fit
        ViewThatFits(in: .horizontal) {
            ClassicTopNavButtonsClassic()
            ClassicTopNavButtonsClassic(compact: true)
            ScrollView(.horizontal, showsIndicators: false) { ClassicTopNavButtonsClassic(compact: true) }
        }
    }
}

struct ClassicTopNavButtonsClassic: View {
    @AppStorage("accent") private var accentName = "red"
    @EnvironmentObject var emby: Emby
    @AppStorage(NavOrder.key) private var navOrder = ""
    @ObservedObject private var nav = ClassicNavState.shared
    @Namespace private var hoverNS   // Settings → Hover effect → Sliding light glides in it
    @StateObject private var slide = TopBarSlideState()
    @AppStorage("topBarLabels") private var labelSetting = "both"   // Settings → General: "both", "names" or "icons"
    /// The window is too narrow for the names: icons only, whatever Settings says.
    var compact = false
    var labels: String { compact ? "icons" : labelSetting }
    func item(_ title: String, _ id: String, _ icon: String, badge: Int = 0) -> some View {
        let on = nav.sel == id
        return Button {
            nav.query = ""; nav.searchOpen = false
            if nav.sel == id { nav.reselect += 1 }
            nav.sel = id; nav.popToRoot()
        } label: {
            // Small icon before each name, as in the sidebar
            HStack(spacing: Glass3DTokens.Space.s) {
                // Glossy lettering (the 3D face, no thickness)
                if labels != "names" { Text3D(image: Image(systemName: icon), size: labels == "icons" ? 16 : 14, thick: false) }
                if labels != "icons" {
                    Text3D(text: title, size: 15, thick: false, weight: .bold)   // every tab as readable as the selected one (owner)
                }
                // the count in a red circle (owner's mock-up), names or icons alike
                if badge > 0 { CountBadge(count: badge) }
            }
                .padding(.horizontal, labels == "names" ? 18 : 16).frame(height: 36)
                .classicSelectedPill(on)   // only the selected section gets the banner Play button's glass pill
                .modifier(Glass3DTabHover(on: on))   // the others: a lighter dark pill; hover sheen, lift and white label
                .modifier(SectionHoverGlow(on: !on, slideId: id))   // the others: the chosen hover look (Sliding light: shared)
                .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .tip(labels == "icons" ? title : "")   // names show on hover when only icons are shown
        .focusEffectDisabled()   // no blue keyboard-focus ring around a section
    }
    /// Favorites or Activity, wherever Settings → Libraries placed it.
    @ViewBuilder func section(_ id: String) -> some View {
        if id == NavOrder.favorites { item("Favorites", "favorites", "heart.fill") }
        else if id == NavOrder.nowPlaying { item(ActivitySection.title, "nowplaying", ActivitySection.icon, badge: nav.activeCount).modifier(ActivityUnreadDot(inset: 7)) }
    }
    func icon(_ lib: LibPref) -> String { LibraryIcon.classic(kind: lib.kind) }
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.s) {
            item("Home", "home", "house.fill")
            let rows = NavOrder.rows(navOrder, libIds: emby.libs.map(\.id))
            ForEach(NavOrder.top(rows), id: \.self) { section($0) }
            ForEach(emby.libs) { lib in
                if lib.visible { item(lib.title, lib.id, icon(lib)) }
                ForEach(NavOrder.after(lib.id, rows), id: \.self) { section($0) }
            }
        }
        .environment(\.topBarSlide, TopBarSlide(ns: hoverNS, state: slide))
        .padding(Glass3DTokens.Space.xs)
        .frame(height: 44)
        .classicClearGlass()

    }
}
