import Foundation
import Combine

/// A person's page data (their titles and their own record), shared by the Glass and Classic themes.
@MainActor
final class PersonModel: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var record: Item?
    @Published private(set) var loading = true

    var movies: [Item] { items.filter { !$0.isSeries } }
    var shows: [Item] { items.filter { $0.isSeries } }

    func load(_ id: String, source: ScreenSource) async {
        async let list = source.itemsWithPerson(id)
        async let me = source.person(id)
        items = await list
        record = await me
        loading = false
    }
}
