import Foundation
import Combine

/// A person's page data (their titles and their own record), shared by the Glass and Classic themes.
@MainActor
final class PersonModel: ObservableObject {
    /// An admin edit (pictures, metadata): the item as read again replaces the copy shown here
    private var liveWatch: ItemChangeWatch?
    init() {
        liveWatch = ItemChangeWatch { [weak self] fresh in
            guard let self else { return }
            if let n = LiveRefresh.replacing(self.items, with: fresh) { self.items = n }
        }
    }
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
