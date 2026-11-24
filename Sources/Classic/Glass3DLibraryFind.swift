import SwiftUI

/// "Find to edit…" next to the library page's admin ⋯ (admins only): a compact glass search field that widens
/// to ~260 pt when clicked. Typing searches this library (250 ms debounce); the results drop down under it
/// (thumb, name, year, kind). Click, or ↑/↓ and Return, opens Edit metadata for that item. Esc clears.
struct LibraryFindField: View {
    let lib: LibPref
    @EnvironmentObject var emby: Emby
    @ObservedObject private var profile = ProfileModel.shared
    @AppStorage("accent") private var accentName = "red"
    @FocusState private var focused: Bool
    @State private var open = false
    @State private var term = ""
    @State private var hits: [MetadataEditorAPI.Hit] = []
    @State private var selected: Int?
    @State private var searching = false
    @State private var showResults = false

    var body: some View {
        if !ItemAdminAPI.libraryMenu(kind: lib.kind, admin: profile.admin).isEmpty {
            field
        }
    }

    var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").cvFont(13, weight: .semibold).foregroundColor(.white.opacity(0.8))
            if open {
                TextField("Find to edit…", text: $term)
                    .textFieldStyle(.plain).cvFont(13).foregroundColor(.white)
                    .focused($focused)
                    .onSubmit { pick(selected ?? (hits.isEmpty ? nil : 0)) }
                    .onKeyPress(.downArrow) { selected = MetadataEditorAPI.moveSelection(selected, by: 1, count: hits.count); return .handled }
                    .onKeyPress(.upArrow) { selected = MetadataEditorAPI.moveSelection(selected, by: -1, count: hits.count); return .handled }
                    .onKeyPress(.escape) { reset(); return .handled }
                if searching { Spinner().controlSize(.mini) }
                if !term.isEmpty {
                    Button { term = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.6)) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, open ? 14 : 0)
        .frame(width: open ? 260 : 44, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.3)))
        .background(ClassicGlassBacking(shape: Capsule()))
        .contentShape(Capsule())
        .onTapGesture { if !open { withAnimation(.easeOut(duration: 0.18)) { open = true }; focused = true } }
        .helpLabel("Find an item in this library to edit its metadata")
        .onChange(of: focused) { _, f in if !f && term.isEmpty && !showResults { withAnimation(.easeOut(duration: 0.18)) { open = false } } }
        .task(id: term) { await search() }
        .popover(isPresented: $showResults, arrowEdge: .bottom) { results }
    }

    var results: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hits.isEmpty {
                Text(searching ? "Searching…" : "Nothing found in \(lib.title).").cvFont(12)
                    .foregroundColor(.white.opacity(0.65)).padding(12)
            }
            ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                Button { pick(i) } label: {
                    HStack(spacing: 10) {
                        ItemAdminThumb(url: emby.image(h.id, width: 80), placeholder: h.type == "Series" ? "tv" : "film")
                            .frame(width: 30, height: 45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name).cvFont(13, weight: .semibold).lineLimit(1)
                            Text(h.detail).cvFont(11).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field)
                        .fill(selected == i ? Theme.accent(accentName).opacity(0.35) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { selected = i } }
            }
        }
        .padding(6)
        .frame(width: 320)
        .foregroundColor(.white)
        .background(Color.black.opacity(0.55))
        .preferredColorScheme(.dark)
    }

    func search() async {
        guard let req = MetadataEditorAPI.search(userId: emby.userId, libraryId: lib.id, kind: lib.kind, term: term) else {
            hits = []; selected = nil; showResults = false; searching = false; return
        }
        try? await Task.sleep(for: .milliseconds(250))   // debounce: a new keystroke cancels this task
        if Task.isCancelled { return }
        searching = true
        var found: [MetadataEditorAPI.Hit] = []
        _ = await ItemAdminService.send(req, emby: emby, action: "search the library", timeout: 15) { found = MetadataEditorAPI.decodeHits($0) }
        if Task.isCancelled { return }
        searching = false
        hits = found
        selected = found.isEmpty ? nil : 0
        showResults = focused || !found.isEmpty
    }

    func pick(_ i: Int?) {
        guard let i, hits.indices.contains(i) else { return }
        let h = hits[i]
        showResults = false
        MetadataEditorWindow.open(h.id, name: h.name, parentId: lib.id, emby: emby)
    }

    func reset() {
        term = ""; hits = []; selected = nil; showResults = false; focused = false
        withAnimation(.easeOut(duration: 0.18)) { open = false }
    }
}
