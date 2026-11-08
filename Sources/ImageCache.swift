import SwiftUI
import AppKit

/// Pictures from the server, kept in memory while Cove runs and on disk (~/Library/Caches/Cove/Images) between
/// launches, so posters and banners seen before appear at once. Links carry the server's image tag, which
/// changes when the artwork changes, so a saved copy is used without asking the server again.
///
/// Pictures on screen download first: a download nobody is waiting for any more (scrolled past) is cancelled,
/// and look-ahead downloads (`prefetch`) run at low priority, a few at a time.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, NSImage>()
    let urlCache: URLCache
    private let session: URLSession
    private let lock = NSLock()
    private var _auth: (server: URL?, headers: [String: String]) = (nil, [:])
    private let authLock = NSLock()    // separate from `lock`: makeTask runs while `lock` is held

    /// Sign-in headers and the server they belong to, set by Emby whenever the server or token changes.
    /// Look-ahead downloads still queued for the previous server are dropped.
    func setAuth(server: String, headers: [String: String]) {
        authLock.withLock { _auth = (URL(string: server), headers) }
        lock.withLock { prefetchQueue.removeAll() }
    }

    /// The headers for one picture: only when it is on the server they belong to, so a download queued
    /// before a server switch never sends the new server's token to the old one (or the other way round).
    private func headers(for url: URL) -> [String: String] {
        authLock.withLock {
            guard let s = _auth.server, Net.sameOrigin(s, url) else { return [:] }
            return _auth.headers
        }
    }

    /// A download and how many views are waiting for it (prefetches pin it, so it is never cancelled).
    private final class Job { var task: Task<NSImage?, Never>!; var waiters = 0; var pinned = false }
    private var jobs: [URL: Job] = [:]
    private var prefetchQueue: [URL] = []
    private var prefetchRunning = 0
    private let prefetchLimit = 3

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove/Images", isDirectory: true)
    }

    private init() {
        memory.totalCostLimit = 200 * 1024 * 1024   // decoded pictures, about 200 MB
        urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 500 * 1024 * 1024,
                            directory: Self.directory)
        let cfg = URLSessionConfiguration.default
        // The session itself caches nothing: it would store each request together with its sign-in headers.
        // makeTask saves the picture by hand, keyed by the bare link, so the cache on disk holds no token.
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 60
        // Same redirect rule as the rest of the app: image links carry the token, so never follow them to another host
        session = URLSession(configuration: cfg, delegate: SameHostRedirects(), delegateQueue: nil)
        // Pictures saved by older versions are keyed by links that contain the sign-in token: drop them once
        if !UserDefaults.standard.bool(forKey: "imageCacheTokenFree") {
            urlCache.removeAllCachedResponses()
            UserDefaults.standard.set(true, forKey: "imageCacheTokenFree")
        }
        // Up to 1.15 the session also cached each request together with its sign-in headers: drop those once
        if !UserDefaults.standard.bool(forKey: "imageCacheNoHeaders") {
            urlCache.removeAllCachedResponses()
            UserDefaults.standard.set(true, forKey: "imageCacheNoHeaders")
        }
    }

    /// Already decoded and in memory (no waiting, no flash).
    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    private func makeTask(_ url: URL, priority: TaskPriority) -> Task<NSImage?, Never> {
        let headers = headers(for: url)
        return Task(priority: priority) { [session, memory, urlCache] in
            // Looked up and stored by the bare link (no headers), so a saved copy is found whatever the sign-in
            let key = URLRequest(url: url)
            // A link with the server's image tag changes when the artwork changes, so its copy is kept. Without a
            // tag (cast and people pictures) a copy is only trusted for a week, then fetched again.
            let tagged = url.query?.contains("tag=") ?? false
            if let c = urlCache.cachedResponse(for: key),
               tagged || (c.userInfo?["saved"] as? Date ?? .distantPast) > Date().addingTimeInterval(-7 * 86400),
               let img = NSImage(data: c.data) {
                memory.setObject(img, forKey: url as NSURL, cost: c.data.count * 4)
                return img
            }
            var r = URLRequest(url: url)
            r.cachePolicy = .reloadIgnoringLocalCacheData
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            guard let (data, resp) = try? await session.data(for: r),
                  (resp as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let img = NSImage(data: data) else { return nil }
            // Saved copies are kept no matter what caching rules the server sends
            urlCache.storeCachedResponse(CachedURLResponse(response: resp, data: data, userInfo: ["saved": Date()],
                                                           storagePolicy: .allowed), for: key)
            memory.setObject(img, forKey: url as NSURL, cost: data.count * 4)
            return img
        }
    }

    /// The picture for a view on screen. If the view goes away first, its share of the download is dropped, and
    /// the download stops when no one else needs it.
    func image(_ url: URL) async -> NSImage? {
        if let m = cached(url) { return m }
        let job = lock.withLock { () -> Job in
            if let j = jobs[url] { j.waiters += 1; return j }
            let j = Job(); j.waiters = 1
            j.task = makeTask(url, priority: .userInitiated)
            jobs[url] = j
            return j
        }
        return await withTaskCancellationHandler {
            let img = await job.task.value
            lock.withLock { if jobs[url] === job { jobs[url] = nil } }
            return img
        } onCancel: {
            lock.withLock {
                job.waiters -= 1
                if job.waiters <= 0 && !job.pinned { job.task.cancel(); if jobs[url] === job { jobs[url] = nil } }
            }
        }
    }

    /// Downloads pictures ahead of time (next banners, posters further along a row) at low priority.
    func prefetch(_ urls: [URL?]) {
        lock.withLock {
            for case let u? in urls where cached(u) == nil && jobs[u] == nil && !prefetchQueue.contains(u) {
                prefetchQueue.append(u)
            }
        }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while true {
            let next: URL? = lock.withLock {
                guard prefetchRunning < prefetchLimit, !prefetchQueue.isEmpty else { return nil }
                prefetchRunning += 1
                return prefetchQueue.removeFirst()
            }
            guard let url = next else { return }
            let job = lock.withLock { () -> Job in
                if let j = jobs[url] { j.pinned = true; return j }
                let j = Job(); j.pinned = true
                j.task = makeTask(url, priority: .utility)
                jobs[url] = j
                return j
            }
            Task(priority: .utility) {
                _ = await job.task.value
                self.lock.withLock {
                    if self.jobs[url] === job { self.jobs[url] = nil }
                    self.prefetchRunning -= 1
                }
                self.pumpPrefetch()
            }
        }
    }

    /// Bytes used on disk.
    var diskUsage: Int { urlCache.currentDiskUsage }

    func clear() {
        // Stop downloads first, so none of them saves a picture again right after the cache was emptied
        lock.withLock {
            prefetchQueue.removeAll()
            for job in jobs.values { job.task.cancel() }
            jobs.removeAll()
        }
        memory.removeAllObjects()
        urlCache.removeAllCachedResponses()
        BlurHash.cache.removeAllObjects()
    }
}

