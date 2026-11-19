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

/// What an item page (DetailModel) asks of the server and the app's playback state. `Emby` is the real one.
@MainActor
protocol DetailSource: AnyObject {
    func full(_ id: String) async -> Full?
    func episodes(_ seriesId: String) async -> [Item]
    func seasons(_ seriesId: String) async -> [Item]
    func nextUp(_ seriesId: String) async -> Item?
    func children(_ parentId: String) async -> [Item]
    /// A collection page loaded its titles: remember its films, so the collection's ✓ follows them
    func noteCollection(_ boxId: String, _ children: [Item])
    func collections(containing id: String) async -> [Item]
    func similar(_ id: String) async -> [Item]
    func isPlayed(_ it: Item) -> Bool
    func resumeAt(_ it: Item) -> Double
    func play(_ it: Item) async
    var openSeason: Int? { get set }
    var playing: PlayRequest? { get set }
}

extension Emby: DetailSource {}

extension DetailSource {
    func noteCollection(_ boxId: String, _ children: [Item]) {}
}
