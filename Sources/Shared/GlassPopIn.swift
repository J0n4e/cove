import SwiftUI

/// The bottom search pill's entrance (SearchDock in Sources/Glass/GlassSearch.swift, used by both themes'
/// top-bar layout): it slides up from the bottom edge while fading in, on a 0.35 s spring. Shared so pop-ups
/// such as the player's Up next card appear the same way.
extension AnyTransition {
    static var coveGlassPopIn: AnyTransition { .move(edge: .bottom).combined(with: .opacity) }
}

extension Animation {
    static var coveGlassPopIn: Animation { .spring(duration: 0.35) }
}

extension View {
    /// Slides the view up from the bottom with the search pill's spring while `value` changes (apply the
    /// `.coveGlassPopIn` transition to the view that appears inside).
    func coveGlassPopIn<V: Equatable>(value: V) -> some View { animation(.coveGlassPopIn, value: value) }
}
