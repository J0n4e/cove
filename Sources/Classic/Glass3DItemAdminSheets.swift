import SwiftUI

/// Refresh metadata: the dashboards' three modes, Replace existing images, a confirm step for Replace all.
struct ItemRefreshView: View {
    let item: Item
    let close: () -> Void
    var onChange: () -> Void = {}
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var mode: ItemAdminAPI.RefreshMode = .missing
    @State private var replaceImages = false
    @State private var confirming = false
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItemAdminHeader(title: "Refresh Metadata", subtitle: item.Name)
            ForEach(ItemAdminAPI.RefreshMode.allCases) { m in
                Button { mode = m; confirming = false } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                            .cvFont(14).foregroundColor(mode == m ? Theme.accent(accentName) : .white.opacity(0.6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).cvFont(13, weight: .semibold)
                                .foregroundColor(m == .replaceAll ? Color(red: 1, green: 0.55, blue: 0.5) : .white)
                            Text(m.detail).cvFont(11).foregroundColor(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .itemAdminCard()
                }.buttonStyle(.plain)
            }
            Toggle(isOn: $replaceImages) { Text("Replace existing images").cvFont(12) }
                .toggleStyle(.checkbox).disabled(mode == .scan).opacity(mode == .scan ? 0.5 : 1)
            if confirming {
                Text("This overwrites all metadata of \u{201C}\(item.Name)\u{201D}, including your own edits. Continue?")
                    .cvFont(12).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty { Text(error).cvFont(11).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                if busy { Spinner().controlSize(.small) }
                Spacer()
                Button("Cancel") { close() }.buttonStyle(AboutButton(accentName: accentName))
                Button(confirming ? "Yes, replace all" : "Refresh") { start() }
                    .buttonStyle(AboutButton(primary: true, accentName: accentName)).disabled(busy)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
        .foregroundColor(.white)
        .keepsWindowOpen(busy)
    }

    func start() {
        if mode.needsConfirm && !confirming { confirming = true; return }
        busy = true; error = ""
        let (id, name, m, img) = (item.id, item.Name, mode, replaceImages)
        Task { @MainActor in
            // The item as it is now, then the request; on success the window closes and the toast follows the server
            let before = await ItemAdminService.record(id, emby: emby).map(ItemAdminAPI.snapshot)
            if let err = await ItemAdminService.send(ItemAdminAPI.refresh(itemId: id, mode: m, replaceImages: img),
                                                     emby: emby, action: "refresh the metadata") {
                error = err; busy = false; return
            }
            close()
            emby.toast = Emby.Toast(text: "Refreshing \u{201C}\(name)\u{201D}…", icon: "arrow.clockwise")
            let changed = await ItemAdminService.waitForChange(id, before: before, emby: emby, seconds: 60)
            await ItemAdminService.reloadItem(id, emby: emby)
            onChange()
            emby.toast = Emby.Toast(text: changed ? "Updated \u{201C}\(name)\u{201D}" : "Refresh started – the server is still working on it",
                                    icon: changed ? "checkmark.circle.fill" : "clock")
        }
    }
}

/// Identify: search the providers by name / year / ids, pick the right match, apply it.
struct ItemIdentifyView: View {
    let item: Item
    let close: () -> Void
    var onChange: () -> Void = {}
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var name = ""
    @State private var year = ""
    @State private var ids: [String: String] = [:]
    @State private var results: [ItemAdminAPI.SearchResult] = []
    @State private var searched = false
    @State private var busy = false
    @State private var error = ""
    @State private var picked: Int?

    var fields: [String] { ItemAdminAPI.providerFields(item.`Type`) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemAdminHeader(title: "Identify", subtitle: item.Name)
            HStack(spacing: 8) {
                field("Name", $name).frame(maxWidth: .infinity)
                field("Year", $year).frame(width: 70)
            }
            HStack(spacing: 8) {
                ForEach(fields, id: \.self) { k in
                    field(label(k), Binding(get: { ids[k] ?? "" }, set: { ids[k] = $0 }))
                }
            }
            HStack {
                if busy { Spinner().controlSize(.small) }
                if !error.isEmpty { Text(error).cvFont(11).foregroundColor(.orange).lineLimit(2) }
                Spacer()
                Button("Search") { search() }.buttonStyle(AboutButton(primary: picked == nil, accentName: accentName)).disabled(busy)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if searched && results.isEmpty && !busy {
                        Text("No matches. Try fewer words, without the year, or an IMDb / TMDb id.")
                            .cvFont(12).foregroundColor(.white.opacity(0.65)).padding(.top, 20)
                    }
                    ForEach(results) { r in row(r) }
                }
            }
            .classicScrollBars()
            HStack {
                Spacer()
                Button("Cancel") { close() }.buttonStyle(AboutButton(accentName: accentName))
                Button("Use this match") { apply() }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                    .disabled(picked == nil || busy).opacity(picked == nil ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
        .foregroundColor(.white)
        .onAppear {
            name = item.Name
            year = item.ProductionYear.map(String.init) ?? ""
            ids = (item.ProviderIds ?? [:]).filter { fields.contains($0.key) }
        }
        .keepsWindowOpen(busy)
    }

    func label(_ k: String) -> String { ["Imdb": "IMDb id", "Tmdb": "TMDb id", "Tvdb": "TVDb id"][k] ?? k }

    func field(_ title: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).cvFont(10).foregroundColor(.white.opacity(0.6))
            TextField(title, text: b).textFieldStyle(.roundedBorder).cvFont(12).onSubmit { search() }
        }
    }

    func row(_ r: ItemAdminAPI.SearchResult) -> some View {
        Button { picked = r.id } label: {
            HStack(alignment: .top, spacing: 12) {
                ItemAdminThumb(url: r.imageURL.flatMap(URL.init(string:)), placeholder: "film").frame(width: 60, height: 90)
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.name + (r.year.map { " (\($0))" } ?? "")).cvFont(13, weight: .semibold)
                    if let p = r.provider { Text(p).cvFont(10).foregroundColor(.white.opacity(0.55)) }
                    if let o = r.overview { Text(o).cvFont(11).foregroundColor(.white.opacity(0.75)).lineLimit(3) }
                }
                Spacer(minLength: 0)
                if picked == r.id { Image(systemName: "checkmark.circle.fill").cvFont(16).foregroundColor(Theme.accent(accentName)) }
            }
            .contentShape(Rectangle())
            .itemAdminCard()
            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card)
                .stroke(picked == r.id ? Theme.accent(accentName) : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }

