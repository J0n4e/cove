import SwiftUI

/// A page / section with nothing to show: a symbol, a bold title, one line of explanation and an optional action.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// Smaller symbol and padding, for side bars and cards
    var compact = false

    /// What VoiceOver reads: "Title. Message".
    static func spoken(title: String, message: String?) -> String {
        guard let m = message, !m.isEmpty else { return title }
        return title + ". " + m
    }
    /// The Help sidebar's line when a search finds nothing.
    static func helpNoMatch(_ query: String) -> String { "No help topic matches \u{201C}\(query)\u{201D}." }

    var body: some View {
        VStack(spacing: compact ? Glass3DTokens.Space.s : Glass3DTokens.Space.m) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                .coveFont(size: compact ? 22 : 34, weight: .light)
                .foregroundColor(Glass3DTokens.Grey.secondary)
            Text(title).coveFont(size: compact ? 13 : 15, weight: .bold)
                .foregroundColor(Glass3DTokens.Grey.primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message).coveFont(size: compact ? 12 : 13)
                    .foregroundColor(Glass3DTokens.Grey.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(GlassButtonStyle(.secondary)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(compact ? Glass3DTokens.Space.m : 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(title: title, message: message))
    }
}
