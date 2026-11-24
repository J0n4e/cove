import SwiftUI

// One look for every pop-up glass menu and one for every toast, built only from existing tokens:
// menus = elevation level 3 (the app background at 75 % under the glass, level-3 shadow), Radius.window corners,
// a Motion.fast fade to open / close; toasts = the bottom search pill's glass capsule (white text, Space.xl sides)
// with the shared slide-up (`coveGlassPopIn`) entrance on Motion.spring.

extension Glass3DTokens {
    /// Pop-up glass menus (profile menu, glass dropdowns).
    enum Menu {
        static let level = 3
        static let radius: CGFloat = Glass3DTokens.Radius.window
        static let animation: Animation = Glass3DTokens.Motion.fast
        /// The level-3 shadow (falls back to the large shadow token, which has the same values).
        static var shadow: Glass3DTokens.Shadow { Glass3DTokens.elevation(level).shadow ?? Glass3DTokens.shadowLarge }
    }

    /// Toasts (favourite / watched confirmations, SyncPlay, server messages, Manage server results).
    enum Toast {
        /// Single-line toast heights (main window / in the player)
        static let height: CGFloat = 44
        static let compactHeight: CGFloat = 40
        static let animation: Animation = Glass3DTokens.Motion.spring
    }
}

/// The shared pop-up menu surface: fixed dark fill of the app background, the glass edge, the level-3 shadow.
struct GlassMenuSurface: ViewModifier {
    @Environment(\.appBG) private var bg
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Menu.radius, style: .continuous)
        let e = Glass3DTokens.elevation(Glass3DTokens.Menu.level)
        content
            .background(shape.fill(bg.opacity(e.backgroundFill)))
            .clipShape(shape)
            .modifier(ClassicClearGlass(shape: shape))
            .g3Shadow(Glass3DTokens.Menu.shadow)
    }
}

/// The shared toast look: white text on the search pill's glass capsule, dark scheme. `height` nil = sized by its
/// (possibly multi-line) text with Space.m above and below.
struct ToastStyle: ViewModifier {
    var height: CGFloat? = Glass3DTokens.Toast.height
    @ViewBuilder func body(content: Content) -> some View {
        if let height {
            content.foregroundColor(.white)
                .padding(.horizontal, Glass3DTokens.Space.xl).frame(height: height)
                .searchGlass()
                .environment(\.colorScheme, .dark)
        } else {
            content.foregroundColor(.white)
                .padding(.horizontal, Glass3DTokens.Space.xl).padding(.vertical, Glass3DTokens.Space.m)
                .searchGlass()
                .environment(\.colorScheme, .dark)
        }
    }
}

extension AnyTransition {
    /// A toast's entrance: slides in from `edge` while fading (the bottom one is the search pill's `coveGlassPopIn`).
    static func toast(from edge: Edge = .bottom) -> AnyTransition { .move(edge: edge).combined(with: .opacity) }
}

extension View {
    func glassMenuSurface() -> some View { modifier(GlassMenuSurface()) }
    func toastStyle(height: CGFloat? = Glass3DTokens.Toast.height) -> some View { modifier(ToastStyle(height: height)) }
}
