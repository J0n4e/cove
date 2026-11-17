import Foundation

/// A dictionary that keeps at most `cap` entries: when full, the entry written longest ago goes first.
/// For lookup tables filled from every list the server sends (image tags, blurred previews), which otherwise
/// grow for as long as the app runs. Not thread-safe: callers keep their own lock.
struct BoundedMap<Value> {
    let cap: Int
    private var storage: [String: (value: Value, gen: Int)] = [:]
    /// Write order; entries whose key was written again later are skipped when evicting
    private var order: [(key: String, gen: Int)] = []
    private var head = 0
    private var gen = 0

    init(cap: Int) { self.cap = max(1, cap) }

    var count: Int { storage.count }

    subscript(key: String) -> Value? {
        get { storage[key]?.value }
        set {
            guard let newValue else { storage[key] = nil; return }
            gen += 1
            storage[key] = (newValue, gen)
            order.append((key, gen))
            while storage.count > cap, head < order.count {
                let o = order[head]; head += 1
                if storage[o.key]?.gen == o.gen { storage[o.key] = nil }
            }
            compactIfNeeded()
        }
    }

    mutating func removeAll() { storage = [:]; order = []; head = 0 }

    /// Drops the used-up front of `order` and stale rewrites, so it stays proportional to `cap`.
    private mutating func compactIfNeeded() {
        guard order.count - head > 2 * cap + 256 || (head > 1024 && head * 2 > order.count) else { return }
        order = order[head...].filter { storage[$0.key]?.gen == $0.gen }
        head = 0
    }
}

/// How a poster grid's item list changed, so a page appended at the end can be inserted instead of
/// reloading (and rebinding) every poster on screen.
enum GridDiff {
    /// The indexes added at the end when `new` is `old` plus more items; nil for any other change.
    static func appendedTail(old: [String], new: [String]) -> Range<Int>? {
        guard !old.isEmpty, new.count > old.count, new.starts(with: old) else { return nil }
        return old.count..<new.count
    }
}
