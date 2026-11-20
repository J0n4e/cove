import Foundation
import Network

/// Cast devices on the local network (Bonjour `_googlecast._tcp`). Browsing starts when a Cast picker opens
/// and stops a while after it closes; the first search shows the macOS Local Network permission prompt.
@MainActor
final class CastDeviceStore: ObservableObject {
    static let shared = CastDeviceStore()

    @Published private(set) var devices: [CastDevice] = []
    /// True while searching and nothing was found for under 5 s.
    @Published private(set) var searching = false
    @Published private(set) var browseError: String?

    private var browser: NWBrowser?
    private var users = 0
    private var stopTask: Task<Void, Never>?
    private let defaults: UserDefaults
    static let lastKey = "castLastDevice"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The device used last (its TXT id), listed first.
    var lastUsedId: String? {
        get { defaults.string(forKey: Self.lastKey) }
        set { defaults.set(newValue, forKey: Self.lastKey) }
    }

    /// Devices sorted for the picker: the last used first, then by name.
    nonisolated static func sorted(_ list: [CastDevice], last: String?) -> [CastDevice] {
        list.sorted { a, b in
            if (a.id == last) != (b.id == last) { return a.id == last }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func begin() {
        users += 1
        stopTask?.cancel(); stopTask = nil
        guard browser == nil else { return }
        searching = true
        browseError = nil
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: "local."), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.device(from:))
            Task { @MainActor in self?.update(found) }
        }
        b.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st {
                DebugLog.write("cast: browse failed (\(CastChannel.describe(e)))")
                Task { @MainActor in self?.browseError = "Cove couldn't look for Cast devices. Allow Cove in System Settings → Privacy & Security → Local Network." }
            }
        }
        b.start(queue: DispatchQueue(label: "eu.jonae.cove.cast.browse"))
        browser = b
        DebugLog.write("cast: browsing for devices")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.searching = false
        }
    }

    func end() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.users == 0 else { return }
            self.browser?.cancel(); self.browser = nil
        }
    }

    private func update(_ found: [CastDevice]) {
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.id).inserted }
        let list = Self.sorted(unique, last: lastUsedId)
        if list != devices {
            devices = list
            DebugLog.write("cast: \(list.count) device(s): \(list.map(\.model).joined(separator: ", "))")
        }
        if !list.isEmpty { searching = false }
    }

    nonisolated static func device(from r: NWBrowser.Result) -> CastDevice? {
        guard case let .service(name, _, domain, _) = r.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(rec) = r.metadata { txt = rec.dictionary }
        return CastDevice.from(txt: txt, service: name, domain: domain)
    }
}
