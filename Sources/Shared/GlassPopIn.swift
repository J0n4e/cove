import SwiftUI

/// The bottom search pill's entrance (SearchDock in Sources/Shared/SearchDock.swift,
/// top-bar layout): it slides up from the bottom edge while fading in, on a 0.35 s spring. Shared so pop-ups
/// such as the player's Up next card appear the same way.
extension AnyTransition {
    static var coveGlassPopIn: AnyTransition { .move(edge: .bottom).combined(with: .opacity) }
}

extension Animation {
    static var coveGlassPopIn: Animation { Glass3DTokens.Motion.spring }
}

extension View {
    /// Slides the view up from the bottom with the search pill's spring while `value` changes (apply the
    /// `.coveGlassPopIn` transition to the view that appears inside).
    func coveGlassPopIn<V: Equatable>(value: V) -> some View { animation(.coveGlassPopIn, value: value) }
}

extension AnyTransition {
    /// Every shared glass menu (profile menu, glass dropdowns) opens and closes with this: a fade plus a small
    /// drop from its anchor, never a scale. Animate it with `Glass3DTokens.Menu.animation`.
    static var coveMenuPopIn: AnyTransition {
        .opacity.combined(with: .offset(y: -Glass3DTokens.Space.xs))
    }
}
