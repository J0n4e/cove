import AppKit
import SwiftUI

/// Where the circle sits, so the menu can open right under it (see Glass3DProfileMenuLayer).
struct ProfileCircleAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// The user's picture (or initials on accent-tinted dark glass) in a circle with a thin glass rim.
struct ProfileAvatar: View {
    @ObservedObject private var profile = ProfileModel.shared
    @AppStorage("accent") private var accentName = "red"
    var size: CGFloat
    var body: some View {
        ZStack {
            if let img = profile.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Theme.accent(accentName).opacity(0.35))
                Circle().fill(Color.black.opacity(0.35))
                Text(ProfileInitials.of(profile.name)).cvFont(size * 0.4, weight: .semibold).foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

/// Far right of the Glass3D top bar: the profile circle. Click opens the profile menu.
struct Glass3DProfileCircle: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var profile = ProfileModel.shared
    var body: some View {
        if emby.loggedIn {
            Button { profile.menuOpen.toggle() } label: {
                ProfileAvatar(size: 30)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(HoverButton())   // as the search button next to it
            .focusEffectDisabled()
            .tip(ProfileInitials.tooltip(user: profile.name.isEmpty ? (emby.currentServer?.user ?? "") : profile.name,
                                         server: emby.currentServerName))
            .accessibilityLabel("Profile")
            .anchorPreference(key: ProfileCircleAnchor.self, value: .bounds) { $0 }
            .task(id: emby.server + "|" + emby.userId) {
                profile.menuOpen = false
                await profile.load(emby)
                ProfileActions.rememberCurrent(emby)
            }
        }
    }
}

/// The menu under the circle, over the whole window (outside clicks and Esc close it). Applied once on the Glass3D
/// shell with `.modifier(Glass3DProfileMenuLayer())`.
struct Glass3DProfileMenuLayer: ViewModifier {
    @ObservedObject private var profile = ProfileModel.shared
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ProfileCircleAnchor.self) { anchor in
            GeometryReader { g in
                if profile.menuOpen, let anchor {
                    let r = g[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle())
                            .onTapGesture { profile.menuOpen = false }
                        Glass3DProfileMenu()
                            .frame(width: Glass3DProfileMenu.width)
                            .offset(x: max(8, min(r.maxX - Glass3DProfileMenu.width, g.size.width - Glass3DProfileMenu.width - 8)),
                                    y: r.maxY + 8)
                            .transition(.coveGlassPopIn)
                    }
                    .onExitCommand { profile.menuOpen = false }
                }
            }
            .coveGlassPopIn(value: profile.menuOpen)
        }
    }
}
