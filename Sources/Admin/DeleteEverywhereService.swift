import Foundation
import Combine

/// Items deleted in this session: pages drop them (LiveRefresh tombstones), an open detail page of one goes back.
@MainActor
final class DeletedItems: ObservableObject {
    static let shared = DeletedItems()
    let deleted = PassthroughSubject<Set<String>, Never>()
    @Published private(set) var records: [DeletionRecord] = DeletionStore.load()

    /// Tells every page: ids go out through ItemAdminChanges as tombstones (LiveRefresh.replacing drops them).
    func announce(_ ids: Set<String>) {
        var fresh: [String: Item] = [:]
        for id in ids { if let t = Item.tombstone(id) { fresh[id] = t } }
        if !fresh.isEmpty { ItemAdminChanges.shared.updates.send(fresh) }
        deleted.send(ids)
    }

    func add(_ r: DeletionRecord) { records = DeletionStore.pruned([r] + records); DeletionStore.save(records) }
    func update(_ r: DeletionRecord) {
        records = records.map { $0.id == r.id ? r : $0 }; DeletionStore.save(records)
    }
    func remove(_ id: String) { records.removeAll { $0.id == id }; DeletionStore.save(records) }
    func reload() { records = DeletionStore.load() }
}

extension Item {
    static let tombstoneType = "__coveDeleted"
    var isTombstone: Bool { `Type` == Item.tombstoneType }
    /// A stand-in that means "this item is gone".
    static func tombstone(_ id: String) -> Item? {
        let o: [String: Any] = ["Id": id, "Name": "", "Type": tombstoneType]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: d)
    }
}

/// The one nexcrate connection (address + sealed key). The key is never logged or shown.
@MainActor
final class NexcrateConnection: ObservableObject {
    static let shared = NexcrateConnection()
    private static let addressKey = "nexcrateAddress", keyName = "nexcrateKey", scopesKey = "nexcrateScopes"

    @Published var address: String = UserDefaults.standard.string(forKey: addressKey) ?? ""
    @Published private(set) var hasKey: Bool = SealedPrefs.get(keyName) != nil
    @Published var scopes: [String] = UserDefaults.standard.stringArray(forKey: scopesKey) ?? []
    @Published var status: String?
    @Published var version: String?

    var configured: Bool { hasKey && NexcrateAPI.baseURL(address) != nil }

    func saveAddress(_ a: String) {
        let n = NexcrateAPI.normalizedAddress(a) ?? a.trimmingCharacters(in: .whitespaces)
        address = n; UserDefaults.standard.set(n, forKey: Self.addressKey)
    }
    func setKey(_ k: String?, scopes s: [String] = []) {
        SealedPrefs.set(k?.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyName)
        hasKey = SealedPrefs.get(Self.keyName) != nil
        scopes = hasKey ? s : []
        UserDefaults.standard.set(scopes, forKey: Self.scopesKey)
    }
    func disconnect() { setKey(nil); version = nil; status = "Disconnected." }

    /// One call. Returns (status, body); status 0 = not reachable.
    func send(_ req: NexcrateAPI.Request, auth: Bool = true, headers: [String: String] = [:], timeout: TimeInterval = 30) async -> (Int, Data) {
        guard let base = NexcrateAPI.baseURL(address), let u = URL(string: base + req.path) else { return (0, Data()) }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = req.method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ct = req.contentType { r.setValue(ct, forHTTPHeaderField: "Content-Type") }
        r.httpBody = req.body
        if auth, let k = SealedPrefs.get(Self.keyName) { r.setValue("Bearer " + k, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (d, resp) = try await Net.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                coveLog.error("nexcrate \(req.method, privacy: .public) HTTP \(code) \(NexcrateAPI.errorCode(d) ?? "-", privacy: .public)")
            }
            return (code, d)
        } catch {
            coveLog.error("nexcrate \(req.method, privacy: .public) failed: \((error as NSError).code)")
            return (0, Data())
        }
    }

    static let unreachable = "Couldn't reach nexcrate. Check the address in Settings → Connect."

