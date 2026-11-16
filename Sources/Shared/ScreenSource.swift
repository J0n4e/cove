import Foundation

/// The few server calls the shared screen models (Favorites, Search, Person) make. `Emby` is the real one;
/// the tests pass a small fake, so the models' logic can be checked without a server.
@MainActor
protocol ScreenSource: AnyObject {
    func favorites() async -> [Item]
    func favoritePeople() async -> [Item]
    func search(_ term: String) async -> [Item]
    func searchPeople(_ term: String) async -> [Item]
    func itemsWithPerson(_ personId: String) async -> [Item]
    func person(_ id: String) async -> Item?
}

extension Emby: ScreenSource {}
