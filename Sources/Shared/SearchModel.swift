import Foundation
import Combine

/// Search results, shared by the Glass and Classic themes. The view calls `run` from `.task(id: query)`:
/// typing a new letter cancels the running task, and the debounce sleep below is where it stops.
@MainActor
final class SearchModel: ObservableObject {
    /// How long typing has to pause before the server is asked (0.35 s).
    static let debounce: UInt64 = 350_000_000

    @Published private(set) var results: [Item] = []
    @Published private(set) var people: [Item] = []
    @Published private(set) var busy = false

    func run(_ query: String, source: ScreenSource, debounce: UInt64 = SearchModel.debounce) async {
        busy = true
        try? await Task.sleep(nanoseconds: debounce)
        if Task.isCancelled { return }
        async let titles = source.search(query)
        async let persons = source.searchPeople(query)
        results = await titles
        people = await persons
        busy = false
    }
}