    /// GET /system: fills version and scopes; returns the status line.
    @discardableResult
    func test() async -> String {
        let (c, d) = await send(NexcrateAPI.system(), timeout: 15)
        let s: String
        if c == 0 { s = Self.unreachable }
        else if let info = NexcrateAPI.decodeSystem(d), (200..<300).contains(c) {
            version = info.version
            if !info.scopes.isEmpty { scopes = info.scopes; UserDefaults.standard.set(scopes, forKey: Self.scopesKey) }
            let missing = ["read", "request"].filter { !info.scopes.contains($0) }
            s = "Connected" + (info.version.map { " to nexcrate \($0)" } ?? "") + " · scopes: " + info.scopes.joined(separator: ", ")
                + (missing.isEmpty ? "" : " — missing \(missing.joined(separator: ", ")): Delete won't work")
        } else { s = NexcrateAPI.message(status: c, code: NexcrateAPI.errorCode(d)) ?? "Unexpected answer." }
        status = s
        return s
    }

    // MARK: Pairing
    @Published var pairingCode: String?
    private var pairingTask: Task<Void, Never>?

    func startPairing() {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self else { return }
            let (c, d) = await self.send(NexcrateAPI.pairing(), auth: false, timeout: 15)
            guard (200..<300).contains(c), let start = NexcrateAPI.decodePairingStart(d) else {
                self.status = c == 0 ? Self.unreachable : NexcrateAPI.message(status: c, code: NexcrateAPI.errorCode(d)); return
            }
            self.pairingCode = start.code
            self.status = "Confirm Cove in nexcrate: \(start.code)"
            let wait = UInt64(max(2, min(start.poll_seconds ?? 3, 30)))
            for _ in 0..<400 {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                if Task.isCancelled { return }
                let (pc, pd) = await self.send(NexcrateAPI.pairingState(start.pairing_id), auth: false,
                                               headers: ["X-Pairing-Secret": start.secret], timeout: 15)
                if pc == 0 { continue }
                guard (200..<300).contains(pc), let st = NexcrateAPI.decodePairingState(pd) else {
                    self.pairingCode = nil
                    self.status = NexcrateAPI.message(status: pc, code: NexcrateAPI.errorCode(pd)); return
                }
                switch st.phase {
                case .waiting, .unknown: continue
                case .gotKey(let key, let s):
                    self.pairingCode = nil
                    self.setKey(key, scopes: s)
                    await self.test(); return
                case .delivered:
                    self.pairingCode = nil; self.status = "nexcrate handed the key out already. Start again."; return
                case .denied:
                    self.pairingCode = nil; self.status = "The request was denied in nexcrate."; return
                case .expired:
                    self.pairingCode = nil; self.status = "The request expired. Start again."; return
                }
            }
            self.pairingCode = nil
        }
    }
    func cancelPairing() { pairingTask?.cancel(); pairingTask = nil; pairingCode = nil; status = nil }
}

/// The whole Delete… flow (admins only). Every message is a plain sentence.
@MainActor
enum DeleteEverywhereService {
    /// What the confirm window needs.
    struct Plan {
        let item: Item
        let raw: [String: Any]
        let target: NexcrateAPI.Target?
        let inNexcrate: Bool
        let configured: Bool
        let text: NexcrateAPI.ConfirmText
        let sizeBytes: Int64?
        let libraryId: String?
        /// nexcrate couldn't be asked (unreachable): the window says so and offers no permanent path silently
        let lookupProblem: String?
    }

