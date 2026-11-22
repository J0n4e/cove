import SwiftUI

// Activity → Cleanup (admins only): every movie and series, from never watched to mostly watched, with Delete…
// per row and for a selection. Model: Shared/Cleanup.swift.

struct CleanupView: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var store = CleanupStore.shared
    @ObservedObject private var trakt = Trakt.shared
    @AppStorage("cleanupSort") private var sortRaw = CleanupSort.leastWatched.rawValue
    @AppStorage("cleanupFilter") private var filterRaw = CleanupFilter.all.rawValue
    @AppStorage("cleanupRated") private var ratedRaw = CleanupRated.any.rawValue
    @AppStorage("cleanupKind") private var kindRaw = CleanupKind.both.rawValue
    @State private var library: String?
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private var sort: CleanupSort { CleanupSort(rawValue: sortRaw) ?? .leastWatched }
    private var filter: CleanupFilter { CleanupFilter(rawValue: filterRaw) ?? .all }
    private var rated: CleanupRated { CleanupRated(rawValue: ratedRaw) ?? .any }
    private var kind: CleanupKind { CleanupKind(rawValue: kindRaw) ?? .both }

    /// Your ★ ratings (Trakt) on the items, by their IMDb/TMDB/TVDB ids
    private func withMyRatings(_ items: [CleanupItem]) -> [CleanupItem] {
        items.map { e in
            guard let it = e.item, let k = Trakt.kind(it) else { return e }
            var c = e; c.myRating = trakt.rating(kind: k, ids: Trakt.ids(it.ProviderIds)); return c
        }
    }

    var body: some View {
        let shown = Cleanup.sorted(Cleanup.searched(Cleanup.filtered(withMyRatings(store.items), library: library, kind: kind, filter: filter).filter { rated.matches($0) }, query), by: sort)
        VStack(alignment: .leading, spacing: 16) {
            header(shown)
            if store.items.isEmpty {
                if store.loading {
                    VStack(spacing: 10) {
                        Spinner()
                        Text(store.progress ?? "").cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary)
                    }.frame(maxWidth: .infinity).padding(60)
                } else if let e = store.error {
                    StatsStateCard(symbol: "exclamationmark.triangle", title: "Cleanup couldn't be loaded", message: e)
                } else {
                    StatsStateCard(symbol: "sparkles", title: "No movies or series", message: "Titles of your libraries show here.")
                }
            } else if shown.isEmpty {
                StatsStateCard(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                               message: "Try another filter or library.")
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(shown) { i in
                        CleanupRow(entry: i, libraryName: libraryName(i.libraryId), selecting: selecting,
                                   selected: Binding(get: { selected.contains(i.id) },
                                                     set: { if $0 { selected.insert(i.id) } else { selected.remove(i.id) } }))
                    }
                }
            }
        }
        .task(id: emby.server + "|" + emby.userId) { await store.load(emby) }
        .task { await trakt.refresh() }   // your ★ ratings
        .onReceive(DeletedItems.shared.deleted) { ids in store.remove(ids); selected.subtract(ids) }
    }

    private func libraryName(_ id: String?) -> String? { store.libraries.first { $0.id == id }?.name }

    @ViewBuilder private func header(_ shown: [CleanupItem]) -> some View {
        HStack(spacing: 10) {
            CleanupMenu(symbol: "books.vertical", value: libraryName(library) ?? "All libraries",
                        options: [(nil as String?, "All libraries")] + store.libraries.map { (Optional($0.id), $0.name) },
                        selected: library, help: "Library") { library = $0 }
            CleanupMenu(symbol: "film.stack", value: kind.title, options: CleanupKind.allCases.map { ($0.rawValue, $0.title) },
                        selected: kindRaw, help: "Movies or series") { kindRaw = $0 }
            CleanupMenu(symbol: "line.3.horizontal.decrease", value: filter.title,
                        options: CleanupFilter.allCases.map { ($0.rawValue, $0.title) },
                        selected: filterRaw, help: "Filter") { filterRaw = $0 }
            CleanupMenu(symbol: "star", value: rated.title, options: CleanupRated.allCases.map { ($0.rawValue, $0.title) },
                        selected: ratedRaw, help: "Rated or not") { ratedRaw = $0 }
            CleanupMenu(symbol: "arrow.up.arrow.down", value: sort.title,
                        options: Cleanup.sorts(hasSize: store.items.contains { $0.sizeBytes != nil }).map { ($0.rawValue, $0.title) },
                        selected: sortRaw, help: "Sort") { sortRaw = $0 }
            // Find a title by name instead of scrolling (owner)
            ServerSearchField(placeholder: "Search titles", text: $query).frame(width: 220)
            Spacer(minLength: 0)
            if selecting {
                Button("Delete \(selected.count)\u{2026}") {
                    let picked = shown.filter { selected.contains($0.id) }.compactMap(\.item)
                    CleanupBatchWindow.open(picked, emby: emby)
                }
                .buttonStyle(ServerDangerButton()).disabled(selected.isEmpty)
            }
            Button(selecting ? "Done" : "Select") { selecting.toggle(); if !selecting { selected = [] } }
                .buttonStyle(AboutButton())
            Button { Task { await store.load(emby, force: true) } } label: {
                Image(systemName: "arrow.clockwise").cvFont(13, weight: .semibold)
                    .frame(width: 36, height: 36).modifier(ClassicClearGlass(shape: Circle()))
            }
            .buttonStyle(.plainHand).disabled(store.loading).helpLabel("Refresh")
        }
        if !store.items.isEmpty {
            HStack(spacing: 8) {
                Text(Cleanup.summary(shown).text).cvFont(Glass3DTokens.Text.meta, weight: .medium) { $0.monospacedDigit() }
                    .foregroundColor(Glass3DTokens.Grey.secondary)
                if store.loading, let p = store.progress {
                    ProgressView().controlSize(.mini)
                    Text(p).cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.tertiary)
                }
            }
        }
    }
}

