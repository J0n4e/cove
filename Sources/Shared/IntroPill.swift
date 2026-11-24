import SwiftUI

extension View {
    /// The intro pills sit over the player, whose tap gesture toggles pause. Give the whole pill a hit shape
    /// and swallow taps that miss its Button, so a click never falls through and pauses the episode.
    func introPillConsumesClicks() -> some View {
        contentShape(Rectangle()).onTapGesture {}
    }
}