    static func rawItem(_ id: String, emby: Emby) async -> [String: Any]? {
        var out: [String: Any]?
        let path = "/Users/\(ItemAdminAPI.p(emby.userId))/Items/\(ItemAdminAPI.p(id))?Fields=ProviderIds,MediaSources,ChildCount,Path"
        _ = await ItemAdminService.send(.init(method: "GET", path: path), emby: emby, action: "read the item", timeout: 15) { d in
            out = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        return out
    }

    /// Whether the item still exists (false on 404).
    static func exists(_ id: String, emby: Emby) async -> Bool {
        guard let u = URL(string: emby.server + "/Users/\(ItemAdminAPI.p(emby.userId))/Items/\(ItemAdminAPI.p(id))") else { return false }
        var r = URLRequest(url: u, timeoutInterval: 15); emby.authorize(&r)
        guard let answer = try? await Net.session.data(for: r) else { return true }
        return ((answer.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400
    }

    static func libraryId(_ id: String, emby: Emby) async -> String? {
        var out: String?
        _ = await ItemAdminService.send(.init(method: "GET", path: "/Items/\(ItemAdminAPI.p(id))/Ancestors?UserId=\(ItemAdminAPI.p(emby.userId))"),
                                        emby: emby, action: "read the item", timeout: 15) { d in
            let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
            out = arr.first { ($0["Type"] as? String) == "CollectionFolder" }?["Id"] as? String
        }
        return out
    }

    static func prepare(_ item: Item, emby: Emby) async -> Plan {
        let conn = NexcrateConnection.shared
        let raw = await rawItem(item.id, emby: emby) ?? [:]
        let type = item.`Type`
        let idx = raw["IndexNumber"] as? Int ?? item.IndexNumber
        let pidx = raw["ParentIndexNumber"] as? Int ?? item.ParentIndexNumber
        let idxEnd = raw["IndexNumberEnd"] as? Int
        var seriesIds: [String: String]?
        if type == "Season" || type == "Episode", let sid = item.SeriesId ?? raw["SeriesId"] as? String {
            seriesIds = (await rawItem(sid, emby: emby))?["ProviderIds"] as? [String: String]
        }
        let pids = raw["ProviderIds"] as? [String: String] ?? item.ProviderIds
        let target = NexcrateAPI.target(type: type, providerIds: pids, seriesProviderIds: seriesIds,
                                        index: idx, parentIndex: pidx, indexEnd: idxEnd)
        var inNex = false, names: [String] = [], problem: String?
        if conn.configured, let target {
            let (c, d) = await conn.send(NexcrateAPI.lookup(target), timeout: 15)
            if (200..<300).contains(c) {
                inNex = true
                let ids = NexcrateAPI.decodeTitleVersions(d, season: type == "Season" ? idx : (type == "Episode" ? pidx : nil))
                let (vc, vd) = await conn.send(NexcrateAPI.versions(), timeout: 15)
                let map = (200..<300).contains(vc) ? NexcrateAPI.decodeVersionNames(vd) : [:]
                names = ids.compactMap { map[$0] }
            } else if c != 404 {
                problem = c == 0 ? NexcrateConnection.unreachable : NexcrateAPI.message(status: c, code: NexcrateAPI.errorCode(d))
            }
        }
        let sizes = (raw["MediaSources"] as? [[String: Any]] ?? []).compactMap { ($0["Size"] as? NSNumber)?.int64Value }
        let scope = NexcrateAPI.scopeLine(type: type, name: item.Name, seriesName: item.SeriesName ?? raw["SeriesName"] as? String,
                                          index: idx, parentIndex: pidx, indexEnd: idxEnd,
                                          childCount: raw["ChildCount"] as? Int ?? item.ChildCount)
        let text = NexcrateAPI.confirmText(type: type, scopeLine: scope, inNexcrate: inNex, configured: conn.configured,
                                           versionNames: names, doubleEpisode: (idxEnd ?? 0) > (idx ?? 0), season: idx)
        let lib = await libraryId(item.id, emby: emby)
        return Plan(item: item, raw: raw, target: target, inNexcrate: inNex, configured: conn.configured, text: text,
                    sizeBytes: sizes.isEmpty ? nil : sizes.reduce(0, +), libraryId: lib,
                    lookupProblem: problem)
    }

    /// Runs the confirmed delete. nil = done; else the sentence to show.
    static func run(_ plan: Plan, emby: Emby) async -> String? {
        let o = await perform(plan, emby: emby)
        if let e = o.error { return e }
        if let rec = o.record { DeleteUndoToast.show(rec, emby: emby) }
        else { emby.toast = Emby.Toast(text: "Deleted \u{201C}\(plan.item.Name)\u{201D} from the server", icon: "trash") }
        return nil
    }

    /// What one delete did: an error sentence, or the nexcrate record to undo (nil record = deleted on the server
    /// for good). Shows no toast, so a batch (Activity → Cleanup) can show one for all.
    struct Outcome { var error: String?; var record: DeletionRecord? }

    static func perform(_ plan: Plan, emby: Emby) async -> Outcome {
        let item = plan.item
        if plan.inNexcrate, let t = plan.target {
            let conn = NexcrateConnection.shared
            let started = Date()
            let req = t.whole ? NexcrateAPI.removeTitle(t) : NexcrateAPI.deleteFiles(t)
            let (c, d) = await conn.send(req, timeout: 120)
            if c == 0 { return Outcome(error: NexcrateConnection.unreachable) }
            if let m = NexcrateAPI.message(status: c, code: NexcrateAPI.errorCode(d)) { return Outcome(error: m) }
            if !t.whole { _ = await conn.send(NexcrateAPI.monitoring(t, monitored: false)) }
            let (bc, bd) = await conn.send(NexcrateAPI.recycleBin(), timeout: 20)
            let entries = (200..<300).contains(bc) ? NexcrateAPI.matching(NexcrateAPI.decodeRecycleBin(bd), target: t, since: started) : []
            let rec = DeletionRecord(server: emby.server.lowercased(), itemId: item.id, name: item.SeriesName.map { "\($0) · \(item.Name)" } ?? item.Name,
                                     what: plan.text.scopeLine, kind: t.kind, ref: t.ref, scope: t.scope, deletedAt: started,
                                     entryIds: entries.map(\.entryId), libraryId: plan.libraryId,
                                     posterURL: emby.image(item.posterId, width: 120)?.absoluteString, posterItemId: item.posterId)
            DeletedItems.shared.add(rec)
            DeletedItems.shared.announce([item.id])
            Task { await settle(item.id, libraryId: plan.libraryId, emby: emby) }
            return Outcome(record: rec)
        }
        guard let u = URL(string: emby.server + "/Items/\(ItemAdminAPI.p(item.id))") else { return Outcome(error: "Couldn't delete (bad address).") }
        var r = URLRequest(url: u, timeoutInterval: 60); r.httpMethod = "DELETE"; emby.authorize(&r)
        do {
            let (_, resp) = try await Net.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let m = NexcrateAPI.serverDeleteMessage(status: code) { return Outcome(error: m) }
        } catch { return Outcome(error: "Couldn't reach the server to delete this item. Check the connection and try again.") }
        DeletedItems.shared.announce([item.id])
        return Outcome()
    }

    /// After nexcrate deleted: the server should notice by itself (nexcrate asks it to rescan). If the item is still
    /// there after ~10 s, refresh its library; still there after that, remove the entry (its files are gone already).
    static func settle(_ id: String, libraryId: String?, emby: Emby) async {
        try? await Task.sleep(for: .seconds(10))
        guard await exists(id, emby: emby) else { return }
        await refreshLibrary(libraryId, emby: emby)
        try? await Task.sleep(for: .seconds(20))
        guard await exists(id, emby: emby) else { return }
        var r = URLRequest(url: URL(string: emby.server + "/Items/\(ItemAdminAPI.p(id))")!, timeoutInterval: 30)
        r.httpMethod = "DELETE"; emby.authorize(&r)
        _ = try? await Net.session.data(for: r)
    }

    static func refreshLibrary(_ libraryId: String?, emby: Emby) async {
        let path = libraryId.map { "/Items/\(ItemAdminAPI.p($0))/Refresh?Recursive=true" } ?? "/Library/Refresh"
        _ = await ItemAdminService.send(.init(method: "POST", path: path), emby: emby, action: "refresh the library", timeout: 20)
    }

    /// Undo: restore the bin entries (matched again if none were known), thaw a season/episode scope, refresh.
    static func undo(_ rec: DeletionRecord, emby: Emby) async -> String? {
        let conn = NexcrateConnection.shared
        guard conn.configured else { return "nexcrate isn't connected. " + NexcrateAPI.connectHint }
        var ids = rec.entryIds
        if ids.isEmpty {
            let (bc, bd) = await conn.send(NexcrateAPI.recycleBin(), timeout: 20)
            if bc == 0 { return NexcrateConnection.unreachable }
            ids = NexcrateAPI.matching(NexcrateAPI.decodeRecycleBin(bd), target: rec.target, since: rec.deletedAt).map(\.entryId)
        }
        guard !ids.isEmpty else { return "nexcrate's recycle bin holds no files of this delete any more." }
        var failures: [String] = [], restored: [Int] = []
        for id in ids {
            let (c, d) = await conn.send(NexcrateAPI.restore(id), timeout: 60)
            if let m = c == 0 ? NexcrateConnection.unreachable : NexcrateAPI.message(status: c, code: NexcrateAPI.errorCode(d)) { failures.append(m) }
            else { restored.append(id) }
        }
        if !rec.target.whole, !restored.isEmpty { _ = await conn.send(NexcrateAPI.monitoring(rec.target, monitored: true)) }
        if emby.server.lowercased() == rec.server { await refreshLibrary(rec.libraryId, emby: emby) }
        if failures.isEmpty { DeletedItems.shared.remove(rec.id); return nil }
        var left = rec; left.entryIds = ids.filter { !restored.contains($0) }
        DeletedItems.shared.update(left)
        return failures.first
    }
}
