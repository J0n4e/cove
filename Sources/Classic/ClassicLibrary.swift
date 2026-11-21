import IOKit.pwr_mgt
import SwiftUI
import AVKit

let classicAlphaLetters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

// MARK: - Library page (header, tabs, sort, filter; choices are remembered per library)

struct ClassicLibraryView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let lib: LibPref
    @StateObject private var model: LibraryModel
    /// Bumped by the root when the library already shown is clicked again: reload it from the server.
    var refresh = 0

    init(lib: LibPref, refresh: Int = 0) {
        self.lib = lib
        _model = StateObject(wrappedValue: LibraryModel(lib: lib))
        self.refresh = refresh
    }

    var body: some View {
        Group {
            if model.tab != 2 && model.layout != "list" && !model.visibleItems.isEmpty {
                // The posters: AppKit grid (see PosterGrid), which owns the scrolling; the header scrolls with them.
                // While there are none yet (loading, an error, an empty library) the page below shows why.
                GeometryReader { g in
                    PosterGrid(emby: emby, items: model.visibleItems,
                               header: AnyView(header.padding(.leading, 40).padding(.trailing, 92).padding(.top, 24)),
                               footer: model.loading ? AnyView(Spinner())
                                   : model.loadFailed ? AnyView(LoadMoreFailedView { model.retry() }) : nil,
                               topInset: g.safeAreaInsets.top, willShow: { i in
                        model.cellWillShow(i)
                    }, open: { ClassicNavState.shared.open($0) })
                    .ignoresSafeArea(edges: .top)   // runs up under the see-through top bar, as the ScrollView did
                    .modifier(ClassicGridTopFade())   // the AppKit grid: soft fade under the bar
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if model.tab == 2 { genreGrid } else { grid }
                    }.padding(.leading, 40).padding(.trailing, 92).padding(.vertical, 24)   // room for the A–Z bar
                }
                .classicScrollBars()   // thin overlay bars, only while scrolling
            }
        }
        .background(bg)
        .overlay(alignment: .trailing) {
            if model.tab != 2 {
                // Fits the window height: every other letter when they don't all fit
                GeometryReader { g in
                    alphaBar(AlphaBar.thin(classicAlphaLetters, slots: AlphaBar.slots(height: g.size.height - 40)))
                        .frame(width: g.size.width, height: g.size.height, alignment: .trailing)
                }
            }
        }
        .task(id: model.key) { model.bind(emby); await model.load(reset: true) }
        .onDisappear { model.cancel() }
        .onChange(of: refresh) { model.reload() }
        .task { model.bind(emby); await model.loadGenres() }
        .onChange(of: model.sort) { model.sortChanged() }
        .onChange(of: model.savedKey) { model.save() }
    }

    /// The letter under the pointer, for the Dock-style zoom of the A–Z bar.
    @State private var alphaHover: Int?
    func alphaScale(_ i: Int) -> CGFloat {
        guard let h = alphaHover else { return 1 }
        switch abs(i - h) { case 0: return 1.7; case 1: return 1.35; case 2: return 1.12; default: return 1 }
    }

    func alphaBar(_ letters: [String]) -> some View {
        // Letters on a slim glass strip, as the top bar's sections
        VStack(spacing: 1) {
            ForEach(Array(letters.enumerated()), id: \.element) { i, l in
                ClassicAlphaLetter(l: l, on: model.letter == l, action: { model.letter = (model.letter == l) ? "" : l },
                                   scale: alphaScale(i), hovering: { inside in
                    if inside { alphaHover = i } else if alphaHover == i { alphaHover = nil }
                })
            }
        }
        .animation(.easeOut(duration: 0.12), value: alphaHover)
        .padding(.vertical, 6).padding(.horizontal, 3)
        .background(Capsule().fill(Color.black.opacity(0.3)))
        .background(ClassicGlassBacking(shape: Capsule()))
        .padding(.trailing, 34)
    }

    var header: some View {
        VStack(spacing: 16) {
            ZStack {
                // Title on the grid's leading edge, the count as small grey text under it
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        ClassicPageTitle(text: lib.title, icon: ClassicPageTitle.icon(lib.kind))
                        Text(Glass3DTokens.itemCount(model.visibleCount))
                            .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                    Spacer()
                    LibraryFindField(lib: lib)   // admins: Find to edit… (Edit metadata)
                    ItemAdminLibraryButton(lib: lib)   // admins: ⋯ Items without poster / backdrop
                }
                // Shared with the Now Playing page (Glass3DSegmentTabs), so both stay identical
                Glass3DSegmentTabs(titles: [lib.title, "Collections", "Genres", "Favorites"], selection: $model.tab)
            }
            if model.tab != 2 { controls }
        }
    }

    /// A button's icon and name in the top bar's glossy lettering.
    func glossyLabel(_ title: String, _ icon: String) -> some View {
        Label { Text3D(text: title, size: 16, weight: .semibold) } icon: { Text3D(image: Image(systemName: icon), size: 17) }
    }

    var controls: some View {
        HStack(spacing: 10) {
            Button { Task { await model.playFirst() } } label: {
                glossyLabel("Play", "play.fill").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton())
            Button { Task { await model.shuffle() } } label: {
                glossyLabel("Shuffle", "shuffle").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton())
            // Sort, filter and More open the glass list (not the macOS menu)
            GlassListButton(list: {
                let sorts = [("latest", "Recently Added"), ("name", "Name"), ("release", "Release Date"), ("top", "Rating")]
                let opts = ["Sort by"] + sorts.map(\.1) + ["Order", "Ascending", "Descending"]
                var ck: Set<Int> = [model.desc ? 7 : 6]
                if let i = sorts.firstIndex(where: { $0.0 == model.sort }) { ck.insert(i + 1) }
                return (opts, ck, [0, 5], { i in
                    if (1...4).contains(i) { model.sort = sorts[i - 1].0 } else if i == 6 { model.desc = false } else if i == 7 { model.desc = true }
                })
            }) {
                glossyLabel(Glass3DTokens.sortLabel(field: model.sortLabel, ascending: !model.desc), "arrow.up.arrow.down").classicGlassPill(size: 44, iconOnly: false)
            }.helpLabel("Sort")
            GlassListButton(list: {
                let status = [("all", "All"), ("unwatched", "Unwatched"), ("watched", "Watched")]
                let opts = ["Status"] + status.map(\.1) + ["Genre", "All Genres"] + model.genres
                var ck: Set<Int> = []
                if let i = status.firstIndex(where: { $0.0 == model.watch }) { ck.insert(i + 1) }
                ck.insert(model.genre.isEmpty ? 5 : (model.genres.firstIndex(of: model.genre).map { $0 + 6 } ?? 5))
                return (opts, ck, [0, 4], { i in
                    if (1...3).contains(i) { model.watch = status[i - 1].0 }
                    else if i == 5 { model.genre = "" } else if i >= 6 { model.genre = model.genres[i - 6] }
                })
            }) {
                Label("Filter", systemImage: model.filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .classicGlassPill(size: 44)
            }.helpLabel("Filter")
            if !model.genre.isEmpty {
                Button { model.genre = "" } label: { glossyLabel(model.genre, "xmark").classicGlassPill(size: 44, iconOnly: false) }
                    .buttonStyle(HoverButton()).helpLabel("Clear genre")
            }
            layoutToggle
            GlassListButton(list: {
                let opts = (model.canGroup ? ["Group by Collection"] : []) + ["Refresh"]
                return (opts, model.canGroup && model.groupCol ? [0] : [], [], { i in
                    if model.canGroup && i == 0 { model.groupCol.toggle() } else { model.reload() }
                })
            }) {
                Label("More", systemImage: "ellipsis").classicGlassPill(size: 44)
            }.helpLabel("More")
        }
    }

    var grid: some View {
        VStack(spacing: 20) {
            if model.layout == "list" {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleItems) { it in
                        Glass3DListRow(item: it).onAppear {   // v1.18.6: the poster badges, no hover buttons
                            model.listRowAppeared(it.id)
                        }
                    }
                }
            }   // grid: PosterGrid, see body
            if model.loading { Spinner() }
            else if model.loadFailed {
                if model.items.isEmpty { ErrorStateView(message: emby.lastFailure ?? "Couldn't load this library.") { model.reload() } }
                else { LoadMoreFailedView { model.retry() } }
            }
            else if model.visibleItems.isEmpty { Text("Nothing here.").foregroundColor(.secondary).padding(40) }
        }
    }

    var layoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { model.layout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(model.layout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(model.layout == m.0)
                        .modifier(SectionHoverGlow(on: !(model.layout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicClearGlass()
    }

    var genreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(model.genres, id: \.self) { g in
                Button { model.genre = g; model.tab = 0 } label: {
                    // Glass tiles, as the buttons
                    Text(g).cvFont(13, weight: .bold).foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(HoverButton())
            }
        }
    }
}

/// One letter of the Classic A–Z bar: the original look, plus a pointing hand and a light circle under the mouse.
struct ClassicAlphaLetter: View {
    let l: String
    let on: Bool
    let action: () -> Void
    /// Dock-style zoom: set by the bar from how close the pointer is to this letter.
    var scale: CGFloat = 1
    var hovering: (Bool) -> Void = { _ in }
    @State private var hover = false
    @AppStorage("accent") private var accentName = "red"
    var body: some View {
        Button(action: action) {
            // The chosen letter lit in the accent, the one under the pointer in the top bar's hover look
            Text(l).cvFont(12, weight: .bold)
                .frame(width: 22, height: 20)
                .foregroundColor(on || hover ? .white : .white.opacity(0.55))
                .background {
                    if on {
                        Circle().fill(Theme.accent(accentName).opacity(0.6))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                    } else if hover {
                        ClassicHoverEffect()   // the top bar's hover look (Settings → General → Hover effect)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .scaleEffect(scale)
        .padding(.vertical, (scale - 1) * 10)   // a zoomed letter makes room, so its neighbours move apart
        // The pointer covers the letter itself: a large preview of it beside the bar, to the left, in a teardrop pointing at it
        .overlay(alignment: .trailing) {
            if hover {
                Text(l).cvFont(19, weight: .heavy).foregroundColor(.black.opacity(0.85))
                    .frame(width: 34, height: 36)
                    .offset(x: 7, y: -15)   // the turn moves the drop's round part up-left; the letter follows
                    .padding(.trailing, 8)   // the point
                    // The drop lies like a backslash: round part up-left, the point down-right at the letter
                    .background(TeardropGlass().rotationEffect(.degrees(45), anchor: .trailing))
                    .fixedSize()
                    .offset(x: -15, y: -6)   // the point reaches toward the letter under the pointer
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(scale > 1 ? 1 : 0)
        .onHover { inside in
            hover = inside
            hovering(inside)
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(on ? "Show all" : l == "#" ? "Titles starting with a number" : "Jump to \(l)")   // no tooltip
    }
}
