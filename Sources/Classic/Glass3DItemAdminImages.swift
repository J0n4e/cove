import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edit images: one section per kind the item supports (poster, backdrops, logo…), each with the current picture(s)
/// (as Cove shows them), Delete (asks first), Browse online and Upload… (or drop a JPEG/PNG on the section).
struct ItemImagesView: View {
    let item: Item
    var onChange: () -> Void = {}
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var current: [String: [String]] = [:]
    @State private var loaded = false
    @State private var busy: String?
    @State private var error = ""
    @State private var confirmDelete: String?   // "type|index"
    @State private var browsing: String?        // the kind whose online choices are shown

    var types: [String] { ItemAdminAPI.imageTypes(item.`Type`) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemAdminHeader(title: browsing.map { "Online \(ItemAdminAPI.typeTitle($0).lowercased())" } ?? "Edit Images",
                            subtitle: item.Name)
            if !error.isEmpty { Text(error).cvFont(11).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if let b = browsing {
                ItemRemoteImagesView(item: item, type: b, back: { browsing = nil }, picked: { img in download(b, img) })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !loaded { Spinner().frame(maxWidth: .infinity).padding(.top, 40) }
                        else { ForEach(types, id: \.self) { section($0) } }
                    }.padding(.bottom, 16)
                }.classicScrollBars()
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
        .foregroundColor(.white)
        .task { await reload() }
    }

    func reload() async {
        if let r = await ItemAdminService.record(item.id, emby: emby) { current = ItemAdminAPI.currentImages(r); error = "" }
        else if !loaded { error = "Couldn't read the item's pictures from the server." }
        loaded = true
    }

    /// After any change: the item's tags are read again everywhere and the page is told.
    func changed() async {
        await reload()
        await ItemAdminService.reloadItem(item.id, emby: emby)
        onChange()
    }

    func url(_ type: String, _ i: Int, _ tag: String) -> URL? {
        URL(string: emby.server + ItemAdminAPI.imagePath(itemId: item.id, type: type, index: i, tag: tag,
                                                         maxWidth: type == "Primary" ? 300 : 480))
    }

    func section(_ type: String) -> some View {
        let tags = current[type] ?? []
        let tall = type == "Primary" || type == "Disc"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ItemAdminAPI.typeTitle(type)).cvFont(14, weight: .semibold)
                if busy == type { Spinner().controlSize(.small) }
                Spacer()
                Button("Browse online") { browsing = type }.buttonStyle(AboutButton(accentName: accentName))
                Button(ItemAdminAPI.isMultiple(type) && !tags.isEmpty ? "Add…" : "Upload…") { choose(type) }
                    .buttonStyle(AboutButton(accentName: accentName))
            }
            if tags.isEmpty {
                Text("None – drop a JPEG or PNG here, upload one or browse online.").cvFont(11).foregroundColor(.white.opacity(0.55))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { i, tag in
                            VStack(spacing: 6) {
                                ItemAdminThumb(url: url(type, i, tag)).frame(width: tall ? 110 : 200, height: tall ? 165 : 112)
                                deleteButton(type, i)
                            }
                        }
                    }
                }
            }
        }
        .itemAdminCard()
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first, let d = try? Data(contentsOf: u) else { return false }
            upload(type, d); return true
        }
    }

    @ViewBuilder func deleteButton(_ type: String, _ i: Int) -> some View {
        let key = "\(type)|\(i)"
        if confirmDelete == key {
            HStack(spacing: 6) {
                Button("Delete") { delete(type, i) }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                Button("Keep") { confirmDelete = nil }.buttonStyle(AboutButton(accentName: accentName))
            }
        } else {
            Button { confirmDelete = key } label: { Label("Delete", systemImage: "trash").cvFont(11) }
                .buttonStyle(AboutButton(accentName: accentName)).disabled(busy != nil)
        }
    }

    func choose(_ type: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.jpeg, .png]
        p.allowsMultipleSelection = false
        p.message = "Choose a JPEG or PNG for the \(ItemAdminAPI.typeTitle(type).lowercased())"
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        upload(type, d)
    }

    func upload(_ type: String, _ data: Data) {
        guard let req = ItemAdminAPI.upload(itemId: item.id, type: type, data: data) else {
            error = "That file isn't a JPEG or PNG picture."; return
        }
        run(type, req, action: "upload the picture", done: "Picture uploaded")
    }

    func delete(_ type: String, _ i: Int) {
        confirmDelete = nil
        run(type, ItemAdminAPI.deleteImage(itemId: item.id, type: type, index: i), action: "delete the picture", done: "Picture deleted")
    }

    func download(_ type: String, _ img: ItemAdminAPI.RemoteImage) {
        browsing = nil
        run(type, ItemAdminAPI.download(itemId: item.id, type: type, image: img), action: "download the picture", done: "Picture saved")
    }

    func run(_ type: String, _ req: ItemAdminAPI.Request, action: String, done: String) {
        busy = type; error = ""
        Task { @MainActor in
            let err = await ItemAdminService.send(req, emby: emby, action: action, timeout: 90)
            if let err { error = err } else {
                await changed()
                emby.toast = Emby.Toast(text: done, icon: "checkmark.circle.fill")
            }
            busy = nil
        }
    }
}

