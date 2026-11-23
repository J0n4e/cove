import AppKit
import SwiftUI

/// Opens the Edit metadata window (admins only; the callers only show the entry to admins).
@MainActor
enum MetadataEditorWindow {
    static func open(_ id: String, name: String, parentId: String? = nil, emby: Emby, onChange: @escaping () -> Void = {}) {
        guard ProfileModel.shared.admin == true else { return }
        let wid = "admin-metadata-" + id
        ItemAdminWindows.show(wid, title: "Edit Metadata", size: NSSize(width: 820, height: 700), emby: emby,
                              MetadataEditorView(itemId: id, title: name, parentId: parentId,
                                                 close: { ItemAdminWindows.close(wid) }, onChange: onChange))
    }
}

/// The editor: the server's full item JSON is loaded, a `Draft` of the editable fields is shown, and Save posts
/// the same JSON back with only the edited keys changed (MetadataEditorAPI.apply). A summary of the changes is
/// shown before saving.
struct MetadataEditorView: View {
    typealias API = MetadataEditorAPI
    let itemId: String
    let title: String
    var parentId: String?
    let close: () -> Void
    var onChange: () -> Void = {}
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var raw: [String: Any] = [:]
    @State private var original = API.Draft()
    @State private var d = API.Draft()
    @State private var loading = true
    @State private var busy = false
    @State private var error = ""
    @State private var confirming = false
    @State private var lockConfirm: Bool?
    @State private var ratings: [String] = []
    @State private var genreSugg: [String] = []
    @State private var tagSugg: [String] = []
    @State private var studioSugg: [String] = []

