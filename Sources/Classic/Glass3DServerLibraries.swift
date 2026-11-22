import SwiftUI

// MARK: - Libraries tab

struct ServerLibrariesTab: View {
    @StateObject private var model: ServerLibrariesModel
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var sheet: Sheet?
    @State private var message: String?

    enum Sheet: Identifiable {
        case add, addPath(AdminLibrary), removePath(AdminLibrary, String), rename(AdminLibrary), delete(AdminLibrary)
        var id: String {
            switch self {
            case .add: return "add"
            case .addPath(let l): return "ap" + l.id
            case .removePath(let l, let p): return "rp" + l.id + p
            case .rename(let l): return "rn" + l.id
            case .delete(let l): return "dl" + l.id
            }
        }
    }

    init(admin: ServerAdmin) { _model = StateObject(wrappedValue: ServerLibrariesModel(kind: admin.kind, api: admin.api)) }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let m = message { Text(m).cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).lineLimit(2) }
                    Spacer()
                    Button { sheet = .add } label: { Label("Add library…", systemImage: "plus.rectangle.on.folder") }
                        .buttonStyle(AboutButton(primary: true, accentName: accentName))
                }
                if let e = model.error, model.libraries.isEmpty {
                    ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
                } else if !model.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) { ForEach(model.libraries) { card($0) }; RecentlyDeletedCard() }.padding(.bottom, 8)
                    }.scrollIndicators(.never)
                }
            }
            if let s = sheet { ServerLibrarySheet(model: model, sheet: s) { result in
                sheet = nil
                if let result { message = result }
            } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
    }

    func card(_ l: AdminLibrary) -> some View {
        ServerAdminCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: l.icon).cvFont(20).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.name).cvFont(15, weight: .bold).foregroundColor(.white)
                    Text(meta(l)).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                    if l.refreshing {
                        HStack(spacing: 8) {
                            ServerProgressBar(percent: l.refreshProgress ?? 0).frame(maxWidth: 200)
                            Text("Scanning").cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                        }
                    }
                }
                Spacer()
                GlassListButton(list: {
                    let acts = actions(l)
                    return (acts.map { $0.0 }, Set<Int>(), Set<Int>(), { i in if i >= 0 && i < acts.count { acts[i].1() } })
                }) {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: 30, height: 30).classicGlassPill()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(l.paths, id: \.self) { p in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary)
                        Text(p).cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { sheet = .removePath(l, p) } label: { Image(systemName: "minus.circle").foregroundColor(Glass3DTokens.Grey.secondary) }
                            .buttonStyle(.plainHand).help("Remove this folder from the library")
                    }
                }
                if l.paths.isEmpty { Text("No folders").cvFont(12).foregroundColor(Glass3DTokens.Grey.tertiary) }
            }.padding(.leading, 40)
            HStack(spacing: 8) {
                Spacer()
                Button { scan(l) } label: { Label("Scan", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(AboutButton(accentName: accentName)).disabled(l.itemId.isEmpty)
                Button { sheet = .addPath(l) } label: { Label("Add folder…", systemImage: "folder.badge.plus") }
                    .buttonStyle(AboutButton(accentName: accentName))
            }
        }
    }

    func meta(_ l: AdminLibrary) -> String {
        var parts = [l.typeTitle]
        if let n = model.counts[l.id] { parts.append(n == 1 ? "1 item" : "\(n) items") }
        if let lang = l.metadataLanguage { parts.append("Metadata: " + lang + (l.countryCode.map { "-" + $0 } ?? "")) }
        return parts.joined(separator: " · ")
    }

    func actions(_ l: AdminLibrary) -> [(String, () -> Void)] {
        var a: [(String, () -> Void)] = []
        if let item = LibraryAdminAPI.item(l), !l.itemId.isEmpty {
            a.append(("Refresh metadata…", { ItemAdminWindows.refresh(item, emby: emby) }))
        }
        if LibraryAdminAPI.offersMissing(l), !l.itemId.isEmpty {
            a.append((ItemAdminAPI.Missing.poster.title, { ItemAdminWindows.missing(.poster, lib: LibraryAdminAPI.libPref(l), emby: emby) }))
            a.append((ItemAdminAPI.Missing.backdrop.title, { ItemAdminWindows.missing(.backdrop, lib: LibraryAdminAPI.libPref(l), emby: emby) }))
        }
        a.append(("Rename library…", { sheet = .rename(l) }))
        a.append(("Delete library…", { sheet = .delete(l) }))
        return a
    }

    func scan(_ l: AdminLibrary) {
        Task {
            let e = await model.run(LibraryAdminAPI.scan(l), action: "start the scan", reload: false)
            message = e ?? "Scanning \u{201C}\(l.name)\u{201D}…"
            if e == nil { try? await Task.sleep(nanoseconds: 2_000_000_000); await model.load() }
        }
    }
}

