import AppKit
import SwiftUI

/// Settings and About as see-through glass windows, like Cove's "You're up to date" alert: the desktop shows
/// blurred behind a rounded, clear panel with white text on it.
///
/// Built per macOS version:
/// - macOS 26+: an `NSGlassEffectView` (Liquid Glass) fills the window behind the SwiftUI content.
/// - macOS 14/15: an `NSVisualEffectView` (.hudWindow, behind-window blending, always active).
/// - Reduce Transparency: a dark, mostly opaque fill (0.85), never pure black and never see-through.
enum GlassWindowBackdrop: Equatable {
    case liquidGlass, visualEffect, reducedFill

    /// Corner radius of the glass panel (the update alert's).
    static let cornerRadius: CGFloat = 26
    /// Opacity of the dark fill used when Reduce Transparency is on.
    static let reducedFillAlpha: CGFloat = 0.85
    /// The fixed dark fill over the glass (Settings, About…), as the profile menu's panel
    static let panelFillAlpha: CGFloat = 0.75

    static func choose(liquidGlass: Bool, reduceTransparency: Bool) -> GlassWindowBackdrop {
        if reduceTransparency { return .reducedFill }
        return liquidGlass ? .liquidGlass : .visualEffect
    }

    /// Dark tint over the glass so white text stays readable on a bright desktop. Follows the Glass setting
    /// (Settings → General → Glass): "Follow macOS" keeps a light tint, otherwise the frost slider adds more.
    static func tintAlpha(follow: Bool, frost: Double) -> CGFloat {
        let f = frost.isFinite ? min(1, max(0, frost)) : GlassFrost.defaultFrost
        return follow ? 0.18 : CGFloat(0.08 + 0.4 * f)
    }

    @MainActor static var current: GlassWindowBackdrop {
        choose(liquidGlass: GlassFrost.hasLiquidGlass,
               reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
}

/// A plain container: the glass backdrop at the bottom, the SwiftUI hosting view on top, both filling it.
/// The hosting view is a subview (not the window's content view controller), so its size never drives the
/// window's frame (the macOS 27.3 safe-area layout loop).
@MainActor
final class GlassWindowContainer: NSView {
    private var backdrop: NSView?
    private var observers: [NSObjectProtocol] = []
    let content: NSView

    init(content: NSView, size: NSSize) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        rebuildBackdrop()
        addSubview(content)
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildBackdrop() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateTint() }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var tintAlpha: CGFloat {
        let d = UserDefaults.standard
        let follow = d.object(forKey: GlassFrost.followKey) as? Bool ?? true
        let frost = d.object(forKey: GlassFrost.frostKey) as? Double ?? GlassFrost.defaultFrost
        return GlassWindowBackdrop.tintAlpha(follow: follow, frost: frost)
    }

    private func makeBackdrop(_ kind: GlassWindowBackdrop) -> NSView {
        let r = GlassWindowBackdrop.cornerRadius
        switch kind {
        case .liquidGlass:
            if #available(macOS 26, *) {
                let g = NSGlassEffectView()
                g.cornerRadius = r
                g.tintColor = NSColor.black.withAlphaComponent(tintAlpha)
                return g
            }
            fallthrough
        case .visualEffect:
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = r
            v.layer?.masksToBounds = true
            return v
        case .reducedFill:
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(white: 0.08, alpha: GlassWindowBackdrop.reducedFillAlpha).cgColor
            v.layer?.cornerRadius = r
            v.layer?.masksToBounds = true
            return v
        }
    }

    private var panelFill: NSView?

    func rebuildBackdrop() {
        backdrop?.removeFromSuperview()
        let b = makeBackdrop(GlassWindowBackdrop.current)
        b.frame = bounds
        b.autoresizingMask = [.width, .height]
        // A fixed fill of the app's background colour at 75% over the glass, like the profile menu (PanelSurface):
        // the same look on any desktop, independent of the Glass slider (owner)
        let fill = NSView(frame: bounds)
        fill.wantsLayer = true
        fill.autoresizingMask = [.width, .height]
        fill.layer?.backgroundColor = NSColor(Theme.bg(UserDefaults.standard.string(forKey: "bg") ?? "black"))
            .withAlphaComponent(GlassWindowBackdrop.panelFillAlpha).cgColor
        fill.layer?.cornerRadius = GlassWindowBackdrop.cornerRadius
        fill.layer?.masksToBounds = true
        panelFill?.removeFromSuperview()
        addSubview(b, positioned: .below, relativeTo: content.superview === self ? content : nil)
        addSubview(fill, positioned: .above, relativeTo: b)   // a sibling: NSGlassEffectView only shows its contentView
        backdrop = b
        panelFill = fill
    }

    private func updateTint() {
        if #available(macOS 26, *), let g = backdrop as? NSGlassEffectView {
            let c = NSColor.black.withAlphaComponent(tintAlpha)
            if g.tintColor != c { g.tintColor = c }
        }
    }
}

extension CoveWindowLook {
    /// Turns a window into a see-through glass panel hosting `content` at a fixed size (no automatic sizing).
    static func applyGlass(_ w: NSWindow, content: NSView, size: NSSize) {
        // Settings, About, Report an issue, Change picture: open OVER a full-screen Cove instead of macOS switching
        // to the desktop Space and leaving the main window behind (owner)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.contentView = GlassWindowContainer(content: content, size: size)
        w.setContentSize(size)
        w.invalidateShadow()
    }
}

/// White text with a soft dark shadow, readable straight on the glass (like the top bar tabs).
struct GlassReadable: ViewModifier {
    func body(content: Content) -> some View {
        // The unselected top bar tabs' treatment (owner): two dark shadows, a tight one and a soft halo
        content
            .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 0.5)
            .shadow(color: .black.opacity(0.6), radius: 5, x: 0, y: 0)
    }
}
extension View { func glassReadable() -> some View { modifier(GlassReadable()) } }