    var type: String? { raw["Type"] as? String }
    var isSeries: Bool { type == "Series" }
    var changes: String { API.summary(d, original: original) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ItemAdminHeader(title: "Edit Metadata", subtitle: [title, raw["Path"] as? String].compactMap { $0 }.joined(separator: " · "))
            if loading {
                Spacer(); HStack { Spacer(); Spinner(); Spacer() }; Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        general
                        chips("Genres", $d.genres, genreSugg, lock: "Genres")
                        chips("Tags", $d.tags, tagSugg, lock: "Tags")
                        chips("Studios", $d.studios, studioSugg, lock: "Studios")
                        PeopleEditor(people: $d.people)
                        externalIds
                        advanced
                    }.padding(.bottom, 12)
                }.classicScrollBars()
            }
            footer
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .foregroundColor(.white)
        .task { await load() }
        .keepsWindowOpen(busy || (!loading && d != original))
    }

    // MARK: Sections

    func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).cvFont(13, weight: .bold)
            c()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .itemAdminCard()
    }

    var general: some View {
        section("General") {
            HStack(spacing: 10) { field("Title", $d.name); field("Original title", $d.originalTitle) }
            HStack(spacing: 10) { field("Sort title", $d.sortName); field("Tagline", $d.tagline) }
            VStack(alignment: .leading, spacing: 3) {
                Text("Overview").cvFont(10).foregroundColor(.white.opacity(0.6))
                TextEditor(text: $d.overview).cvFont(12).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
            }
            HStack(spacing: 10) {
                field("Year", $d.year).frame(width: 80)
                field("Premiere date (YYYY-MM-DD)", $d.premiereDate)
                if isSeries || !d.endDate.isEmpty { field("End date (YYYY-MM-DD)", $d.endDate) }
                if isSeries {
                    menuField("Status", $d.status, [("", "—"), ("Continuing", "Continuing"), ("Ended", "Ended")])
                }
            }
            HStack(spacing: 10) {
                menuField("Parental rating", $d.officialRating,
                          [("", "None")] + (ratings.contains(d.officialRating) || d.officialRating.isEmpty ? [] : [(d.officialRating, d.officialRating)])
                            + ratings.map { ($0, $0) })
                menuField("Custom rating", $d.customRating, [("", "None")] + (ratings.contains(d.customRating) || d.customRating.isEmpty ? [] : [(d.customRating, d.customRating)])
                            + ratings.map { ($0, $0) })
                field("Community rating (0–10)", $d.communityRating)
                field("Critic rating (0–100)", $d.criticRating)
            }
        }
    }

    func chips(_ t: String, _ b: Binding<[String]>, _ sugg: [String], lock: String) -> some View {
        section(t) {
            ChipEditor(values: b, suggestions: sugg, placeholder: "Add \(t.lowercased().dropLast())…")
            if API.needsLockHint(d, original: original).contains(lock) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open").cvFont(11).foregroundColor(.orange)
                    Text("Lock \(t) so a refresh keeps your changes").cvFont(11).foregroundColor(.white.opacity(0.75))
                    Button("Lock \(t)") { if !d.lockedFields.contains(lock) { d.lockedFields.append(lock) } }
                        .buttonStyle(AboutButton(accentName: accentName))
                }
            }
        }
    }

    var externalIds: some View {
        section("External IDs") {
            ForEach(API.providerKeys(type, existing: original.providerIds), id: \.self) { k in
                HStack(spacing: 8) {
                    Text(API.providerTitle(k)).cvFont(12).frame(width: 130, alignment: .leading)
                    TextField(API.providerTitle(k) + " id", text: Binding(get: { d.providerIds[k] ?? "" }, set: { d.providerIds[k] = $0 }))
                        .textFieldStyle(.roundedBorder).cvFont(12)
                    if let u = API.providerURL(k, id: d.providerIds[k] ?? "", type: type) {
                        Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.plain).helpLabel("Open on \(API.providerTitle(k))")
                    } else { Color.clear.frame(width: 16, height: 1) }
                }
            }
        }
    }

    var advanced: some View {
        section("Advanced") {
            Toggle(isOn: Binding(get: { d.lockData }, set: { d.lockData = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock this item's metadata").cvFont(12, weight: .semibold)
                    Text("A metadata refresh then leaves every field alone.").cvFont(10).foregroundColor(.white.opacity(0.6))
                }
            }.toggleStyle(.switch)
            Text("Lock single fields").cvFont(11, weight: .semibold).foregroundColor(.white.opacity(0.75)).padding(.top, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                ForEach(API.lockableFields, id: \.key) { f in
                    Toggle(isOn: Binding(get: { d.lockedFields.contains(f.key) }, set: { on in
                        d.lockedFields.removeAll { $0 == f.key }
                        if on { d.lockedFields.append(f.key) }
                    })) { Text(f.title).cvFont(12) }.toggleStyle(.checkbox)
                }
            }
            HStack(spacing: 8) {
                Button("Lock all fields") { lockConfirm = true }.buttonStyle(AboutButton(accentName: accentName))
                Button("Unlock all fields") { lockConfirm = false }.buttonStyle(AboutButton(accentName: accentName))
                if let all = lockConfirm {
                    Text(all ? "Lock every field?" : "Unlock every field?").cvFont(11).foregroundColor(.orange)
                    Button("Yes") {
                        d.lockedFields = all ? API.lockableFields.map(\.key) : []
                        lockConfirm = nil
                    }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                    Button("No") { lockConfirm = nil }.buttonStyle(AboutButton(accentName: accentName))
                }
            }
            HStack(spacing: 10) {
                field("Preferred metadata language (e.g. en)", $d.language)
                field("Country (e.g. US)", $d.country)
                if isSeries || !d.displayOrder.isEmpty { field("Display order (e.g. aired, dvd, absolute)", $d.displayOrder) }
            }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if confirming {
                Text(changes.isEmpty ? "Nothing changed." : changes).cvFont(11).foregroundColor(.white.opacity(0.85))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty { Text(error).cvFont(11).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                if let it = asItem() {
                    Button("Refresh metadata…") { ItemAdminWindows.refresh(it, emby: emby, onChange: reloadAfterTool) }
                        .buttonStyle(AboutButton(accentName: accentName))
                    Button("Edit images…") { ItemAdminWindows.images(it, emby: emby, onChange: reloadAfterTool) }
                        .buttonStyle(AboutButton(accentName: accentName))
                    if ItemAdminAPI.searchKind(type) != nil {
                        Button("Identify…") { ItemAdminWindows.identify(it, emby: emby, onChange: reloadAfterTool) }
                            .buttonStyle(AboutButton(accentName: accentName))
                    }
                }
                Spacer()
                if busy { Spinner().controlSize(.small) }
                Button(confirming ? "Back" : "Cancel") { if confirming { confirming = false } else { close() } }
                    .buttonStyle(AboutButton(accentName: accentName))
                Button(confirming ? "Save changes" : "Save") { save() }
                    .buttonStyle(AboutButton(primary: true, accentName: accentName))
                    .disabled(busy || loading || changes.isEmpty).opacity(changes.isEmpty ? 0.5 : 1)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    // MARK: Fields

    func field(_ t: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).cvFont(10).foregroundColor(.white.opacity(0.6)).lineLimit(1)
            TextField(t, text: b).textFieldStyle(.roundedBorder).cvFont(12)
        }.frame(maxWidth: .infinity)
    }

    func menuField(_ t: String, _ b: Binding<String>, _ options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).cvFont(10).foregroundColor(.white.opacity(0.6)).lineLimit(1)
            Menu {
                ForEach(options, id: \.0) { o in Button(o.1) { b.wrappedValue = o.0 } }
            } label: {
                HStack {
                    Text(options.first { $0.0 == b.wrappedValue }?.1 ?? b.wrappedValue).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").cvFont(9, weight: .bold).opacity(0.7)
                }
                .cvFont(12).padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(Color.white.opacity(0.18)))
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }.frame(maxWidth: .infinity)
    }

    // MARK: Server

    func asItem() -> Item? {
        guard !raw.isEmpty, let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }

    func load() async {
        loading = true
        var item: [String: Any]?
        let err = await ItemAdminService.send(API.load(userId: emby.userId, itemId: itemId), emby: emby, action: "read the item") {
            item = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        guard let item else { error = err ?? "Couldn't read the item."; loading = false; return }
        raw = item
        original = API.draft(item)
        d = original
        loading = false
        confirming = false
        let lib = parentId
        async let r: [String] = names(API.parentalRatings())
        async let g: [String] = names(API.suggestions("Genres", userId: emby.userId, parentId: lib))
        async let t: [String] = names(API.suggestions("Tags", userId: emby.userId, parentId: lib))
        async let s: [String] = names(API.suggestions("Studios", userId: emby.userId, parentId: lib))
        (ratings, genreSugg, tagSugg, studioSugg) = await (r, g, t, s)
    }

    func names(_ req: API.Request) async -> [String] {
        var out: [String] = []
        _ = await ItemAdminService.send(req, emby: emby, action: "read the suggestions", timeout: 20) { out = API.decodeNames($0) }
        return out
    }

    func save() {
        if !confirming { confirming = true; return }
        busy = true; error = ""
        let body = API.apply(d, original: original, to: raw, emby: !emby.isJellyfin)
        guard let req = API.save(itemId: itemId, item: body) else { error = "Couldn't prepare the changes."; busy = false; return }
        Task { @MainActor in
            if let err = await ItemAdminService.send(req, emby: emby, action: "save the metadata") {
                error = err; busy = false; return
            }
            await ItemAdminService.reloadItem(itemId, emby: emby)
            onChange()
            emby.toast = Emby.Toast(text: "Saved \u{201C}\(d.name)\u{201D}", icon: "checkmark.circle.fill")
            busy = false
            await load()
        }
    }

    func reloadAfterTool() { onChange(); Task { await load() } }
}

// MARK: - Chips

/// Token chips with ×, a field to add one (Return or a suggestion), and suggestions from the server.
struct ChipEditor: View {
    @Binding var values: [String]
    let suggestions: [String]
    var placeholder = "Add…"
    @State private var entry = ""
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if values.isEmpty { Text("None").cvFont(11).foregroundColor(.white.opacity(0.5)) }
            ChipFlow(spacing: 6) {
                ForEach(values, id: \.self) { v in
                    HStack(spacing: 4) {
                        Text(v).cvFont(12)
                        Button { values.removeAll { $0 == v } } label: { Image(systemName: "xmark").cvFont(9, weight: .bold) }
                            .buttonStyle(.plain).helpLabel("Remove \(v)")
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.2)))
                }
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $entry).textFieldStyle(.roundedBorder).cvFont(12).frame(width: 220)
                    .onSubmit { add(entry) }
                ForEach(MetadataEditorAPI.suggest(entry, from: suggestions, excluding: values, limit: 5), id: \.self) { s in
                    Button(s) { add(s) }.buttonStyle(.plain).cvFont(11)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().stroke(Theme.accent(accentName).opacity(0.7)))
                }
            }
        }
    }

    func add(_ s: String) {
        values = MetadataEditorAPI.clean(values + [s])
        entry = ""
    }
}

