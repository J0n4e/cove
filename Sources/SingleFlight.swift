import Foundation

/// Runs one operation at a time: callers that come while it runs wait for it and get the same result,
/// instead of starting it again. The next call after it finishes starts a new one.
@MainActor
final class SingleFlight<T: Sendable> {
    private var task: Task<T, Error>?

    var isRunning: Bool { task != nil }

    func run(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        if let task { return try await task.value }
        let t = Task { @MainActor in try await operation() }
        task = t
        defer { task = nil }
        return try await t.value
    }
}
