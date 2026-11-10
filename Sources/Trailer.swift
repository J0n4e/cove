import AppKit
import SwiftUI
import WebKit

/// Trailers: YouTube links play in a sheet over the window with YouTube's own player, no browser. Other links,
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

    private static var sheet: NSWindow?
    private static var escMonitor: Any?

    /// Trailer button: a YouTube trailer plays in Cove, anything else opens in the browser.
    static func open(_ u: URL) {
        guard let id = youTubeID(u), let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil
        else { NSWorkspace.shared.open(u); return }
        let w = min(max(parent.frame.width * 0.8, 640), 1280)
        let s = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: w * 9 / 16 + 52),
                         styleMask: [.titled], backing: .buffered, defer: false)
        s.contentView = NSHostingView(rootView: TrailerView(videoID: id, link: u, close: close)
            .preferredColorScheme(.dark))
        sheet = s
        // Esc closes it, also while the player has the keyboard
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard ev.keyCode == 53, ev.window === sheet else { return ev }
            close(); return nil
        }
        parent.beginSheet(s)
    }

    static func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        guard let s = sheet else { return }
        sheet = nil
        s.sheetParent?.endSheet(s)
        s.contentView = nil          // drops the web view, so the sound stops at once
    }
}

private struct TrailerView: View {
    let videoID: String
    let link: URL
    let close: () -> Void
    @State private var blocked = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if blocked {
                    VStack(spacing: 14) {
                        Image(systemName: "film").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("This trailer can only be played on YouTube.").font(.title3)
                        Button("Watch on YouTube") { NSWorkspace.shared.open(link); close() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    YouTubePlayer(videoID: videoID) { blocked = true }
                }
            }
            HStack {
                Button { NSWorkspace.shared.open(link); close() } label: { Label("Watch on YouTube", systemImage: "arrow.up.right.square") }
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).frame(height: 52)
        }
    }
}

/// YouTube's embedded player (IFrame API) in a web view. Links inside it open in the browser.
private struct YouTubePlayer: NSViewRepresentable {
    let videoID: String
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
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}

    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "cove")
        v.loadHTMLString("", baseURL: nil)
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
