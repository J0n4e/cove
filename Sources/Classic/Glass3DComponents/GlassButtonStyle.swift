import SwiftUI

/// The shared button family.
/// - primary: solid accent with a glossy top edge and a soft inner shadow (a 3D button)
/// - secondary: dark glass with a light outline
/// - destructive: the fixed danger red, same 3D recipe as primary
/// - icon: a round glass button
/// - row: a list row with a faint hover / press highlight behind it (no padding of its own)
/// - lift: bare labels (page, player, banner buttons) that brighten under the mouse and dip when clicked;
///   `backing` adds a soft see-through capsule under the mouse for bare icons
/// - accentRow: player panel rows; `glass` lights the row under the pointer in the accent (plain: a press flash)
/// Pressing darkens; hover only brightens a little. Nothing ever changes size.
struct GlassButtonStyle: ButtonStyle {
    enum Kind: Equatable { case primary, secondary, destructive, icon, row, lift(backing: Bool), accentRow(glass: Bool) }
    var kind: Kind = .secondary
    /// nil: the accent from Settings
    var accentName: String? = nil

    init(_ kind: Kind = .secondary, accentName: String? = nil) {
        self.kind = kind
        self.accentName = accentName
    }

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(c: configuration, kind: kind, accentOverride: accentName)
    }

    /// Brightness of a button face: darker while pressed, a touch lighter under the mouse.
    static func brightness(pressed: Bool, hover: Bool) -> Double { pressed ? -0.1 : hover ? 0.04 : 0 }
    /// Solid face colour, nil for glass kinds.
    static func isSolid(_ k: Kind) -> Bool { k == .primary || k == .destructive }
    /// Text buttons that get the 3D face (glossy top edge, inner shadow, bottom shade): primary, destructive AND
    /// secondary (owner: Cancel must not look flat next to Delete), so they read as one family.
    static func usesHighlightRecipe(_ k: Kind) -> Bool { k == .primary || k == .destructive || k == .secondary }
    /// The secondary face: neutral grey glass under the same 3D recipe.
    static let secondaryFill = 0.16
}

private struct GlassButtonBody: View {
    let c: ButtonStyleConfiguration
    let kind: GlassButtonStyle.Kind
    let accentOverride: String?
    @AppStorage("accent") private var storedAccent = "red"
    @State private var hover = false

    var body: some View {
        switch kind {
        case .primary, .secondary, .destructive: textButton.onHover { hover = $0 }.animation(Glass3DTokens.Motion.fast, value: hover)
        case .icon: iconButton.onHover { hover = $0 }.animation(Glass3DTokens.Motion.fast, value: hover)
        case .row: rowButton.onHover { hover = $0 }
        case .lift(let backing): liftButton(backing)
        case .accentRow(let glass): accentRowButton(glass)
        }
    }

    private var name: String { accentOverride ?? storedAccent }

    private var textButton: some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.button, style: .continuous)
        let solid = GlassButtonStyle.isSolid(kind)
        let face: Color = kind == .primary ? Theme.accent(name) : Glass3DTokens.Status.danger
        return c.label
            .coveFont(size: 13, weight: .semibold)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, Glass3DTokens.Space.l).padding(.vertical, Glass3DTokens.Space.s)
            .foregroundColor(kind == .primary ? Theme.onAccent(name) : .white)
            .background {
                if solid {
                    SolidButtonFace(color: face, shape: shape)
                } else {
                    // Secondary: dark glass under a neutral grey 3D face, same height / radius as primary
                    ZStack {
                        shape.fill(Color.black.opacity(0.25))
                        SolidButtonFace(color: Color.white.opacity(GlassButtonStyle.secondaryFill), shape: shape)
                    }
                }
            }
            .brightness(GlassButtonStyle.brightness(pressed: c.isPressed, hover: hover))
            .contentShape(Rectangle())
    }

    private var iconButton: some View {
        c.label
            .coveFont(size: 13, weight: Glass3DTokens.Icon.weight)
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .glass3DRoundOutline()
            .brightness(GlassButtonStyle.brightness(pressed: c.isPressed, hover: false))
            .contentShape(Circle())
    }

    private var rowButton: some View {
        c.label
            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb, style: .continuous)
                .fill(Color.white.opacity(c.isPressed ? 0.16 : hover ? 0.1 : 0)))
    }

    /// Owner: hover never changes a control's size, so only light (brightness, soft shadow) on hover.
    private func liftButton(_ backing: Bool) -> some View {
        c.label
            .padding(backing ? Glass3DTokens.Space.xs : 0)
            .background(Capsule().fill(Color.white.opacity(backing && hover ? 0.16 : 0)))
            .padding(backing ? -Glass3DTokens.Space.xs : 0)
            .brightness(hover ? 0.12 : 0)
            .scaleEffect(c.isPressed ? 0.95 : 1)
            .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 8, y: 3)
            .scrollHover($hover)
            .handCursor()
            .animation(Glass3DTokens.Motion.fast, value: hover)
            .animation(Glass3DTokens.Motion.fast, value: c.isPressed)
    }

    @ViewBuilder private func accentRowButton(_ glass: Bool) -> some View {
        if glass {
            c.label
                .background { if hover || c.isPressed { Capsule().fill(Theme.accent(name).opacity(c.isPressed ? 0.7 : 0.55)) } }
                .scrollHover($hover)
        } else {
            c.label.background(Color.white.opacity(c.isPressed ? 0.15 : 0))
        }
    }
}

/// The 3D face of a solid button: the colour, a glossy highlight on the top half, a soft inner shadow at the bottom
/// and a thin lit top edge.
private struct SolidButtonFace<S: InsettableShape>: View {
    let color: Color
    let shape: S
    var body: some View {
        ZStack {
            shape.fill(color.shadow(.inner(color: .black.opacity(0.28), radius: 2, x: 0, y: -1.5)))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.26), Color.white.opacity(0.06), .clear],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), .clear, Color.black.opacity(0.18)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: color.opacity(0.3), radius: 4, y: 2)
        .allowsHitTesting(false)
    }
}
