import SwiftUI

/// Items without poster / backdrop in one library: every movie, show and collection is paged through (neither
/// server can filter on a missing image) and the ones without it are listed, each with Edit images, Refresh
/// metadata and Identify, plus "Refresh all" (two at a time, with progress).
struct ItemMissingView: View {
    let kind: ItemAdminAPI.Missing
    let lib: LibPref
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var rows: [ItemAdminAPI.MissingRow] = []
    @State private var scanned = 0
    @State private var total: Int?
    @State private var scanning = true
    @State private var error = ""
    @State private var refreshing = false
    @State private var done = 0
    @State private var fixed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemAdminHeader(title: kind.title, subtitle: lib.title)
            HStack {
                Text(status).cvFont(12).foregroundColor(.white.opacity(0.7))
                if scanning || refreshing { Spinner().controlSize(.small) }
                Spacer()
                Button(refreshing ? "Refreshing \(done) of \(rows.count)…" : "Refresh all missing") { refreshAll() }
                    .buttonStyle(AboutButton(primary: true, accentName: accentName))
                    .disabled(rows.isEmpty || scanning || refreshing).opacity(rows.isEmpty || scanning ? 0.5 : 1)
            }
            if !error.isEmpty { Text(error).cvFont(11).foregroundColor(.orange) }
            ScrollView {
                LazyVStack(spacing: 8) { ForEach(rows) { row($0) } }.padding(.bottom, 12)
            }.classicScrollBars()
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
        .foregroundColor(.white)
        .task { await scan() }
    }

    var status: String {
        if scanning { return "Checking \(scanned)\(total.map { " of \($0)" } ?? "") items…" }
        return rows.isEmpty ? "Every item has a \(kind == .poster ? "poster" : "backdrop")." : "\(rows.count) items"
    }

    func scan() async {
        scanning = true; rows = []; scanned = 0
        var start = 0
        let limit = 300
        while !Task.isCancelled {
            var page: (rows: [ItemAdminAPI.MissingRow], pageCount: Int, total: Int?) = ([], 0, nil)
            let err = await ItemAdminService.send(ItemAdminAPI.missingPage(userId: emby.userId, libraryId: lib.id, start: start, limit: limit),
                                                  emby: emby, action: "read the library", timeout: 60) { page = ItemAdminAPI.decodeMissing($0, kind) }
            if let err { error = err; break }
            rows += page.rows
            scanned += page.pageCount
            total = page.total ?? total
            start += page.pageCount
            if page.pageCount < limit || (total.map { start >= $0 } ?? false) { break }
        }
        scanning = false
    }

    func item(_ r: ItemAdminAPI.MissingRow) -> Item? {
        let o: [String: Any] = ["Id": r.id, "Name": r.name, "Type": r.type as Any, "ProductionYear": r.year as Any]
        guard let d = try? JSONSerialization.data(withJSONObject: o.compactMapValues { $0 is NSNull ? nil : $0 }) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: d)
    }

    func row(_ r: ItemAdminAPI.MissingRow) -> some View {
        HStack(spacing: 12) {
            ItemAdminThumb(url: nil, placeholder: r.type == "Series" ? "tv" : "film").frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.name + (r.year.map { " (\($0))" } ?? "")).cvFont(13, weight: .semibold).lineLimit(1)
                    if fixed.contains(r.id) { Image(systemName: "checkmark.circle.fill").cvFont(12).foregroundColor(.green) }
                }
                if let p = r.path { Text(p).cvFont(10).foregroundColor(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            if let it = item(r) {
                Button("Edit images") { ItemAdminWindows.images(it, emby: emby) }.buttonStyle(AboutButton(accentName: accentName))
                Button("Refresh") { ItemAdminWindows.refresh(it, emby: emby) }.buttonStyle(AboutButton(accentName: accentName))
                if ItemAdminAPI.searchKind(r.type) != nil {
                    Button("Identify") { ItemAdminWindows.identify(it, emby: emby) }.buttonStyle(AboutButton(accentName: accentName))
                }
            }
        }
        .itemAdminCard()
    }

    /// "Search for missing metadata" on every listed item, two at a time; rows that got the picture get a ✓.
    func refreshAll() {
        refreshing = true; done = 0
        let list = rows
        let k = kind
        Task { @MainActor in
            var i = 0
            while i < list.count {
                let batch = Array(list[i..<min(i + 2, list.count)])
                await withTaskGroup(of: (String, Bool).self) { g in
                    for r in batch {
                        g.addTask { @MainActor in
                            _ = await ItemAdminService.refresh(r.id, name: r.name, mode: .missing, replaceImages: false,
                                                               emby: emby, toast: false)
                            let rec = await ItemAdminService.record(r.id, emby: emby)
                            return (r.id, rec.map { !ItemAdminAPI.isMissing($0, k) } ?? false)
                        }
                    }
                    for await (id, ok) in g { done += 1; if ok { fixed.insert(id) } }
                }
                i += 2
            }
            refreshing = false
            emby.toast = Emby.Toast(text: "\(fixed.count) of \(list.count) now have a \(k == .poster ? "poster" : "backdrop")",
                                    icon: "checkmark.circle.fill")
        }
    }
}
