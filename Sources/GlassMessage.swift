import SwiftUI

/// A short message in a small glass window (instead of the system alert): "You're up to date", "Update failed"…
struct GlassMessageView: View {
    let title: String
    let text: String
    let close: () -> Void
    var body: some View {
        // One compact row (owner: the message window was too big): icon · title + text · OK
        HStack(alignment: .center, spacing: 12) {
            AppIconView(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).coveFont(size: 14, weight: .bold).glassReadable()
                Text(text).coveFont(size: 12).foregroundColor(.white.opacity(0.85)).glassReadable()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("OK", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

enum GlassMessage {
    static let windowID = "glassMessage"
    /// Compact: one row; a taller window only for longer texts or bigger text sizes
    static func size(text: String) -> NSSize {
        let scale: CGFloat = TextScale.inApp(UserDefaults.standard.string(forKey: "textSize") ?? "default")
        let lines = CGFloat(max(1, min(4, (text.count + 41) / 42)))
        return NSSize(width: 360, height: (CGFloat(70) + lines * CGFloat(16)) * max(CGFloat(1), scale))
    }
    @MainActor static func show(_ title: String, _ text: String) {
        CoveWindows.show(windowID, title: title, size: GlassMessage.size(text: text),
                         GlassMessageView(title: title, text: text) { CoveWindows.close(windowID) })
    }
}