/// One compact glass dropdown pill (icon + current value + ⌄), ✓ on the current option.
struct CleanupMenu<V: Hashable>: View {
    let symbol: String
    let value: String
    let options: [(V, String)]
    let selected: V
    let help: String
    let pick: (V) -> Void
    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Toggle(o.1, isOn: Binding(get: { selected == o.0 }, set: { if $0 { pick(o.0) } }))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).cvFont(12, weight: .semibold)
                Text(value).cvFont(13, weight: .semibold).lineLimit(1)
                Image(systemName: "chevron.down").cvFont(10, weight: .bold).opacity(0.8)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .modifier(ClassicClearGlass(shape: Capsule()))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .helpLabel(help)
    }
}

struct CleanupRow: View {
    let entry: CleanupItem
    let libraryName: String?
    let selecting: Bool
    @Binding var selected: Bool
    @EnvironmentObject var emby: Emby
    @State private var hover = false
    @State private var showUsers = false

    var body: some View {
        HStack(spacing: 14) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").cvFont(18)
                    .foregroundColor(selected ? .accentColor : Glass3DTokens.Grey.tertiary)
            }
            CachedImage(url: emby.image(entry.id, width: 120)) { p in p.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Color(white: 0.15) }
                .frame(width: 40, height: 60).clipped().cornerRadius(Glass3DTokens.Radius.thumb)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).cvFont(13, weight: .bold).foregroundColor(.white).lineLimit(1)
                    if let y = entry.year { Text(String(y)).cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary) }
                }
                Text([libraryName, entry.isSeries ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                    .cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary).lineLimit(1)
            }
            Spacer(minLength: 12)
            watchedPill
            if let mine = entry.myRating {
                Text("\u{2605} \(mine)/10").cvFont(12, weight: .semibold) { $0.monospacedDigit() }.foregroundColor(.yellow)
                    .lineLimit(1).frame(width: 60, alignment: .trailing)
                    .tip("Your rating" + (entry.communityRating.map { " \u{00B7} server \(String(format: "%.1f", $0))" } ?? ""))
            } else {
                column(entry.communityRating.map { "\u{2605} " + String(format: "%.1f", $0) } ?? "\u{2605} \u{2014}", width: 60,
                   tip: entry.criticRating.map { "Critics \(Int($0))%" } ?? "Community rating")
            }
            column(entry.dateAdded.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "\u{2014}", width: 96, tip: "Date added")
            column(CleanupItem.lastPlayedText(entry), width: 90, tip: CleanupItem.lastPlayedTip(entry))
            column(entry.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "", width: 70, tip: "Size")
            if !selecting, let item = entry.item {
                Button { DeleteEverywhereWindow.open(item, emby: emby) } label: {
                    Image(systemName: "trash").cvFont(13, weight: .semibold).foregroundColor(.white)
                        .frame(width: 30, height: 30).modifier(ClassicClearGlass(shape: Circle()))
                }
                .buttonStyle(.plainHand).helpLabel("Delete\u{2026}")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row).fill(Color.white.opacity(hover ? 0.08 : 0.03)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if selecting { selected.toggle() } else if let item = entry.item { ClassicNavState.shared.open(item) }
        }
    }

    private func column(_ text: String, width: CGFloat, tip: String) -> some View {
        Text(text).cvFont(12) { $0.monospacedDigit() }.foregroundColor(Glass3DTokens.Grey.secondary)
            .lineLimit(1).frame(width: width, alignment: .trailing).tip(tip)
    }

    /// The #259 pill look ("👁 0/10"); a click shows the per-user list.
    private var watchedPill: some View {
        Button { showUsers.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye").cvFont(11, weight: .semibold)
                Text(entry.watchedText).cvFont(11, weight: .semibold) { $0.monospacedDigit() }
            }
            .foregroundColor(.white).padding(.horizontal, 10).frame(height: 26)
            .classicGlassPill(iconOnly: false).contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .tip(entry.watchedBy.isEmpty ? "Nobody watched it" : "Watched by " + entry.watchedBy.joined(separator: ", "))
        .popover(isPresented: $showUsers, arrowEdge: .bottom) {
            if let item = entry.item {
                WatchActivityList(item: item, data: WatchActivityData(entries: entry.entries, dateAdded: entry.dateAdded, loadedAt: Date()),
                                  folder: entry.isSeries)
            }
        }
    }
}

