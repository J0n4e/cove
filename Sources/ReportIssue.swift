import AppKit
import Foundation
import SwiftUI

/// Help → Report an Issue…: a GitHub bug report with the environment filled in, and an optional cleaned copy
/// of the debug log (tokens, addresses, session/device/user ids removed) to drag into the form.
enum ReportIssue {
    static let newIssue = "https://github.com/J0n4e/cove/issues/new"

    /// The environment fields of .github/ISSUE_TEMPLATE/bug_report.yml (ids must match the template).
    struct Info: Equatable {
        var version: String
        var server: String?          // "Emby" / "Jellyfin" (exact dropdown option), nil when not signed in
        var serverVersion: String?
        var macOS: String
        var environment: String
    }

    // Set by Emby.refreshServerKind; read on the main thread only
    @MainActor static var serverKind: String?
    @MainActor static var serverVersion: String?
    @MainActor static var serverAddress: String?
    @MainActor static func note(server: String, jellyfin: Bool, version: String?) {
        serverAddress = server.isEmpty ? nil : server
        serverKind = server.isEmpty ? nil : (jellyfin ? "Jellyfin" : "Emby")
        serverVersion = version
    }

    /// "Version 27.3 (Build 26C5047e)" → "27.3 (26C5047e)".
    static func shortMacOS(_ s: String) -> String {
        s.replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
    }

    static func textSizeName(_ key: String) -> String {
        key == "default" || key.isEmpty ? "Default" : key.prefix(1).uppercased() + key.dropFirst()
    }

    static func environment(model: String, textSize: String, debugLog: Bool) -> String {
        "\(model) · Text size: \(textSizeName(textSize)) · Debug log: \(debugLog ? "on" : "off")"
    }

    /// Query values are encoded strictly (only unreserved characters stay), so &, =, +, # and spaces can't break it.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func url(_ i: Info) -> URL {
        var q: [(String, String)] = [("template", "bug_report.yml"), ("title", "[Bug] "), ("version", i.version)]
        if let s = i.server { q.append(("server", s)) }
        if let v = i.serverVersion, !v.isEmpty { q.append(("server-version", v)) }
        q += [("macos", i.macOS), ("environment", i.environment)]
        return URL(string: newIssue + "?" + q.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&"))!
    }

    @MainActor static func current() -> Info {
        let d = UserDefaults.standard
        let b = AppVersion.build
        var v = b.isEmpty ? AppVersion.label : "\(AppVersion.label) (\(b))"
        if v.hasPrefix("v") { v.removeFirst() }
        return Info(version: v, server: serverKind, serverVersion: serverVersion,
                    macOS: shortMacOS(ProcessInfo.processInfo.operatingSystemVersionString),
                    environment: environment(model: macModel(), textSize: d.string(forKey: "textSize") ?? "default",
                                             debugLog: DebugLog.enabled))
    }

    static func macModel() -> String {
        var n = 0
        guard sysctlbyname("hw.model", nil, &n, nil, 0) == 0, n > 0 else { return "Mac" }
        var b = [CChar](repeating: 0, count: n)
        guard sysctlbyname("hw.model", &b, &n, nil, 0) == 0 else { return "Mac" }
        return String(cString: b)
    }