/// A simple wrapping row for chips.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > w { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height)
        }
        return CGSize(width: w, height: subviews.isEmpty ? 0 : y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX && x + z.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}

// MARK: - People

struct PeopleEditor: View {
    @Binding var people: [MetadataEditorAPI.Person]
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var search = ""
    @State private var found: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People").cvFont(13, weight: .bold)
            if people.isEmpty { Text("None").cvFont(11).foregroundColor(.white.opacity(0.5)) }
            ForEach($people) { $p in
                let i = people.firstIndex { $0.id == p.id } ?? 0
                HStack(spacing: 6) {
                    TextField("Name", text: $p.name).textFieldStyle(.roundedBorder).cvFont(12)
                    TextField("Role", text: $p.role).textFieldStyle(.roundedBorder).cvFont(12)
                    Menu {
                        ForEach(MetadataEditorAPI.personTypes, id: \.self) { t in Button(t) { p.type = t } }
                    } label: { Text(p.type).cvFont(12) }
                        .menuStyle(.borderlessButton).frame(width: 100)
                    Button { move(p.id, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(i == 0)
                    Button { move(p.id, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(i == people.count - 1)
                    Button { let id = p.id; people.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).helpLabel("Remove")
                }
            }
            HStack(spacing: 6) {
                TextField("Add a person (search the server)…", text: $search).textFieldStyle(.roundedBorder).cvFont(12).frame(width: 260)
                    .onSubmit { add(search) }
                ForEach(found.prefix(4), id: \.self) { n in
                    Button(n) { add(n) }.buttonStyle(.plain).cvFont(11)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().stroke(Theme.accent(accentName).opacity(0.7)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .itemAdminCard()
        .task(id: search) {
            guard let req = MetadataEditorAPI.persons(term: search, userId: emby.userId) else { found = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            var out: [String] = []
            _ = await ItemAdminService.send(req, emby: emby, action: "search people", timeout: 15) { out = MetadataEditorAPI.decodeNames($0) }
            if !Task.isCancelled { found = out }
        }
    }

    func move(_ id: UUID, _ by: Int) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let j = i + by
        guard people.indices.contains(i), people.indices.contains(j) else { return }
        people.swapAt(i, j)
    }

    func add(_ n: String) {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        people.append(.init(name: t))
        search = ""; found = []
    }
}
