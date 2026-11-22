import AppKit
import SwiftUI

// Delete… UI (admins only): the Glass3D confirm window, the "Deleted · Undo" toast, the Recently deleted card
// (Manage server → Libraries) and the nexcrate card in Settings → Connect.

@MainActor
enum DeleteEverywhereWindow {
    static func open(_ item: Item, emby: Emby) {
        let id = "admin-delete-" + item.id
        ItemAdminWindows.show(id, title: "Delete", size: NSSize(width: 520, height: 560), emby: emby,
                              DeleteConfirmView(item: item, close: { ItemAdminWindows.close(id) }))
    }
}

struct DeleteConfirmView: View {
    let item: Item
    let close: () -> Void
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var plan: DeleteEverywhereService.Plan?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItemAdminHeader(title: "Delete\u{2026}", subtitle: item.SeriesName ?? item.Name)
            if let plan { content(plan) } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking nexcrate and the server\u{2026}").cvFont(13).foregroundColor(.white.opacity(0.8)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { plan = await DeleteEverywhereService.prepare(item, emby: emby) }
    }

    @ViewBuilder func content(_ p: DeleteEverywhereService.Plan) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ItemAdminThumb(url: URL(string: emby.server + "/Items/\(ItemAdminAPI.p(item.posterId))/Images/Primary?maxWidth=240&quality=85"),
                           placeholder: "film").frame(width: 96, height: 144)
            VStack(alignment: .leading, spacing: 6) {
                Text(p.text.scopeLine).cvFont(15, weight: .bold).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                if let s = p.sizeBytes, s > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).cvFont(12).foregroundColor(.white.opacity(0.7))
                }
                Text(p.inNexcrate ? "In nexcrate" : (p.configured ? "Not in nexcrate" : "nexcrate not connected"))
                    .cvFont(12, weight: .semibold).foregroundColor(p.inNexcrate ? .green : .white.opacity(0.7))
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(p.text.bullets, id: \.self) { Text($0).cvFont(13).foregroundColor(.white).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).itemAdminCard()
        if let w = p.text.warning {
            Text(w).cvFont(13, weight: .semibold).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.9), lineWidth: 1))
        }
        if let m = p.lookupProblem { Text(m).cvFont(12).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
        if let h = p.text.hint { Text(h).cvFont(12).foregroundColor(.white.opacity(0.7)) }
        if let error { Text(error).cvFont(12, weight: .semibold).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
        Spacer(minLength: 0)
        HStack {
            Spacer()
            Button("Cancel") { close() }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
            Button {
                busy = true; error = nil
                Task {
                    let m = await DeleteEverywhereService.run(p, emby: emby)
                    busy = false
                    if let m { error = m } else { close() }
                }
            } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.mini) }; Text(p.text.button) }
            }
            .buttonStyle(ServerDangerButton()).disabled(busy)
        }
    }
}

// MARK: - Toast with Undo (15 s)

@MainActor
enum DeleteUndoToast {
    private static var panel: NSPanel?
    private static var hide: Task<Void, Never>?

    static func show(_ rec: DeletionRecord, emby: Emby) { show([rec], title: "Deleted \u{201C}\(rec.name)\u{201D}", emby: emby) }

    /// One toast for several deletes (Activity → Cleanup): Undo restores every record.
    static func show(_ recs: [DeletionRecord], title: String, emby: Emby) {
        panel?.close()
        let size = NSSize(width: 380, height: 54)
        let host = NSHostingView(rootView: DeleteUndoToastView(recs: recs, title: title, dismiss: { dismiss() }).environmentObject(emby)
            .preferredColorScheme(.dark).frame(width: size.width, height: size.height))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = host
        if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            let f = main.frame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 40))
        } else { p.center() }
        p.orderFront(nil)
        panel = p
        hide?.cancel()
        hide = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { dismiss() } }
    }

    static func dismiss() { panel?.close(); panel = nil }
}