/// The add / rename / folder / delete sheets. `done(nil)` = cancelled, `done(text)` = finished with that line.
struct ServerLibrarySheet: View {
    @ObservedObject var model: ServerLibrariesModel
    let sheet: ServerLibrariesTab.Sheet
    let done: (String?) -> Void
    @AppStorage("accent") private var accentName = "red"
    @State private var name = ""
    @State private var path = ""
    @State private var typeIndex = 0
    @State private var typed = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        ServerSheet(width: 480, dismiss: { done(nil) }) {
            switch sheet {
            case .add:
                title("Add library")
                ServerField(title: "Name", text: $name)
                HStack {
                    Text("Content type").cvFont(13).foregroundColor(.white)
                    Spacer()
                    GlassPicker(selection: $typeIndex, options: LibraryAdminAPI.addTypes.enumerated().map { ($0.offset, $0.element.title) })
                }
                ServerField(title: "First folder (path on the server)", text: $path)
                serverPathHint
                Text("Metadata language: English (US). Change it later in the server's dashboard if needed.")
                    .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
            case .addPath(let l):
                title("Add folder to \u{201C}\(l.name)\u{201D}")
                ServerField(title: "Folder (path on the server)", text: $path)
                serverPathHint
            case .removePath(let l, let p):
                title("Remove this folder?")
                Text("\u{201C}\(p)\u{201D} will no longer be part of \u{201C}\(l.name)\u{201D}. Its files stay on the disk; the items disappear from the library.")
                    .cvFont(13).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
            case .rename(let l):
                title("Rename \u{201C}\(l.name)\u{201D}")
                ServerField(title: "New name", text: $name)
            case .delete(let l):
                title("Delete \u{201C}\(l.name)\u{201D}?")
                Text("The library and its items are removed from the server (the files on disk stay). Type the library's name to confirm.")
                    .cvFont(13).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
                TextField(l.name, text: $typed).textFieldStyle(.roundedBorder).cvFont(13)
            }
            if !error.isEmpty { Text(error).cvFont(12).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                if danger {
                    Button(actionTitle) { go() }.buttonStyle(ServerDangerButton()).disabled(busy || !ready)
                } else {
                    Button(actionTitle) { go() }.buttonStyle(AboutButton(primary: true, accentName: accentName)).disabled(busy || !ready)
                }
            }
        }
        .onAppear { if case .rename(let l) = sheet { name = l.name } }
    }

    var serverPathHint: some View {
        Text("This is a path on the SERVER's machine (e.g. /mnt/media/Movies or D:\\Movies), not on this Mac.")
            .cvFont(11).foregroundColor(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
    }

    func title(_ t: String) -> some View { Text(t).cvFont(17, weight: .bold).foregroundColor(.white) }

    var danger: Bool {
        switch sheet { case .removePath, .delete: return true; default: return false }
    }

    var actionTitle: String {
        switch sheet {
        case .add: return "Add library"
        case .addPath: return "Add folder"
        case .removePath: return "Remove"
        case .rename: return "Rename"
        case .delete: return "Delete library"
        }
    }

    var ready: Bool {
        let p = !path.trimmingCharacters(in: .whitespaces).isEmpty
        switch sheet {
        case .add: return LibraryAdminAPI.validName(name) && p
        case .addPath: return p
        case .removePath: return true
        case .rename(let l): return LibraryAdminAPI.validName(name) && name.trimmingCharacters(in: .whitespaces) != l.name
        case .delete(let l): return typed.trimmingCharacters(in: .whitespacesAndNewlines) == l.name
        }
    }

    func go() {
        let (req, action, ok): (AdminRequest, String, String) = {
            switch sheet {
            case .add:
                let t = LibraryAdminAPI.addTypes[min(typeIndex, LibraryAdminAPI.addTypes.count - 1)].type
                return (LibraryAdminAPI.addLibrary(name: name, type: t, path: path, kind: model.kind), "add the library",
                        "Added \u{201C}\(name)\u{201D}. The server is scanning it.")
            case .addPath(let l):
                return (LibraryAdminAPI.addPath(library: l.name, path: path), "add the folder", "Added the folder to \u{201C}\(l.name)\u{201D}.")
            case .removePath(let l, let p):
                return (LibraryAdminAPI.removePath(library: l.name, path: p), "remove the folder", "Removed the folder from \u{201C}\(l.name)\u{201D}.")
            case .rename(let l):
                return (LibraryAdminAPI.rename(l.name, to: name), "rename the library", "Renamed to \u{201C}\(name)\u{201D}.")
            case .delete(let l):
                return (LibraryAdminAPI.delete(l.name), "delete the library", "Deleted \u{201C}\(l.name)\u{201D}.")
            }
        }()
        busy = true; error = ""
        Task {
            let e = await model.run(req, action: action)
            busy = false
            if let e { error = e } else { done(ok) }
        }
    }
}
