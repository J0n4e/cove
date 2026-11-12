import AppKit
import SwiftUI
import WebKit

/// Trailers: YouTube links play in the player area with YouTube's own player, no browser. Other links,
/// and YouTube videos whose owner doesn't allow playing outside YouTube, open in the browser.
@MainActor
enum Trailer {
    /// The 11-character video id of a YouTube link (watch, youtu.be, embed, shorts), or nil.
    nonisolated static func youTubeID(_ u: URL) -> String? {
        guard let host = u.host?.lowercased() else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com"
                    || host.hasSuffix(".youtube-nocookie.com") {
            if parts.first == "watch" {
                id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["embed", "shorts", "v", "live"].contains(parts[0]) {
                id = parts[1]
            }
        }
        // Only letters, digits, - and _ : the id goes into the page that loads the player
        guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }

    /// Trailer button: a YouTube trailer plays in the player area like a video, anything else opens in the browser.
    static func open(_ u: URL, item: Item, emby: Emby) {
        guard youTubeID(u) != nil else { NSWorkspace.shared.open(u); return }
        emby.playing = PlayRequest(item: item, trailer: u)
    }
}

/// Plays a trailer where videos play (in the window or the separate player window). Esc leaves full screen,
/// then the trailer; F toggles full screen.
struct TrailerPlayerView: View {
    @EnvironmentObject var emby: Emby
    let link: URL
    @State private var blocked = false
    @State private var playerWin = WeakWindow()
    @State private var web = WebViewBox()
    @State private var keyMonitor: Any?
    @State private var enteredFullScreen = false
    @State private var isFullScreen = false

    var videoID: String { Trailer.youTubeID(link) ?? "" }
    var separate: Bool { UserDefaults.standard.bool(forKey: "separatePlayer") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                backButton.helpLabel("Back (Esc)")
                Spacer()
                Button { NSWorkspace.shared.open(link); close() } label: {
                    Label("Watch on YouTube", systemImage: "arrow.up.right.square")
                }.buttonStyle(.plainHand).foregroundStyle(.secondary)
                Button { if let w = playerWin.window { toggleFullScreen(w) } } label: {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 34)
                }
                .buttonStyle(HoverButton(backing: true))
                .helpLabel(isFullScreen ? "Exit full screen (F)" : "Full screen (F)")
            }
            // The separate window has no title bar: room for its window buttons
            .padding(.leading, separate ? 80 : 14).padding(.trailing, 14).frame(height: 48)
            ZStack {
                Color.black
                if blocked {
                    VStack(spacing: 14) {
                        Image(systemName: "film").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("This trailer can only be played on YouTube.").font(.title3)
                        Button("Watch on YouTube") { NSWorkspace.shared.open(link); close() }
                            .buttonStyle(.borderedProminent).handCursor()
                    }
                } else {
                    YouTubePlayer(videoID: videoID, box: web) { blocked = true }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background(WindowReader { playerWin.window = $0 })
        .onAppear {
            let win = playerWin
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                guard let w = win.window, ev.window === w, w.attachedSheet == nil else { return ev }
                if ev.keyCode == 3, ev.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    if !ev.isARepeat { toggleFullScreen(w) }
                    return nil
                }
                guard ev.keyCode == 53 else { return ev }
                if w.styleMask.contains(.fullScreen) { toggleFullScreen(w) } else { close() }
                return nil
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            web.stop()
        }
        // Keeps the full screen button's icon right, however full screen was entered (F, button, green button)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if playerWin.owns(n.object) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            if playerWin.owns(n.object) { isFullScreen = false }
        }
        .task { isFullScreen = playerWin.window?.styleMask.contains(.fullScreen) ?? false }
    }

    @AppStorage("theme") private var theme = "apple"

    /// The page Back button of the current theme: Glass's round ‹, Classic's "‹ Back" capsule.
    /// (The pages' own Back buttons switch off while something plays, so these are drawn here.)
    @ViewBuilder var backButton: some View {
        if theme == "apple" {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .contentShape(Circle())
            }.buttonStyle(HoverButton())
        } else {
            Button(action: close) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text("Back").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.18)))
                .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
                .contentShape(Capsule())
            }.buttonStyle(HoverButton())
        }
    }

    func toggleFullScreen(_ w: NSWindow) {
        w.collectionBehavior.insert(.fullScreenPrimary)
        if !w.styleMask.contains(.fullScreen) { enteredFullScreen = true }
        DispatchQueue.main.async { w.toggleFullScreen(nil) }   // after the key event, as in the video player
    }

    func close() {
        if enteredFullScreen, let w = playerWin.window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        enteredFullScreen = false
        web.stop()   // the sound stops now, even if the page lingers until the view is torn down
        emby.playing = nil
    }
}

/// The trailer's web view, so leaving the trailer can silence it. Leaving used to rely on SwiftUI tearing the
/// web view down, which didn't always happen (after Esc the sound played on until Cove quit).
@MainActor
final class WebViewBox {
    weak var view: WKWebView?

    /// Pauses the video, unloads the page and takes the web view off screen. Safe to call more than once.
    func stop() {
        guard let v = view else { return }
        view = nil
        YouTubePlayer.stop(v)
    }
}

/// YouTube's embedded player (IFrame API) in a web view. Links inside it open in the browser.
private struct YouTubePlayer: NSViewRepresentable {
    let videoID: String
    let box: WebViewBox
    let onError: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.add(context.coordinator, name: "cove")
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.setValue(false, forKey: "drawsBackground")
        // YouTube refuses embeds without a referrer; apps identify themselves by their bundle id
        v.loadHTMLString(html, baseURL: URL(string: "https://eu.jonae.cove/"))
        box.view = v
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}

    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) { stop(v) }

    static func stop(_ v: WKWebView) {
        v.configuration.userContentController.removeAllScriptMessageHandlers()
        v.pauseAllMediaPlayback(completionHandler: nil)
        v.stopLoading()
        v.loadHTMLString("", baseURL: nil)
        v.removeFromSuperview()
    }

    var html: String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        function onYouTubeIframeAPIReady() {
          new YT.Player('p', { videoId: '\(videoID)',
            playerVars: { autoplay: 1, playsinline: 1, rel: 0, fs: 0 },
            events: { onError: function (e) { window.webkit.messageHandlers.cove.postMessage(e.data); } } });
        }
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let onError: () -> Void
        init(onError: @escaping () -> Void) { self.onError = onError }

        /// The player reported an error (101/150: the owner doesn't allow embedding, others: not playable here)
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            onError()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated && action.targetFrame?.isMainFrame != false {
                if let u = SafeLink.url(action.request.url?.absoluteString) { NSWorkspace.shared.open(u) }
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        /// Links that want a new window (the YouTube title and logo) open in the browser
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = SafeLink.url(action.request.url?.absoluteString) { NSWorkspace.shared.open(u) }
            return nil
        }
    }
}