    func search() {
        guard ItemAdminAPI.searchKind(item.`Type`) != nil else { return }
        busy = true; error = ""; picked = nil
        let (n, y, pids) = (name, Int(year.trimmingCharacters(in: .whitespaces)), ids)
        Task { @MainActor in
            // The library's metadata language (if set) for the results; otherwise English, not the server's UI language
            let lang = await ItemAdminService.libraryLanguage(item.id, emby: emby)
            guard let req = ItemAdminAPI.remoteSearch(itemId: item.id, type: item.`Type`, name: n, year: y, providerIds: pids,
                                                      metadataLanguage: lang?.language, countryCode: lang?.country) else { busy = false; return }
            var found: [ItemAdminAPI.SearchResult] = []
            let err = await ItemAdminService.send(req, emby: emby, action: "search the providers", timeout: 60) { found = ItemAdminAPI.decodeSearch($0) }
            results = found; searched = true; busy = false
            if let err { error = err }
        }
    }

    func apply() {
        guard let p = picked, let r = results.first(where: { $0.id == p }) else { return }
        busy = true; error = ""
        let (id, title) = (item.id, r.name)
        Task { @MainActor in
            let before = await ItemAdminService.record(id, emby: emby).map(ItemAdminAPI.snapshot)
            if let err = await ItemAdminService.send(ItemAdminAPI.apply(itemId: id, result: r), emby: emby,
                                                     action: "apply the match", timeout: 90) {
                error = err; busy = false; return
            }
            close()
            emby.toast = Emby.Toast(text: "Identified as \u{201C}\(title)\u{201D} – refreshing…", icon: "arrow.clockwise")
            _ = await ItemAdminService.waitForChange(id, before: before, emby: emby, seconds: 45)
            await ItemAdminService.reloadItem(id, emby: emby)
            onChange()
            emby.toast = Emby.Toast(text: "Updated \u{201C}\(title)\u{201D}", icon: "checkmark.circle.fill")
        }
    }
}
