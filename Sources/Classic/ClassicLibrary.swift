import IOKit.pwr_mgt
import SwiftUI
import AVKit

let classicAlphaLetters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

// MARK: - Library page (header, tabs, sort, filter; choices are remembered per library)

struct ClassicLibraryView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    let lib: LibPref
    @State private var tab = 0
    @State private var items: [Item] = []
    @State private var total = 0
    @State private var loading = false
    @State private var loadFailed = false
    @State private var gen = 0
    @State private var pageTask: Task<Void, Never>?   // the one next-page load in flight (see loadMore)
    @State private var sort: String
    @State private var desc: Bool
    @State private var watch: String
    @State private var genre: String
    @State private var genres: [String] = []
    @State private var letter = ""
    @State private var layout: String
    @State private var groupCol: Bool

    init(lib: LibPref) {
        self.lib = lib
        let d = UserDefaults.standard.dictionary(forKey: "lf-" + lib.id) ?? [:]
        _sort = State(initialValue: d["sort"] as? String ?? "name")
        _desc = State(initialValue: d["desc"] as? Bool ?? false)
        _watch = State(initialValue: d["watch"] as? String ?? "all")
        _genre = State(initialValue: d["genre"] as? String ?? "")
        _groupCol = State(initialValue: d["groupCollections"] as? Bool ?? false)
        _layout = State(initialValue: d["layout"] as? String
                        ?? UserDefaults.standard.string(forKey: "defaultLibraryLayout") ?? "grid")
    }

    var key: String { "\(tab)|\(sort)|\(desc)|\(watch)|\(genre)|\(letter)|\(grouping)" }
    /// "Group by Collection" applies to the main tab of movie libraries.
    var canGroup: Bool { lib.kind == "movies" && tab == 0 }
    var grouping: Bool { canGroup && groupCol }
    var filtered: Bool { watch != "all" || !genre.isEmpty }
    var types: String { (tab == 1 || lib.kind == "boxsets") ? "BoxSet" : "Movie,Series,Video,MusicVideo" }
    var sortLabel: String {
        switch sort {
        case "latest": return "Recently Added"
        case "release": return "Release Date"
        case "top": return "Rating"
        default: return "Name"
        }
    }

    func save() {
        let d: [String: Any] = ["sort": sort, "desc": desc, "watch": watch, "genre": genre, "layout": layout,
                                "groupCollections": groupCol]
        UserDefaults.standard.set(d, forKey: "lf-" + lib.id)
    }

    var body: some View {
        Group {
            if tab != 2 && layout != "list" && !items.isEmpty {
                // The posters: AppKit grid (see PosterGrid), which owns the scrolling; the header scrolls with them.
                // While there are none yet (loading, an error, an empty library) the page below shows why.
                GeometryReader { g in
                    PosterGrid(emby: emby, items: items,
                               header: AnyView(header.padding(.leading, 40).padding(.trailing, 92).padding(.top, 24)),
                               footer: loading ? AnyView(Spinner())
                                   : loadFailed ? AnyView(LoadMoreFailedView { Task { await load(reset: false) } }) : nil,
                               topInset: g.safeAreaInsets.top, willShow: { i in
                        if i == items.count - 30 || i == items.count - 1 { loadMore() }
                    }, open: { ClassicNavState.shared.open($0) })
                    .ignoresSafeArea(edges: .top)   // runs up under the see-through top bar, as the ScrollView did
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if tab == 2 { genreGrid } else { grid }
                    }.padding(.leading, 40).padding(.trailing, 92).padding(.vertical, 24)   // room for the A–Z bar
                }
            }
        }
        .background(bg)
        .overlay(alignment: .trailing) { if tab != 2 { alphaBar } }
        .task(id: key) { await load(reset: true) }
        .onDisappear { pageTask?.cancel(); pageTask = nil }
        .task { genres = await emby.genres(lib) }
        .onChange(of: sort) { desc = (sort != "name") }
        .onChange(of: "\(sort)|\(desc)|\(watch)|\(genre)|\(layout)|\(groupCol)") { save() }
    }

    /// The letter under the pointer, for the Dock-style zoom of the A–Z bar.
    @State private var alphaHover: Int?
    func alphaScale(_ i: Int) -> CGFloat {
        guard let h = alphaHover else { return 1 }
        switch abs(i - h) { case 0: return 1.7; case 1: return 1.35; case 2: return 1.12; default: return 1 }
    }

    var alphaBar: some View {
        // Letters on a slim glass strip, as the top bar's sections
        VStack(spacing: 1) {
            ForEach(Array(classicAlphaLetters.enumerated()), id: \.element) { i, l in
                ClassicAlphaLetter(l: l, on: letter == l, action: { letter = (letter == l) ? "" : l },
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
                HStack { ClassicPageTitle(text: lib.title, icon: ClassicPageTitle.icon(lib.kind)); Spacer() }
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Button { tab = i } label: {
                            // Glossy lettering, as the top bar
                            Text3D(text: i == 0 ? lib.title : ["", "Collections", "Genres", "Favorites"][i], size: 12,
                                   weight: tab == i ? .bold : .semibold)
                                .opacity(tab == i ? 1 : 0.6)
                                .padding(.horizontal, 16).frame(height: 36)
                                .classicSelectedPill(tab == i)
                        .modifier(SectionHoverGlow(on: !(tab == i)))   // accent glow on hover, as the top bar
                        }.buttonStyle(.plainHand)
                    }
                }.padding(4).frame(height: 44).classicClearGlass()
            }
            if tab != 2 { controls }
        }
    }

    /// A button's icon and name in the top bar's glossy lettering.
    func glossyLabel(_ title: String, _ icon: String) -> some View {
        Label { Text3D(text: title, size: 16, weight: .semibold) } icon: { Text3D(image: Image(systemName: icon), size: 17) }
    }

    var controls: some View {
        HStack(spacing: 10) {
            Text("\(total) Items").foregroundColor(.secondary).padding(.trailing, 4)
            Button { Task { if let f = items.first { await emby.play(f) } } } label: {
                glossyLabel("Play", "play.fill").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton())
            Button { Task { await shuffle() } } label: {
                glossyLabel("Shuffle", "shuffle").classicGlassPill(size: 44, iconOnly: false)
            }.buttonStyle(HoverButton())
            // Sort, filter and More open the glass list (not the macOS menu)
            GlassListButton(list: {
                let sorts = [("latest", "Recently Added"), ("name", "Name"), ("release", "Release Date"), ("top", "Rating")]
                let opts = ["Sort by"] + sorts.map(\.1) + ["Order", "Ascending", "Descending"]
                var ck: Set<Int> = [desc ? 7 : 6]
                if let i = sorts.firstIndex(where: { $0.0 == sort }) { ck.insert(i + 1) }
                return (opts, ck, [0, 5], { i in
                    if (1...4).contains(i) { sort = sorts[i - 1].0 } else if i == 6 { desc = false } else if i == 7 { desc = true }
                })
            }) {
                glossyLabel(sortLabel, desc ? "arrow.down" : "arrow.up").classicGlassPill(size: 44, iconOnly: false)
            }.helpLabel("Sort")
            GlassListButton(list: {
                let status = [("all", "All"), ("unwatched", "Unwatched"), ("watched", "Watched")]
                let opts = ["Status"] + status.map(\.1) + ["Genre", "All Genres"] + genres
                var ck: Set<Int> = []
                if let i = status.firstIndex(where: { $0.0 == watch }) { ck.insert(i + 1) }
                ck.insert(genre.isEmpty ? 5 : (genres.firstIndex(of: genre).map { $0 + 6 } ?? 5))
                return (opts, ck, [0, 4], { i in
                    if (1...3).contains(i) { watch = status[i - 1].0 }
                    else if i == 5 { genre = "" } else if i >= 6 { genre = genres[i - 6] }
                })
            }) {
                Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .classicGlassPill(size: 44)
            }.helpLabel("Filter")
            if !genre.isEmpty {
                Button { genre = "" } label: { glossyLabel(genre, "xmark").classicGlassPill(size: 44, iconOnly: false) }
                    .buttonStyle(HoverButton()).helpLabel("Clear genre")
            }
            layoutToggle
            GlassListButton(list: {
                let opts = (canGroup ? ["Group by Collection"] : []) + ["Refresh"]
                return (opts, canGroup && groupCol ? [0] : [], [], { i in
                    if canGroup && i == 0 { groupCol.toggle() } else { Task { await load(reset: true) } }
                })
            }) {
                Label("More", systemImage: "ellipsis").classicGlassPill(size: 44)
            }.helpLabel("More")
        }
    }

    var grid: some View {
        VStack(spacing: 20) {
            if layout == "list" {
                LazyVStack(spacing: 6) {
                    ForEach(items) { it in
                        ListRow(item: it).onAppear {
                            if it.id == nextPageAt || it.id == items.last?.id { loadMore() }
                        }
                    }
                }
            }   // grid: PosterGrid, see body
            if loading { Spinner() }
            else if loadFailed {
                if items.isEmpty { ErrorStateView(message: emby.lastFailure ?? "Couldn't load this library.") { Task { await load(reset: true) } } }
                else { LoadMoreFailedView { Task { await load(reset: false) } } }
            }
            else if items.isEmpty { Text("Nothing here.").foregroundColor(.secondary).padding(40) }
        }
    }

    var layoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("grid", "square.grid.2x2"), ("list", "list.bullet")], id: \.0) { m in
                Button { layout = m.0 } label: {
                    // Glossy icon, as the top bar's lettering
                    Text3D(image: Image(systemName: m.1), size: 15)
                        .opacity(layout == m.0 ? 1 : 0.6)
                        .frame(width: 36, height: 36)
                        .classicSelectedPill(layout == m.0)
                        .modifier(SectionHoverGlow(on: !(layout == m.0)))   // accent glow on hover, as the top bar
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 44).classicClearGlass()
    }

    var genreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(genres, id: \.self) { g in
                Button { genre = g; tab = 0 } label: {
                    // Glass tiles, as the buttons
                    Text(g).font(.cv(13, weight: .bold)).foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(HoverButton())
            }
        }
    }

    func fetch(start: Int, limit: Int, sort s: String) async -> ItemList? {
        await emby.libraryItems(lib, limit: limit, start: start, sort: s, desc: s == sort ? desc : nil,
                                watch: watch, genre: genre, letter: letter, favorites: tab == 3, types: types,
                                groupCollections: grouping)
    }

    /// Next page from a scroll trigger: one task at a time, cancelled on reset and when the page goes away,
    /// instead of a new Task for every cell that scrolls past the trigger.
    func loadMore() {
        guard pageTask == nil else { return }
        pageTask = Task { await load(reset: false); pageTask = nil }
    }

    func load(reset: Bool) async {
        if reset { pageTask?.cancel(); pageTask = nil }
        if !reset && (loading || loadFailed || items.count >= total) { return }
        gen += 1
        let my = gen
        loading = true; loadFailed = false
        let r = await fetch(start: reset ? 0 : items.count, limit: 100, sort: sort)
        guard my == gen else { return }
        loading = false
        // A failed page keeps what's already shown and offers to try again (it used to end paging for good)
        guard let r else { loadFailed = true; return }
        if reset { items = r.Items } else { items += r.Items }
        total = r.TotalRecordCount ?? items.count
        // Posters of the new page start downloading now, before they scroll into view. A small library (Collections,
        // up to 300) is loaded and fetched whole, so no poster has to load while you scroll through it.
        let small = total <= 300
        ImageCache.shared.prefetch(r.Items.prefix(small ? 100 : 40).map { emby.image($0.posterId, width: 360) })
        if small && items.count < total { await load(reset: false) }
    }

    /// The next page is fetched when this item appears, 30 before the end, so it's there before you reach it.
    var nextPageAt: String? { items.count > 30 ? items[items.count - 30].id : nil }

    func shuffle() async {
        let r = await fetch(start: 0, limit: 1, sort: "random")
        if let f = r?.Items.first { await emby.play(f) }
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
            Text(l).font(.cv(11, weight: .bold))
                .frame(width: 20, height: 18)
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
        .padding(.vertical, (scale - 1) * 9)   // a zoomed letter makes room, so its neighbours move apart
        // The pointer covers the letter itself: a large preview of it beside the bar, to the left, in a teardrop pointing at it
        .overlay(alignment: .trailing) {
            if hover {
                Text(l).font(.cv(19, weight: .heavy)).foregroundColor(.black.opacity(0.85))
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
