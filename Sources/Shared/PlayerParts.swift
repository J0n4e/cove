import IOKit.pwr_mgt
import SwiftUI
import Combine
import MediaPlayer
import AVKit

/// "‹ Back" pill button used on detail pages and in the player.
struct BackPill: View {
    var compact = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: "chevron.left").coveFont(size: compact ? 14 : 18, weight: .bold)
                Text("Back").coveFont(size: compact ? 14 : 16, weight: .semibold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 5 : 10)
            .background(Capsule().fill(Color.black.opacity(hover ? 0.85 : 0.6)))
            .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.7 : 0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButton())
        .focusEffectDisabled()   // no blue macOS focus ring when a page opens
        .scrollHover($hover)
        .animation(Glass3DTokens.Motion.fast, value: hover)
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// The same look for the player's icon menus (subtitles, quality), which can't take a button style.
struct HoverBacking: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(Glass3DTokens.Space.xs)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.16 : 0)))
            .padding(-4)
            .brightness(hover ? 0.12 : 0)
            .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 8, y: 3)
            .scrollHover($hover)
            .handCursor()
            .animation(Glass3DTokens.Motion.fast, value: hover)
    }
}

// MARK: - Media keys and Control Center

/// Play/pause and skip from the keyboard's media keys, AirPods and Control Center, with the title and
/// progress shown in the Mac's Now Playing widget.
@MainActor
enum RemoteControls {
    static func attach(_ m: PlayerModel, skip: Double) {
        let c = MPRemoteCommandCenter.shared()
        detach()
        // Weak: a theme switch mid-video must not keep the old player alive through these handlers
        c.togglePlayPauseCommand.addTarget { [weak m] _ in m?.togglePlay(); return .success }
        c.playCommand.addTarget { [weak m] _ in if let m, !m.playing { m.togglePlay() }; return .success }
        c.pauseCommand.addTarget { [weak m] _ in if let m, m.playing { m.togglePlay() }; return .success }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        c.skipForwardCommand.addTarget { [weak m] _ in m?.skip(skip); return .success }
        c.skipBackwardCommand.addTarget { [weak m] _ in m?.skip(-skip); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak m] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            m?.seek(to: e.positionTime); return .success
        }
    }

    static func detach() {
        let c = MPRemoteCommandCenter.shared()
        for cmd in [c.togglePlayPauseCommand, c.playCommand, c.pauseCommand, c.skipForwardCommand,
                    c.skipBackwardCommand, c.changePlaybackPositionCommand] as [MPRemoteCommand] {
            cmd.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    static func update(_ item: Item, _ m: PlayerModel) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.isEpisode ? item.Name : item.heroTitle,
            MPMediaItemPropertyPlaybackDuration: m.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: m.time,
            MPNowPlayingInfoPropertyPlaybackRate: m.playing ? Double(m.speed) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if item.isEpisode {
            info[MPMediaItemPropertyArtist] = "\(item.heroTitle) · S\(item.ParentIndexNumber ?? 0), E\(item.IndexNumber ?? 0)"
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = m.playing ? .playing : .paused
    }
}

// MARK: - Player window

/// The player for a request: trailers get the trailer player, everything else the Cove player.
struct ChosenPlayerView: View {
    let req: PlayRequest
    var body: some View {
        if let t = req.trailer { TrailerPlayerView(link: t) } else { ClassicPlayerView(req: req) }
    }
}

/// The subtitle and quality lists under their old names (Settings reads PlayerView.sizes etc.); the lists live in
/// PlayerUIModel.
enum PlayerView {
    static let sizes = PlayerUIModel.sizes
    static let colors = PlayerUIModel.colors
    static let shadows = PlayerUIModel.shadows
    static let bgs = PlayerUIModel.bgs
    static let qualities = PlayerUIModel.qualities
}

struct PanelRowStyle: ButtonStyle {   // thin alias for GlassButtonStyle(.accentRow)
    /// Classic theme: the line under the pointer lights up in the accent, as in the glass lists
    var glass = false
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonStyle(.accentRow(glass: glass)).makeBody(configuration: configuration)
    }
}

struct SubShadow: ViewModifier {
    let style: String
    let color: Color
    func body(content: Content) -> some View {
        switch style {
        case "drop":
            content.shadow(color: color.opacity(0.9), radius: 2, x: 1.5, y: 1.5).shadow(color: color.opacity(0.6), radius: 4)
        case "outline":
            content.shadow(color: color, radius: 0, x: 1, y: 1).shadow(color: color, radius: 0, x: -1, y: -1)
                .shadow(color: color, radius: 0, x: 1, y: -1).shadow(color: color, radius: 0, x: -1, y: 1)
        case "raised":
            content.shadow(color: color, radius: 0, x: 1, y: 2)
        default:
            content
        }
    }
}

/// AppKit video surface with no built-in controls; the SwiftUI overlay draws the UI.
/// (SwiftUI's VideoPlayer crashes on load on this macOS version.)
/// A plain AVPlayerLayer (picture-in-picture needs the layer). Clicks pass through to SwiftUI (click = play/pause).
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A window reference that doesn't keep the window alive.
final class WeakWindow {
    weak var window: NSWindow?
    /// Whether a notification's object is this window (false while the window isn't known yet).
    func owns(_ object: Any?) -> Bool { window != nil && (object as? NSWindow) === window }
}

/// Reports the window a view is in, when it's added to one (both themes' players use it to keep keys and
/// full-screen events to their own window).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { self.onWindow(w) }
        }
    }
}

struct AVPlayerViewRep: NSViewRepresentable {
    let player: AVPlayer
    var onLayer: (AVPlayerLayer) -> Void = { _ in }
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        let cb = onLayer, l = v.playerLayer
        DispatchQueue.main.async { cb(l) }
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Holds an IOKit assertion that stops the screen saver and display sleep while any player is playing.
/// Each player is an "owner", so the old player closing can't release the assertion the next episode just took.
enum KeepAwake {
    private static var id: IOPMAssertionID = 0
    private static var owners = Set<ObjectIdentifier>()
    static func set(_ on: Bool, owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if on { owners.insert(key) } else { owners.remove(key) }
        if !owners.isEmpty, id == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Cove is playing a video" as CFString, &id)
        } else if owners.isEmpty, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}
