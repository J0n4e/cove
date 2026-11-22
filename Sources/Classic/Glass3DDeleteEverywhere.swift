import AppKit
import SwiftUI

// Delete… UI (admins only): the Glass3D confirm window, the "Deleted · Undo" toast, the Recently deleted card
// (Manage server → Libraries) and the nexcrate card in Settings → Connect.

@MainActor
enum DeleteEverywhereWindow {
    private static var opening: Set<String> = []

    /// Checks nexcrate and the server first, then opens a window just as tall as its content (owner: no empty area).
    static func open(_ item: Item, emby: Emby) {
        let id = "admin-delete-" + item.id
        guard !opening.contains(id) else { return }
        opening.insert(id)
        Task { @MainActor in
            let plan = await DeleteEverywhereService.prepare(item, emby: emby)
            opening.remove(id)
            ItemAdminWindows.show(id, title: "Delete", size: NSSize(width: 470, height: height(for: plan)), emby: emby,
                                  DeleteConfirmView(item: item, initial: plan, close: { ItemAdminWindows.close(id) }))
        }
    }

    /// Title bar + poster block (with the buttons) + the effects card + warning / hints.
    static func height(for p: DeleteEverywhereService.Plan) -> CGFloat {
        var h: CGFloat = 28 + 8 + 124 + 16 + 28 + 18          // top inset, padding, header, gap, card padding, bottom
        let rows: [CGFloat] = p.text.bullets.map { DeleteEffectRow.split($0).detail == nil ? CGFloat(18) : CGFloat(34) }
        let gaps = CGFloat(max(rows.count - 1, 0)) * CGFloat(12)
        h += rows.reduce(CGFloat(0), +) + gaps
        if p.text.warning != nil { h += 16 + 72 }
        if p.text.hint != nil { h += 16 + 34 }
        if p.lookupProblem != nil { h += 16 + 34 }
        return h                                               // an error shows in place of the size/badge line
    }
}

struct DeleteConfirmView: View {
    let item: Item
    let close: () -> Void
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var plan: DeleteEverywhereService.Plan?

    init(item: Item, initial: DeleteEverywhereService.Plan? = nil, close: @escaping () -> Void) {
        self.item = item; self.close = close
        _plan = State(initialValue: initial)
    }
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let plan { content(plan) } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking nexcrate and the server\u{2026}").cvFont(13).foregroundColor(.white.opacity(0.8)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if plan == nil { plan = await DeleteEverywhereService.prepare(item, emby: emby) } }
    }

    /// "The movie “X”" → "X" (the small line above already says what it is)
    static func shortTitle(_ line: String) -> String {
        for pre in ["The movie ", "The series "] where line.hasPrefix(pre) {
            return String(line.dropFirst(pre.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}\""))
        }
        return line
    }

    /// The kind in words for the header ("Delete movie?")
    private var kindWord: String {
        switch item.Type { case "Movie": return "movie"; case "Series": return "series"; case "Season": return "season"
        case "Episode": return "episode"; default: return "title" }
    }

    @ViewBuilder func content(_ p: DeleteEverywhereService.Plan) -> some View {
        // Poster + title block (one title, no repeated subtitle)
        HStack(alignment: .center, spacing: 16) {
            ItemAdminThumb(url: URL(string: emby.server + "/Items/\(ItemAdminAPI.p(item.posterId))/Images/Primary?maxWidth=240&quality=85"),
                           placeholder: "film").frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete \(kindWord)?").cvFont(12, weight: .semibold).foregroundColor(.white.opacity(0.6))
                Text(DeleteConfirmView.shortTitle(p.text.scopeLine)).cvFont(18, weight: .bold).foregroundColor(.white)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let error {
                    // the error takes the size/badge line, so the compact window never needs to grow
                    Text(error).cvFont(12, weight: .semibold).foregroundColor(.orange).lineLimit(2).tip(error)
                } else {
                HStack(spacing: 8) {
                        if let s = p.sizeBytes, s > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).cvFont(12, weight: .medium) { $0.monospacedDigit() }
                                .foregroundColor(.white.opacity(0.75))
                        }
                        DeleteStatusBadge(inNexcrate: p.inNexcrate, configured: p.configured)
                    }
                }
                buttons(p).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        // What happens: icon rows, main line + quieter detail
        VStack(alignment: .leading, spacing: 12) {
            ForEach(p.text.bullets, id: \.self) { DeleteEffectRow(text: $0) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        if let w = p.text.warning {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").cvFont(15).foregroundColor(.white)
                Text(w.replacingOccurrences(of: "\u{26A0} ", with: "")).cvFont(13, weight: .semibold).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.85), lineWidth: 1))
        }
        if let m = p.lookupProblem { Text(m).cvFont(12).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
        if let h = p.text.hint { Text(h).cvFont(12).foregroundColor(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true) }
    }

    /// Cancel + Delete right under the title (owner: buttons above the info, smaller window)
    @ViewBuilder func buttons(_ p: DeleteEverywhereService.Plan) -> some View {
        HStack(spacing: 10) {
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
        .focusEffectDisabled()   // no blue focus ring on Cancel (owner); Esc still cancels
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


/// "In nexcrate" (green) / "Not in nexcrate" / "nexcrate not connected" as a small capsule.
struct DeleteStatusBadge: View {
    let inNexcrate: Bool
    let configured: Bool
    var body: some View {
        let (t, c, i): (String, Color, String) = inNexcrate ? ("In nexcrate", .green, "checkmark.circle.fill")
            : configured ? ("Not in nexcrate", .orange, "xmark.circle.fill") : ("nexcrate not connected", .gray, "link")
        HStack(spacing: 4) { Image(systemName: i).cvFont(10, weight: .bold); Text(t).cvFont(11, weight: .semibold) }
            .foregroundColor(c).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.16)))
    }
}

/// One effect of the delete: icon + main line + (detail in brackets or after a dash) in a quieter second line.
struct DeleteEffectRow: View {
    let text: String
    var body: some View {
        let p = DeleteEffectRow.split(text)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: p.icon).cvFont(13, weight: .semibold).foregroundColor(p.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.main).cvFont(13, weight: .medium).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                if let d = p.detail {
                    Text(d).cvFont(11).foregroundColor(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func split(_ raw: String) -> (main: String, detail: String?, icon: String, tint: Color) {
        var t = raw.hasPrefix("\u{2022} ") ? String(raw.dropFirst(2)) : raw
        var detail: String?
        if let r = t.range(of: " ("), t.hasSuffix(")") {
            detail = String(t[r.upperBound..<t.index(before: t.endIndex)]); t = String(t[..<r.lowerBound])
        } else if let r = t.range(of: " \u{2014} ") {
            detail = String(t[r.upperBound...]); t = String(t[..<r.lowerBound])
        }
        if let d = detail { detail = d.prefix(1).uppercased() + d.dropFirst() }
        let l = t.lowercased()
        let (icon, tint): (String, Color) =
            l.contains("recycle") ? ("arrow.uturn.backward.circle.fill", .green)
            : l.contains("qbittorrent") ? ("arrow.down.circle.fill", .orange)
            : l.contains("frozen") ? ("snowflake", .cyan)
            : l.contains("several episodes") ? ("doc.on.doc.fill", .orange)
            : l.contains("disk") ? ("trash.fill", .red)
            : l.contains("library") ? ("rectangle.stack.badge.minus", .white.opacity(0.8))
            : ("shippingbox.fill", .white.opacity(0.8))
        return (t, detail, icon, tint)
    }
}