struct DeleteUndoToastView: View {
    let recs: [DeletionRecord]
    let title: String
    let dismiss: () -> Void
    @EnvironmentObject var emby: Emby
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundColor(.white)
            Text(note ?? title).cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(1)
            Spacer(minLength: 4)
            Button(busy ? "Undoing\u{2026}" : "Undo") {
                busy = true
                Task {
                    var m: String?
                    for rec in recs { if let e = await DeleteEverywhereService.undo(rec, emby: emby) { m = m ?? e } }
                    busy = false
                    let what = recs.count == 1 ? "\u{201C}\(recs[0].name)\u{201D}" : "\(recs.count) titles"
                    if let m { note = m } else { emby.toast = Emby.Toast(text: "Restored " + what, icon: "arrow.uturn.backward"); dismiss() }
                }
            }.buttonStyle(AboutButton(primary: true)).disabled(busy || recs.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Recently deleted (Manage server → Libraries)

struct RecentlyDeletedCard: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var store = DeletedItems.shared
    @State private var busy: String?
    @State private var message: String?

    var body: some View {
        let mine = store.records.filter { $0.server == emby.server.lowercased() }
        if !mine.isEmpty {
            ServerAdminCard(title: "Recently deleted") {
                ForEach(mine) { r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.what).cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(1)
                            Text("Deleted \(r.deletedAt.formatted(date: .abbreviated, time: .shortened)) · Undo until \(r.deletedAt.addingTimeInterval(DeletionStore.lifetime).formatted(date: .abbreviated, time: .omitted))")
                                .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                        }
                        Spacer()
                        Button(busy == r.id ? "Undoing\u{2026}" : "Undo") {
                            busy = r.id
                            Task {
                                message = await DeleteEverywhereService.undo(r, emby: emby) ?? "Restored \u{201C}\(r.name)\u{201D}."
                                busy = nil
                            }
                        }.buttonStyle(AboutButton()).disabled(busy != nil)
                    }
                }
                if let message { Text(message).cvFont(12).foregroundColor(Glass3DTokens.Grey.primary) }
            }
            .onAppear { store.reload() }
        }
    }
}

// MARK: - Settings → Connect: nexcrate

struct NexcrateSettingsSection: View {
    @ObservedObject private var conn = NexcrateConnection.shared
    @State private var addressDraft = NexcrateConnection.shared.address
    @State private var keyDraft = ""
    @State private var enteringKey = false
    @State private var testing = false

    var body: some View {
        PrefSection(title: "nexcrate") {
            PrefRow(label: "Address") {
                TextField("http://nas:8390", text: $addressDraft).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { conn.saveAddress(addressDraft) }
            }
            PrefRow(label: "Status") {
                VStack(alignment: .leading, spacing: 8) {
                    if let code = conn.pairingCode {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Confirm Cove in nexcrate: ").foregroundColor(.white) + Text(code).bold().foregroundColor(.white)
                        }
                    } else {
                        Text(conn.status ?? (conn.configured ? "Connected" + (conn.scopes.isEmpty ? "" : " · scopes: " + conn.scopes.joined(separator: ", ")) : "Not connected"))
                            .foregroundColor(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        if conn.pairingCode != nil {
                            Button("Cancel") { conn.cancelPairing() }
                        } else {
                            Button("Connect") { conn.saveAddress(addressDraft); conn.startPairing() }
                                .disabled(NexcrateAPI.normalizedAddress(addressDraft) == nil)
                            Button("Enter key\u{2026}") { enteringKey.toggle() }
                            if conn.configured {
                                Button(testing ? "Testing\u{2026}" : "Test") {
                                    testing = true; Task { await conn.test(); testing = false }
                                }.disabled(testing)
                                Button("Disconnect") { conn.disconnect() }
                            }
                        }
                    }
                    if enteringKey {
                        HStack(spacing: 8) {
                            SecureField("Paste a key from nexcrate", text: $keyDraft).textFieldStyle(.roundedBorder).frame(width: 240)
                            Button("Save") {
                                conn.saveAddress(addressDraft); conn.setKey(keyDraft); keyDraft = ""; enteringKey = false
                                Task { await conn.test() }
                            }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            PrefNote("Admins: Delete\u{2026} on a movie, series, season or episode goes through nexcrate when it has the title \u{2014} its torrents leave qBittorrent and the files sit in nexcrate's recycle bin for 7 days, so you can Undo. Connect asks nexcrate for a key (read + request); confirm the code there. The key is kept sealed on this Mac.")
        }
    }
}
