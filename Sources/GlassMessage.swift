import SwiftUI

/// A short message in a small glass window (instead of the system alert): "You're up to date", "Update failed"…
struct GlassMessageView: View {
    let title: String
    let text: String
    let close: () -> Void
    var body: some View {
        // An even square (owner): icon on top, title, text, OK across the bottom — everything centred
        VStack(spacing: Glass3DTokens.Space.m) {
            AppIconView(size: 64)
            Text(title).coveFont(size: 15, weight: .bold).glassReadable().multilineTextAlignment(.center)
            Text(text).coveFont(size: 12).foregroundColor(.white.opacity(0.85)).glassReadable()
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: close) { Text("OK").frame(maxWidth: .infinity) }
                .controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Glass3DTokens.Space.xl).padding(.bottom, Glass3DTokens.Space.xl).padding(.top, Glass3DTokens.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum GlassMessage {
    static let windowID = "glassMessage"
    /// An even square; bigger text sizes / longer texts make the whole square bigger
    static func size(text: String) -> NSSize {
        let scale: CGFloat = TextScale.inApp(UserDefaults.standard.string(forKey: "textSize") ?? "default")
        let extra = CGFloat(max(0, min(3, (text.count - 1) / 34))) * CGFloat(18)
        let side = (CGFloat(260) + extra) * max(CGFloat(1), scale)
        return NSSize(width: side, height: side)
    }
    @MainActor static func show(_ title: String, _ text: String) {
        CoveWindows.show(windowID, title: title, size: GlassMessage.size(text: text),
                         GlassMessageView(title: title, text: text) { CoveWindows.close(windowID) })
    }
}