    // MARK: Log

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Cove.log")
    }

    static func lastLines(_ text: String, _ n: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.suffix(max(0, n)).joined(separator: "\n")
    }

    /// Removes secrets and private details from log text: tokens and keys (query parameters, headers, JSON),
    /// PlaySessionId / DeviceId / UserId values, IP addresses and host names (server address passed in, and any
    /// other URL host). Item ids and normal text stay.
    static func sanitise(_ text: String, server: String? = nil) -> String {
        var s = text
        func sub(_ pattern: String, _ template: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) {
            guard let r = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        // The known server's host first (also when it shows up without a scheme)
        if let server, let h = URL(string: server)?.host, !h.isEmpty {
            s = s.replacingOccurrences(of: h, with: "<server>", options: .caseInsensitive)
        }
        let secret = "api_?key|apikey|access_?token|x-emby-token|x-mediabrowser-token|token|password|pw|playsessionid|play_session_id|deviceid|device_?id|userid|user_?id|sessionid"
        // Authorization: MediaBrowser Client="Cove", Device="…", DeviceId="…", Version="1", Token="…" → whole value
        sub(#"(\b(?:x-emby-)?authorization\b["']?\s*[:=]\s*)[^\n]*"#, "$1<redacted>")
        // key=value in query strings / text, key: value in headers, "key":"value" in JSON
        sub(#"(\b(?:"# + secret + #")["']?\s*[=:]\s*["']?)[^\s&"',;}\]]+"#, "$1<redacted>")
        // /Users/<32 hex or GUID>/ in paths
        sub(#"(/Users/)[0-9a-f-]{32,36}"#, "$1<user>")
        // Other hosts in URLs (http(s)://, ws(s)://), keeping scheme and port
        sub(#"(\b(?:https?|wss?)://)(?:[^@/\s]+@)?(\[[0-9a-f:.]+\]|[a-z0-9.-]+)"#, "$1<server>")
        // IPv4 and IPv6 anywhere else
        sub(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>")
        // IPv6: needs "::" or all eight groups, so times like 12:34:56 stay
        sub(#"(?<![\w:])(?=[0-9a-f:]*::|(?:[0-9a-f]{1,4}:){7})[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}(?![\w:])"#, "<ip>")
        return s
    }

    /// Writes the cleaned last lines of Cove.log to a temporary folder; returns the file to reveal in Finder.
    static func writeSanitisedLog(server: String?, lines: Int = 300) throws -> URL {
        let raw = try String(contentsOf: logURL, encoding: .utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Cove report", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("Cove-report-log.txt")
        try sanitise(lastLines(raw, lines), server: server).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

/// The small glass sheet: what gets filled in, the log option and the button that opens GitHub.
struct ReportIssueView: View {
    @AppStorage("accent") private var accentName = "red"
    @State private var attach = false
    @State private var note: String?
    let info: ReportIssue.Info
    let logExists = FileManager.default.fileExists(atPath: ReportIssue.logURL.path)

    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            Text("Report an issue").coveFont(size: 18, weight: .bold).foregroundColor(.white)
            Text("GitHub opens a bug report with these filled in:").coveFont(size: 13).foregroundColor(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                row("Cove", info.version)
                row("Server", [info.server, info.serverVersion].compactMap { $0 }.joined(separator: " ").ifEmpty("—"))
                row("macOS", info.macOS)
                row("Mac", info.environment)
            }
            Toggle("Attach debug log (tokens, addresses and IDs removed)", isOn: $attach)
                .disabled(!logExists).coveFont(size: 13).foregroundColor(.white)
            if !DebugLog.enabled || !logExists {
                Text("Turn on Settings → Playback → Debug log, reproduce the problem, then report.")
                    .coveFont(size: 12).foregroundColor(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
            if let note { Text(note).coveFont(size: 12).foregroundColor(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Open GitHub report") { submit() }.buttonStyle(AboutButton(primary: true, accentName: accentName)) }
        }
        .glassReadable()
        .padding(.horizontal, Glass3DTokens.Space.xxl).padding(.top, Glass3DTokens.Space.pageWide).padding(.bottom, Glass3DTokens.Space.xl)
        .frame(width: ReportIssueWindow.size.width, height: ReportIssueWindow.size.height, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .tint(Theme.accent(accentName))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Glass3DTokens.Space.s) {
            Text(k).foregroundColor(.white.opacity(0.7)).frame(width: 60, alignment: .leading)
            Text(v).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
        }.coveFont(size: 12)
    }

    @MainActor private func submit() {
        if attach {
            do {
                let f = try ReportIssue.writeSanitisedLog(server: ReportIssue.serverAddress)
                NSWorkspace.shared.activateFileViewerSelecting([f])
                note = "Drag Cove-report-log.txt from Finder into the Logs box on GitHub."
            } catch { note = "Couldn't copy the debug log: \(error.localizedDescription)" }
        }
        NSWorkspace.shared.open(ReportIssue.url(info))
    }
}

private extension String { func ifEmpty(_ d: String) -> String { isEmpty ? d : self } }

@MainActor
enum ReportIssueWindow {
    private static var window: NSWindow?
    static let size = NSSize(width: 460, height: 340)

    static func show() {
        if window == nil {
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Report an Issue"
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible {
            let host = NSHostingView(rootView: ReportIssueView(info: ReportIssue.current()))
            host.sizingOptions = []
            CoveWindowLook.applyGlass(w, content: host, size: size)
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