/// Drop-in for SwiftUI's `AsyncImage` that goes through `ImageCache`. While a picture loads, a blurred preview
/// of it is shown when the server sent one (Jellyfin's "blurhash").
struct CachedImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        // A picture already in memory shows on the first frame (no grey flash when going back to a page);
        // otherwise the blurred preview, if there is one
        if let url, let img = ImageCache.shared.cached(url) {
            _phase = State(initialValue: .success(Image(nsImage: img)))
        } else if let url, let blur = BlurHash.preview(for: url) {
            _phase = State(initialValue: .success(Image(nsImage: blur)))
        }
    }

    init<I: View, P: View>(url: URL?, @ViewBuilder content: @escaping (Image) -> I,
                           @ViewBuilder placeholder: @escaping () -> P) where Content == _ConditionalContent<I, P> {
        self.init(url: url) { phase in
            if let img = phase.image { content(img) } else { placeholder() }
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                guard let url else { phase = .empty; return }
                if let img = ImageCache.shared.cached(url) { phase = .success(Image(nsImage: img)); return }
                if let blur = BlurHash.preview(for: url) { phase = .success(Image(nsImage: blur)) }
                else if case .success = phase {} else { phase = .empty }
                if let img = await ImageCache.shared.image(url) {
                    withAnimation(.easeOut(duration: 0.2)) { phase = .success(Image(nsImage: img)) }
                } else if !Task.isCancelled, phase.image == nil {
                    phase = .failure(URLError(.cannotDecodeContentData))
                }
            }
    }
}

