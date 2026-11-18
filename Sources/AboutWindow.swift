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
            VStack(spacing: 12) {
                // Like the update alert: the app icon on top, the bold white name under it
                AppIconView(size: 84)
                (Text("Cove for Mac").foregroundColor(.white) + Text(".").foregroundColor(accent))
                    .coveFont(size: 20, weight: .bold)
                Text("Version \(versionText.hasPrefix("v") ? String(versionText.dropFirst()) : versionText)")
                    .coveFont(size: 13).foregroundColor(Color.white.opacity(0.9))
                    .padding(.top, -4)
                Text("A native macOS client for Emby and Jellyfin. Found a bug or have an idea? Let us know on GitHub.")
                    .multilineTextAlignment(.center).coveFont(size: 14).foregroundColor(Color.white.opacity(0.95))
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
            .glassReadable()
            .padding(.horizontal, 40).padding(.top, 44)

            Button { open(Self.repo.appendingPathComponent("blob/main/LICENSE")) } label: {
                Text("© 2026 J0n4e · GNU GPL-3.0")
                    .coveFont(size: 11).foregroundColor(Color.white.opacity(0.85)).glassReadable()
            }
            .buttonStyle(.plainHand).padding(.top, 22).padding(.bottom, 26)
        }
        .frame(width: AboutWindow.size.width)
        .frame(height: AboutWindow.size.height, alignment: .top)
        // Content starts at the top edge (under the transparent title bar), straight on the window's glass
        // (GlassWindowContainer); no opaque background of its own
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    func open(_ u: URL) { NSWorkspace.shared.open(u) }
}

/// Nexview's button style in Cove's accent: a gradient-filled primary, a dark outlined secondary.
/// Labels never wrap, so both buttons stay on one line and the same height.
struct AboutButton: ButtonStyle {   // shared by About, Software Update and What's New
    var primary = false
    var accentName = "red"
    func makeBody(configuration c: Configuration) -> some View {
        let a = Theme.accent(accentName)
        return c.label
            .coveFont(size: 13, weight: .semibold)
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

/// One look for every Cove window (Settings, About, Software Update, What's New): dark appearance, a transparent
/// full-size title bar and the window itself painted with the selected Background (kept in sync live), so no
/// default grey can show anywhere — not under the title bar, not below the SwiftUI content, not while resizing.
@MainActor
enum CoveWindowLook {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    private static var observer: NSObjectProtocol?

    static var background: NSColor { NSColor(Theme.bg(UserDefaults.standard.string(forKey: "bg") ?? "black")) }

    static func apply(_ w: NSWindow) {
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = background
        windows.add(w)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: nil, queue: .main) { _ in
                Task { @MainActor in CoveWindowLook.refresh() }
            }
        }
    }

    static func refresh() {
        let c = background
        for w in windows.allObjects where w.backgroundColor != c { w.backgroundColor = c }
    }
}

/// The selected Background behind a window's content, filling the whole window (title bar included).
struct CoveWindowBackground: ViewModifier {
    @AppStorage("bg") private var bgName = "black"
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg(bgName).ignoresSafeArea())
    }
}
extension View { func coveWindowBackground() -> some View { modifier(CoveWindowBackground()) } }

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
    /// Room for the icon, name, version, text, buttons and footer at the larger text sizes.
    static let size = NSSize(width: 520, height: 430)

    static func show() {
        if window == nil {
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: AboutWindow.size),
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            w.title = "About Cove"
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible {
            // A plain NSHostingView with no automatic sizing (macOS 27.3 crashed on the hosting view and the
            // safe area resizing each other). Measured once, then the window gets that fixed size.
            let host = NSHostingView(rootView: AboutView())
            host.sizingOptions = []
            // A fixed size: the measured fitting size came out too short on the glass window and cut off
            // the buttons and the footer (owner)
            CoveWindowLook.applyGlass(w, content: host, size: AboutWindow.size)
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
