import SwiftUI
import AppKit

/// Cove → About Cove: one line with the icon and name, what Cove is, two buttons and the license.
/// Laid out like the Nexview Mac app's About, in Cove's dark look and accent color.
struct AboutView: View {
    @AppStorage("accent") private var accentName = "red"
    @AppStorage("bg") private var bgName = "black"
    var accent: Color { Theme.accent(accentName) }

    static let repo = URL(string: "https://github.com/J0n4e/cove")!

    var versionText: String {
        let b = AppVersion.build
        return b.isEmpty ? AppVersion.label : "\(AppVersion.label) (\(b))"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    AppIconView(size: 22)
                    (Text("Cove for Mac").foregroundColor(.white) + Text(".").foregroundColor(accent))
                        .font(.system(size: 16, weight: .bold))
                }
                Text("A native macOS client for Emby and Jellyfin. Found a bug or have an idea? Let us know on GitHub.")
                    .multilineTextAlignment(.center).font(.system(size: 13)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { open(Self.repo) } label: {
                        Label("Cove on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                    Button { open(Self.repo.appendingPathComponent("issues")) } label: {
                        Label("Report an issue", systemImage: "exclamationmark.bubble")
                    }.buttonStyle(AboutButton(accentName: accentName))
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 34).padding(.top, 34)

            Button { open(Self.repo.appendingPathComponent("blob/main/LICENSE")) } label: {
                Text("Cove \(versionText) · © 2026 J0n4e · GNU GPL-3.0")
                    .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
            }
            .buttonStyle(.plainHand).padding(.vertical, 20)
        }
        .frame(width: 440)
        .background(Theme.bg(bgName).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    func open(_ u: URL) { NSWorkspace.shared.open(u) }
}

/// Nexview's button style in Cove's accent: a gradient-filled primary, a dark outlined secondary.
/// Labels never wrap, so both buttons stay on one line and the same height.
struct AboutButton: ButtonStyle {
    var primary = false
    var accentName = "red"
    func makeBody(configuration c: Configuration) -> some View {
        let a = Theme.accent(accentName)
        return c.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundColor(primary ? Theme.onAccent(accentName) : .white)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(primary
                          ? AnyShapeStyle(LinearGradient(colors: [a.opacity(0.85), a, a.opacity(0.7)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.white.opacity(0.08)))
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(primary ? Color.clear : Color.white.opacity(0.12), lineWidth: 1))
            .opacity(c.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// A window that Esc and ⌘W close (About and Settings).
final class PanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performKeyEquivalent(with ev: NSEvent) -> Bool {
        if ev.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           ev.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil); return true
        }
        return super.performKeyEquivalent(with: ev)
    }
}

/// One About window; About Cove again brings it to the front.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            host.sizingOptions = [.minSize]
            let w = PanelWindow(contentViewController: host)
            w.title = "About Cove"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.isMovableByWindowBackground = true
            window = w
        }
        guard let w = window else { return }
        w.backgroundColor = NSColor(Theme.bg(UserDefaults.standard.string(forKey: "bg") ?? "black"))
        if !w.isVisible, let host = w.contentViewController as? NSHostingController<AboutView> {
            w.setContentSize(host.sizeThatFits(in: NSSize(width: 440, height: 10_000)))
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
