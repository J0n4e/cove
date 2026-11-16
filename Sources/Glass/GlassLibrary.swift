import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// A teardrop lying on its side: round on the left, its point at the middle of the right edge. The point is a
/// right angle (the sides meet at 90°), as a classic drop.
struct Teardrop: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        let c = CGPoint(x: rect.minX + r, y: rect.midY)
        let d = min(rect.maxX - c.x, r * 2.squareRoot())   // r·√2 from the middle gives the 90° point
        let tip = CGPoint(x: c.x + d, y: rect.midY)
        guard d > r else { return Path(ellipseIn: rect) }
        // Where the straight sides touch the circle
        let a = acos(r / d)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y - r * sin(a)))
        p.addArc(center: c, radius: r, startAngle: .radians(-a), endAngle: .radians(a), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The A–Z letter preview's drop, in the watched check's finish: glossy white (light on top, shade at the
/// bottom) with a thin black outline and a soft shadow.
struct TeardropGlass: View {
    var body: some View {
        ZStack {
            Teardrop().fill(Color.white)
            Teardrop().fill(LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                   .init(color: .white.opacity(0.1), location: 0.45),
                                                   .init(color: .black.opacity(0.35), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            Teardrop().stroke(Color.black.opacity(0.85), lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1.5)
    }
}

/// One letter of the library A–Z bar.
struct AlphaLetter: View {
    @AppStorage("accent") private var accentName = "red"
    let l: String
    let on: Bool
    let action: () -> Void
    /// Dock-style zoom: set by the bar from how close the pointer is to this letter.
    var scale: CGFloat = 1
    var hovering: (Bool) -> Void = { _ in }
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(l).font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 17)
                .foregroundColor(on ? Theme.onAccent(accentName) : hover ? .primary : .secondary)
                .background(Capsule().fill(on ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.white.opacity(hover ? 0.18 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHand)
        .scaleEffect(scale)
        .padding(.vertical, (scale - 1) * 9)   // a zoomed letter makes room, so its neighbours move apart
        // The pointer covers the letter itself: a large preview of it beside the bar, to the left, in a teardrop pointing at it
        .overlay(alignment: .trailing) {
            if hover {
                Text(l).font(.system(size: 19, weight: .heavy)).foregroundColor(.black.opacity(0.85))
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
        .helpLabel(on ? "Show all" : l == "#" ? "Titles starting with a number" : "Jump to \(l)")
    }
}

let alphaLetters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

// MARK: - Library page (header, tabs, sort, filter; choices are remembered per library)

struct LibraryView: View {
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
                    PosterGrid(emby: emby, items: items, look: PosterLook(glass3D: false),
                               insets: NSEdgeInsets(top: 0, left: 40, bottom: 24, right: 94),
                               header: AnyView(header.padding(.leading, 40).padding(.trailing, 94).padding(.top, 24)),
                               footer: loading ? AnyView(Spinner())
                                   : loadFailed ? AnyView(LoadMoreFailedView { Task { await load(reset: false) } }) : nil,
                               topInset: g.safeAreaInsets.top, willShow: { i in
                        if i == items.count - 30 || i == items.count - 1 { loadMore() }
                    }, open: { NavState.shared.open($0) })
                    .ignoresSafeArea(edges: .top)   // runs up under the see-through top bar, as the ScrollView did
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if tab == 2 { genreGrid } else { grid }
                    }.padding(.leading, 40).padding(.trailing, 94).padding(.vertical, 24)   // room for the A–Z bar
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

    /// A–Z jump bar in a glass capsule. Each letter shows a pointing hand and lights up under the mouse;
    /// the chosen letter is filled with the accent color (click it again to show everything).
    var alphaBar: some View {
        VStack(spacing: 1) {
            ForEach(Array(alphaLetters.enumerated()), id: \.element) { i, l in
                AlphaLetter(l: l, on: letter == l, action: { letter = (letter == l) ? "" : l },
                            scale: alphaScale(i), hovering: { inside in
                    if inside { alphaHover = i } else if alphaHover == i { alphaHover = nil }
                })
            }
        }
        .animation(.easeOut(duration: 0.12), value: alphaHover)
        .padding(.vertical, 8).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.black.opacity(0.4)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .padding(.trailing, 40)   // clear of the window's scroll bar, a little in from the edge
    }

    var header: some View {
        VStack(spacing: 16) {
            ZStack {
                HStack { Text(lib.title).font(.title2.bold()); Spacer() }
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Button { tab = i } label: {
                            Text(i == 0 ? lib.title : ["", "Collections", "Genres", "Favorites"][i])
                                .font(.callout.weight(tab == i ? .semibold : .regular))
                                .padding(.horizontal, 18).frame(height: 32)
                                .background(Capsule().fill(tab == i ? Color.white.opacity(0.22) : Color.clear))
                                .foregroundColor(tab == i ? .white : .secondary)
                                .contentShape(Capsule())
                        }.buttonStyle(.plainHand).focusEffectDisabled()
                    }
                }.padding(4).frame(height: 40).glassCapsule()
            }
            if tab != 2 { controls }
        }
    }

    var controls: some View {
        HStack(spacing: 10) {
            Text("\(total) Items").foregroundColor(.secondary).padding(.trailing, 4)
            Button { Task { if let f = items.first { await emby.play(f) } } } label: {
                Label("Play", systemImage: "play.fill").pill()
            }.buttonStyle(.plainHand)
            Button { Task { await shuffle() } } label: {
                Label("Shuffle", systemImage: "shuffle").pill()
            }.buttonStyle(.plainHand)
            Menu {
                Picker("Sort by", selection: $sort) {
                    Text("Recently Added").tag("latest")
                    Text("Name").tag("name")
                    Text("Release Date").tag("release")
                    Text("Rating").tag("top")
                }.pickerStyle(.inline)
                Picker("Order", selection: $desc) {
                    Text("Ascending").tag(false)
                    Text("Descending").tag(true)
                }.pickerStyle(.inline)
            } label: {
                Label(sortLabel, systemImage: desc ? "arrow.down" : "arrow.up").pill()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().handCursor()
            Menu {
                Picker("Status", selection: $watch) {
                    Text("All").tag("all")
                    Text("Unwatched").tag("unwatched")
                    Text("Watched").tag("watched")
                }.pickerStyle(.inline)
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag("")
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").pill(active: filtered)
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().handCursor()
            if !genre.isEmpty {
                Button { genre = "" } label: { Label(genre, systemImage: "xmark").pill(active: true) }.buttonStyle(.plainHand)
            }
            layoutToggle
            Menu {
                if canGroup {
                    Toggle("Group by Collection", isOn: $groupCol)
                    Divider()
                }
                Button("Refresh") { Task { await load(reset: true) } }
            } label: { Image(systemName: "ellipsis").pill() }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().handCursor()
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
                    Image(systemName: m.1).font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 28)
                        .background(Capsule().fill(layout == m.0 ? Color.white.opacity(0.22) : Color.clear))
                        .foregroundColor(layout == m.0 ? .white : .secondary)
                        .contentShape(Capsule())
                }.buttonStyle(.plainHand).helpLabel(m.0 == "grid" ? "Grid view" : "List view")
            }
        }.padding(4).frame(height: 36).glassCapsule()
    }

    var genreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(genres, id: \.self) { g in
                Button { genre = g; tab = 0 } label: {
                    Text(g).font(.headline).frame(maxWidth: .infinity, minHeight: 70)
                        .background(Color.white.opacity(0.1)).cornerRadius(8)
                }.buttonStyle(.plainHand)
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