// MARK: - BlurHash (https://blurha.sh): a short text that decodes to a tiny blurred picture

enum BlurHash {
    /// Hashes by "itemId|Kind", filled from the item lists the server sends (Jellyfin only).
    nonisolated(unsafe) static var hashes: [String: String] = [:]
    static let lock = NSLock()
    static let cache = NSCache<NSString, NSImage>()

    static func remember(_ id: String, _ kind: String, _ hash: String) {
        lock.withLock { hashes[id + "|" + kind] = hash }
    }

    /// The blurred preview for an image link (…/Items/{id}/Images/{Kind}?…), if the server sent a hash.
    static func preview(for url: URL) -> NSImage? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "Items"), parts.count > i + 3, parts[i + 2] == "Images" else { return nil }
        // Logos are transparent title art: a blurred square would look wrong, so they just fade in
        guard parts[i + 3] != "Logo" else { return nil }
        let key = parts[i + 1] + "|" + parts[i + 3]
        guard let hash = lock.withLock({ hashes[key] }) else { return nil }
        if let c = cache.object(forKey: hash as NSString) { return c }
        guard let img = decode(hash, width: 32, height: 32) else { return nil }
        cache.setObject(img, forKey: hash as NSString)
        return img
    }

    private static let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static func b83(_ s: Substring) -> Int? {
        var v = 0
        for c in s { guard let d = chars.firstIndex(of: c) else { return nil }; v = v * 83 + d }
        return v
    }
    private static func toLinear(_ v: Int) -> Double {
        let x = Double(v) / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    private static func toSRGB(_ v: Double) -> UInt8 {
        let x = max(0, min(1, v))
        let s = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, Int(s * 255 + 0.5))))
    }

    static func decode(_ hash: String, width: Int, height: Int) -> NSImage? {
        guard hash.count >= 6, let size = b83(hash.prefix(1)) else { return nil }
        let nx = size % 9 + 1, ny = size / 9 + 1
        guard hash.count == 4 + 2 * nx * ny, let qMax = b83(hash.dropFirst().prefix(1)) else { return nil }
        let maxV = Double(qMax + 1) / 166
        var colors: [(Double, Double, Double)] = []
        for i in 0..<(nx * ny) {
            if i == 0 {
                guard let v = b83(hash.dropFirst(2).prefix(4)) else { return nil }
                colors.append((toLinear(v >> 16), toLinear((v >> 8) & 255), toLinear(v & 255)))
            } else {
                guard let v = b83(hash.dropFirst(4 + i * 2).prefix(2)) else { return nil }
                func q(_ x: Int) -> Double { let d = Double(x - 9) / 9; return (d < 0 ? -1 : 1) * d * d * maxV }
                colors.append((q(v / (19 * 19)), q((v / 19) % 19), q(v % 19)))
            }
        }
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<ny {
                    for i in 0..<nx {
                        let basis = cos(Double.pi * Double(x * i) / Double(width)) * cos(Double.pi * Double(y * j) / Double(height))
                        let c = colors[i + j * nx]
                        r += c.0 * basis; g += c.1 * basis; b += c.2 * basis
                    }
                }
                let o = (y * width + x) * 4
                px[o] = toSRGB(r); px[o + 1] = toSRGB(g); px[o + 2] = toSRGB(b)
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
