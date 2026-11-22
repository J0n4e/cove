import Foundation

/// The Nexview connection for Cleanup (address + sealed API token). The token is never logged or shown.
@MainActor
final class NexviewConnection: ObservableObject {
    static let shared = NexviewConnection()
    private static let addressKey = "nexviewAddress", keyName = "nexviewToken"

    struct Failure: Error { let message: String }

    @Published var address: String = UserDefaults.standard.string(forKey: addressKey) ?? ""
    @Published private(set) var hasKey: Bool = SealedPrefs.get(keyName) != nil
    @Published var status: String?

    var configured: Bool { hasKey && NexcrateAPI.normalizedAddress(address) != nil }

    func saveAddress(_ a: String) {
        let n = NexcrateAPI.normalizedAddress(a) ?? a.trimmingCharacters(in: .whitespaces)
        address = n; UserDefaults.standard.set(n, forKey: Self.addressKey)
    }
    func setKey(_ k: String?) {
        let t = k?.trimmingCharacters(in: .whitespacesAndNewlines)
        SealedPrefs.set(t?.isEmpty == true ? nil : t, for: Self.keyName)
        hasKey = SealedPrefs.get(Self.keyName) != nil
    }
    func disconnect() { setKey(nil); status = "Disconnected." }

    /// One GET. Returns (status, body); status 0 = not reachable.
    func get(_ path: String, timeout: TimeInterval = 30) async -> (Int, Data) {
        guard let base = NexcrateAPI.normalizedAddress(address), let u = URL(string: base + path) else { return (0, Data()) }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let k = SealedPrefs.get(Self.keyName) { r.setValue("Bearer " + k, forHTTPHeaderField: "Authorization") }
        do {
            let (d, resp) = try await Net.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) { DebugLog.write("nexview: GET \(path) HTTP \(code)") }
            return (code, d)
        } catch {
            DebugLog.write("nexview: GET \(path) failed \((error as NSError).domain) \((error as NSError).code)")
            return (0, Data())
        }
    }

    /// Every request (the admin list has no paging).
    func requests() async -> Result<[NexviewRequest], Failure> {
        let (c, d) = await get(Nexview.requestsPath, timeout: 60)
        guard (200..<300).contains(c) else { return .failure(Failure(message: Nexview.message(status: c, detail: Nexview.errorDetail(d)))) }
        guard let list = Nexview.decodeRequests(d) else { return .failure(Failure(message: "Nexview sent an unexpected answer.")) }
        DebugLog.write("nexview: \(list.count) requests")
        return .success(list)
    }

    /// /api/v1/me, then the request list: the status line.
    @discardableResult
    func test() async -> String {
        let (c, d) = await get(Nexview.mePath, timeout: 15)
        var s: String
        if (200..<300).contains(c), let me = Nexview.decodeMe(d) {
            s = "Connected as \(me.name)" + (me.role.isEmpty ? "" : " (\(me.role))") + (me.readOnly ? " \u{00B7} read-only token" : "")
            switch await requests() {
            case .success(let l): s += " \u{00B7} \(l.count) request" + (l.count == 1 ? "" : "s")
            case .failure(let e): s += " \u{2014} " + e.message
            }
        } else { s = Nexview.message(status: c, detail: Nexview.errorDetail(d)) }
        status = s
        return s
    }
}
