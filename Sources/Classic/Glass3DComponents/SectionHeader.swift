import SwiftUI

/// A heading: `.page` is the section size in bold (page rows), `.eyebrow` the small uppercased grey title on cards.
struct SectionHeader: View {
    enum Style { case page, eyebrow }
    let title: String
    var style: Style = .eyebrow

    /// The text as shown (eyebrows are uppercased).
    static func shown(_ title: String, style: Style) -> String { style == .eyebrow ? title.uppercased() : title }

    var body: some View {
        switch style {
        case .page:
            Text(Self.shown(title, style: style)).cvFont(Glass3DTokens.Text.section, weight: .bold)
        case .eyebrow:
            Text(Self.shown(title, style: style)).cvFont(11, weight: .semibold).kerning(0.6)
                .foregroundColor(Glass3DTokens.Grey.secondary)
        }
    }
}