/// The providers' pictures for one kind: thumbnail, resolution, language, rating, provider. Raw provider images
/// (no server enhancers), since they aren't on the server yet.
struct ItemRemoteImagesView: View {
    let item: Item
    let type: String
    let back: () -> Void
    let picked: (ItemAdminAPI.RemoteImage) -> Void
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var images: [ItemAdminAPI.RemoteImage] = []
    @State private var providers: [String] = []
    @State private var provider = ""
    @State private var allLanguages = false
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { back() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(AboutButton(accentName: accentName))
                if providers.count > 1 {
                    GlassPicker(selection: $provider, options: [("", "All providers")] + providers.map { ($0, $0) })
                }
                Toggle(isOn: $allLanguages) { Text("All languages").cvFont(12) }.toggleStyle(.checkbox)
                Spacer()
                if loading { Spinner().controlSize(.small) }
                Text("\(images.count) pictures").cvFont(11).foregroundColor(.white.opacity(0.6))
            }
            if !error.isEmpty { Text(error).cvFont(11).foregroundColor(.orange) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: type == "Primary" ? 130 : 210), spacing: 12)], spacing: 12) {
                    ForEach(images) { img in
                        Button { picked(img) } label: { tile(img) }.buttonStyle(HoverButton())
                    }
                }.padding(.bottom, 12)
            }.classicScrollBars()
        }
        .task(id: provider + "|\(allLanguages)") { await load() }
    }

    func tile(_ img: ItemAdminAPI.RemoteImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ItemAdminThumb(url: URL(string: img.thumbnailURL ?? img.url))
                .frame(height: type == "Primary" ? 190 : 118)
            Text([img.resolution, img.language?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                .cvFont(10).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            Text([img.provider, img.rating.map { String(format: "★ %.1f", $0) + (img.votes.map { " (\($0))" } ?? "") }]
                .compactMap { $0 }.joined(separator: " · "))
                .cvFont(10).foregroundColor(.white.opacity(0.55)).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.row).fill(Color.white.opacity(Glass3DTokens.Fill.subtle)))
    }

    func load() async {
        loading = true; error = ""
        var out: (images: [ItemAdminAPI.RemoteImage], providers: [String]) = ([], [])
        let err = await ItemAdminService.send(ItemAdminAPI.remoteImages(itemId: item.id, type: type, allLanguages: allLanguages,
                                                                        provider: provider.isEmpty ? nil : provider),
                                              emby: emby, action: "load the online pictures", timeout: 60) { out = ItemAdminAPI.decodeRemoteImages($0) }
        out.images = ItemAdminAPI.sortImages(out.images)
        guard !Task.isCancelled else { return }
        images = out.images
        if provider.isEmpty, !out.providers.isEmpty { providers = out.providers }
        if let err { error = err } else if images.isEmpty { error = "The providers have no \(ItemAdminAPI.typeTitle(type).lowercased()) for this item." }
        loading = false
    }
}