// MARK: - Delete several

@MainActor
enum CleanupBatchWindow {
    static func open(_ items: [Item], emby: Emby) {
        guard !items.isEmpty else { return }
        let id = "admin-delete-batch"
        ItemAdminWindows.show(id, title: "Delete", size: NSSize(width: 520, height: 580), emby: emby,
                              CleanupBatchView(items: items, close: { ItemAdminWindows.close(id) }))
    }
}

struct CleanupBatchView: View {
    let items: [Item]
    let close: () -> Void
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var plans: [DeleteEverywhereService.Plan] = []
    @State private var checking = true
    @State private var busy = false
    @State private var progress: String?
    @State private var error: String?

    private var permanent: [DeleteEverywhereService.Plan] { plans.filter { !$0.inNexcrate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItemAdminHeader(title: "Delete \(items.count) title" + (items.count == 1 ? "" : "s") + "\u{2026}")
            if checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress ?? "Checking nexcrate and the server\u{2026}").cvFont(13).foregroundColor(.white.opacity(0.8))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { content }
        }
        .padding(.horizontal, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            var out: [DeleteEverywhereService.Plan] = []
            for (n, i) in items.enumerated() {
                progress = "Checking \(n + 1) of \(items.count)\u{2026}"
                out.append(await DeleteEverywhereService.prepare(i, emby: emby))
            }
            plans = out; checking = false; progress = nil
        }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plans, id: \.item.id) { p in
                    HStack {
                        Text(p.text.scopeLine).cvFont(13).foregroundColor(.white).lineLimit(1)
                        Spacer()
                        Text(p.inNexcrate ? "Undo 7 days" : "Permanent").cvFont(11, weight: .semibold)
                            .foregroundColor(p.inNexcrate ? .green : .orange)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260).itemAdminCard()
        if !permanent.isEmpty {
            Text("Not in nexcrate, deleted from the server for good (no undo): " + permanent.map(\.item.Name).joined(separator: ", "))
                .cvFont(13, weight: .semibold).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.9), lineWidth: 1))
        }
        if let m = plans.compactMap(\.lookupProblem).first { Text(m).cvFont(12).foregroundColor(.orange) }
        if let progress { Text(progress).cvFont(12).foregroundColor(.white.opacity(0.8)) }
        if let error { Text(error).cvFont(12, weight: .semibold).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
        Spacer(minLength: 0)
        HStack {
            Spacer()
            Button("Cancel") { close() }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction).disabled(busy)
            Button {
                busy = true; error = nil
                Task { await run() }
            } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.mini) }; Text("Delete \(plans.count)") }
            }
            .buttonStyle(ServerDangerButton()).disabled(busy || plans.isEmpty)
        }
        .focusEffectDisabled()   // no blue focus ring on Cancel
    }

    private func run() async {
        let byId = Dictionary(uniqueKeysWithValues: plans.map { ($0.item.id, $0) })
        var recs: [DeletionRecord] = []
        let r = await CleanupDeleteQueue.run(plans.map(\.item.id), progress: { n, total in
            progress = "Deleting \(n + 1) of \(total)\u{2026}"
        }) { id in
            guard let p = byId[id] else { return nil }
            let o = await DeleteEverywhereService.perform(p, emby: emby)
            if let rec = o.record { recs.append(rec) }
            return o.error
        }
        busy = false; progress = nil
        if !r.done.isEmpty {
            let title = "Deleted \(r.done.count)" + (r.done.count == 1 ? " title" : " titles")
            if recs.isEmpty { emby.toast = Emby.Toast(text: title + " from the server", icon: "trash") }
            else { DeleteUndoToast.show(recs, title: title, emby: emby) }
        }
        if let f = r.failed {
            let name = byId[f.id]?.item.Name ?? ""
            error = "Stopped at \u{201C}\(name)\u{201D}: \(f.message)" + (r.skipped.isEmpty ? "" : " \(r.skipped.count) not deleted.")
            plans = plans.filter { !r.done.contains($0.item.id) }
        } else { close() }
    }
}
