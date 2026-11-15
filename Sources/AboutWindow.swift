import SwiftUI
import AppKit

/// Cove → About Cove: icon and name, the version in a card, what Cove is with links, the license.
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
            // Icon and name on one line keeps the window compact
            HStack(spacing: 14) {
                AppIconView(size: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cove").font(.system(size: 30, weight: .heavy))
                    Text("for Mac").font(.system(size: 13)).foregroundColor(.secondary)
                }
            }
            .padding(.top, 34).padding(.bottom, 20)

            VStack(spacing: 0) {
                infoRow("Version", versionText)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .padding(.horizontal, 28)

            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "play.rectangle.fill").foregroundColor(accent)
                    Text("Cove").font(.system(size: 16, weight: .bold))
                }
                Text("A native macOS client for Emby and Jellyfin, written in SwiftUI. Found a bug or have an idea? Let us know on GitHub.")
                    .multilineTextAlignment(.center).font(.system(size: 13)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    pill("Cove on GitHub", "chevron.left.forwardslash.chevron.right", primary: true) { open(Self.repo) }
                    pill("Releases", "shippingbox") { open(Self.repo.appendingPathComponent("releases")) }
                    pill("Report an issue", "exclamationmark.bubble") { open(Self.repo.appendingPathComponent("issues")) }
                }
                .padding(.top, 6)
                HStack(spacing: 16) {
                    Button("What's New in Cove…") { WhatsNew.show() }
                    Button("Check for Updates…") { Task { await Updater.shared.check(interactive: true) } }
                }
                .buttonStyle(.plainHand).font(.system(size: 12)).foregroundColor(accent)
                .padding(.top, 4)
            }
            .padding(.horizontal, 30).padding(.top, 24)

            Button { open(Self.repo.appendingPathComponent("blob/main/LICENSE")) } label: {
                Text("Cove © J0n4e · GNU GPL-3.0").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .buttonStyle(.plainHand).padding(.vertical, 20)
        }
        .frame(width: 460)
        .background(Theme.bg(bgName))
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    func open(_ u: URL) { NSWorkspace.shared.open(u) }

    /// A capsule button: filled with the accent (primary) or a soft glass fill.
    func pill(_ title: String, _ icon: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? Theme.onAccent(accentName) : .primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(primary ? accent : Color.white.opacity(0.1)))
                .overlay(Capsule().stroke(Color.white.opacity(primary ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plainHand)
    }

    func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundColor(.secondary)
            Spacer()
            Text(v).font(.system(size: 13, weight: .semibold).monospacedDigit()).textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
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
            let w = NSWindow(contentViewController: host)
            w.title = "About Cove"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.isMovableByWindowBackground = true
            w.setContentSize(host.sizeThatFits(in: NSSize(width: 460, height: 10_000)))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
