import SwiftUI

/// A short message in a small glass window (instead of the system alert): "You're up to date", "Update failed"…
struct GlassMessageView: View {
    let title: String
    let text: String
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AppIconView(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).coveFont(size: 15, weight: .bold).glassReadable()
                    Text(text).coveFont(size: 12).foregroundColor(.white.opacity(0.85)).glassReadable()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("OK", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum GlassMessage {
    static let windowID = "glassMessage"
    @MainActor static func show(_ title: String, _ text: String) {
        CoveWindows.show(windowID, title: title, size: NSSize(width: 400, height: 170),
                         GlassMessageView(title: title, text: text) { CoveWindows.close(windowID) })
    }
}
