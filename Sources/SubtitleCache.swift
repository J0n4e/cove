import Foundation

/// Whole subtitle tracks saved on this Mac (one .srt per track), named base64("server|item|source|index")
/// with "/" replaced by "_". Bounded by size and age; touched on every hit so pruning drops the least recently used.
struct SubtitleCache {
    static let shared = SubtitleCache()
    let dir: URL

    init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "eu.jonae.cove", isDirectory: true)
            .appendingPathComponent("Subtitles", isDirectory: true)
    }

    static func fileName(_ key: String) -> String {
        Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".srt"
    }

    static func key(ofFile name: String) -> String? {
        guard name.hasSuffix(".srt") else { return nil }
        let b = String(name.dropLast(4)).replacingOccurrences(of: "_", with: "/")
        guard let d = Data(base64Encoded: b) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func file(_ key: String) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.fileName(key))
    }

    private static let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.keys)) ?? [])
            .filter { $0.pathExtension == "srt" }
    }

    private static func size(_ f: URL) -> Int {
        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return v?.totalFileAllocatedSize ?? v?.fileSize ?? 0
    }

    private static func lastUse(_ f: URL) -> Date {
        let v = try? f.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        let dates = [v?.contentAccessDate, v?.contentModificationDate].compactMap { $0 }
        return dates.max() ?? .distantPast
    }

    func totalBytes() -> Int { files().reduce(0) { $0 + Self.size($1) } }

    func clear() { files().forEach { try? FileManager.default.removeItem(at: $0) } }

    /// Marks a hit, so the track counts as recently used.
    func touch(_ f: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
    }

    func prune(maxBytes: Int = 100 * 1024 * 1024, maxAge: TimeInterval = 90 * 86400, now: Date = Date()) {
        var live: [(url: URL, date: Date, size: Int)] = []
        for f in files() {
            let d = Self.lastUse(f)
            if now.timeIntervalSince(d) > maxAge { try? FileManager.default.removeItem(at: f) }
            else { live.append((f, d, Self.size(f))) }
        }
        var total = live.reduce(0) { $0 + $1.size }
        for f in live.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }

    /// Deletes the tracks saved from this server (on sign out or when it's removed).
    func removeServer(_ server: String) {
        let prefix = server.lowercased() + "|"
        for f in files() {
            if let k = Self.key(ofFile: f.lastPathComponent), k.lowercased().hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
