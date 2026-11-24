import SwiftUI

/// A count in a red circle with a white number (owner: Activity's streams number), '99+' above 99.
struct CountBadge: View {
    let count: Int
    var size: CGFloat = 20
    static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
    var body: some View {
        let t = Self.text(count)
        Text(t).coveFont(size: size * 0.6, weight: .bold, design: .rounded) { $0.monospacedDigit() }
            .foregroundColor(.white)
            .padding(.horizontal, t.count > 1 ? size * 0.25 : 0).frame(minWidth: size, minHeight: size)
            .background(Capsule().fill(Glass3DTokens.Status.danger))
            .fixedSize()
    }
}

/// The small red unread dot (Activity item, segment tabs), fitted inside the pill per the owner.
struct UnreadDot: View {
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(Glass3DTokens.Status.danger).frame(width: size, height: size).allowsHitTesting(false)
    }
}
