import SwiftUI

/// Settings → General → Posters → "Dim watched": watched posters and thumbnails at 60% (default on, as before).
enum WatchedDim {
    static let key = "dimWatched"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    static func opacity(played: Bool, enabled: Bool = WatchedDim.enabled) -> Double { played && enabled ? 0.6 : 1 }
}

/// `.opacity(played ? 0.6 : 1)` that follows the setting live.
struct WatchedDimModifier: ViewModifier {
    let played: Bool
    @AppStorage(WatchedDim.key) private var on = true
    func body(content: Content) -> some View { content.opacity(WatchedDim.opacity(played: played, enabled: on)) }
}

extension View {
    func watchedDim(_ played: Bool) -> some View { modifier(WatchedDimModifier(played: played)) }
}
