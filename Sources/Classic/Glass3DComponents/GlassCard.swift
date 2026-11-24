import SwiftUI

/// The shared glass card: an optional eyebrow title over the content, on the level-2 surface. Admin cards, Settings
/// sections and Stats cards all use this look; callers pass their own padding / radius so their sizes stay the same.
struct GlassCard<Content: View>: View {
    var title: String? = nil
    var padding: CGFloat = Glass3DTokens.Space.l
    var spacing: CGFloat = 8
    var radius: CGFloat = Glass3DTokens.Radius.panel
    var level: Int = 2
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title { SectionHeader(title: title, style: .eyebrow) }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(level, radius: radius)
    }
}

extension View {
    /// The GlassCard surface around an existing layout: `padding` inside, the level's surface behind.
    func glassCard(padding: CGFloat = Glass3DTokens.Space.l, radius: CGFloat = Glass3DTokens.Radius.panel,
                   level: Int = 2) -> some View {
        self.padding(padding).elevation(level, radius: radius)
    }
}
