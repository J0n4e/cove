import AppKit
import SwiftUI

/// Release notes (Markdown from GitHub) as text for the update and What's New windows.
enum ReleaseNotes {
    /// Only https links stay clickable (no javascript:, file:, http: … from a release body).
    static func safeLink(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Headings, lists, bold, code and links; plain text when the Markdown can't be read.
    static func render(_ md: String) -> NSAttributedString {
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "No release notes." : trimmed
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let a = try? AttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: base)
        }
        // .full parsing drops the line breaks between blocks; put them back from the block identities
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        for run in a.runs {
            let kinds = run.presentationIntent?.components.map(\.kind) ?? []
            let block = run.presentationIntent?.components.first?.identity
            let newBlock = block != nil && block != lastBlock
            if newBlock, lastBlock != nil { out.append(NSAttributedString(string: "\n")) }
            lastBlock = block ?? lastBlock
            let isList = kinds.contains { if case .listItem = $0 { return true }; return false }
            let isHeader = kinds.contains { if case .header = $0 { return true }; return false }
            var piece = String(a[run.range].characters)
            var font = NSFont.systemFont(ofSize: 13)
            if isHeader { font = .boldSystemFont(ofSize: 14) }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = .boldSystemFont(ofSize: font.pointSize) }
            if run.inlinePresentationIntent?.contains(.code) == true { font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
            if newBlock, isList { piece = "•  " + piece }
            var attrs = base
            attrs[.font] = font
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = isList ? 2 : 8
            attrs[.paragraphStyle] = para
            if let link = safeLink(run.link) { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

/// Scrollable, read-only release notes.
struct NotesText: NSViewRepresentable {
    let markdown: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.textStorage?.setAttributedString(ReleaseNotes.render(markdown))
        }
        return scroll
    }
    func updateNSView(_ v: NSScrollView, context: Context) {}
}

/// The Software Update and What's New windows: one plain window each, in the app's dark look and accent color.
@MainActor
enum CoveWindows {
    private static var windows: [String: NSWindow] = [:]

    static func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }

    static func show<V: View>(_ id: String, title: String, _ view: V) {
        windows[id]?.close()
        let accent = UserDefaults.standard.string(forKey: "accent") ?? "red"
        let host = NSHostingController(rootView: view.tint(Theme.accent(accent)).preferredColorScheme(.dark))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentViewController = host
        w.setContentSize(NSSize(width: 520, height: 420))
        w.contentMinSize = NSSize(width: 420, height: 320)
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) { windows[id]?.close() }
}

/// Icon on the left, bold title and a secondary line.
private struct WindowHeader: View {
    let title: String
    let subtitle: String?
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .bold))
                if let subtitle { Text(subtitle).foregroundColor(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Software Update: the new version's notes, progress while it installs, errors in red.
struct UpdateWindowView: View {
    let rel: Updater.Release
    let current: String
    @ObservedObject var up = Updater.shared

    var installing: Bool { up.status == .installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowHeader(title: "Cove \(AppVersion.pretty(rel.tag_name)) is available",
                         subtitle: "You have \(AppVersion.pretty(current)). Here's what's new:")
            NotesText(markdown: rel.body ?? "").frame(minHeight: 160)
            if let u = ReleaseNotes.safeLink(URL(string: rel.html_url)) {
                Link("View on GitHub", destination: u).font(.caption)
            }
            if installing {
                if let p = up.progress, p.total > 0 {
                    ProgressView(value: Double(p.received), total: Double(p.total))
                    Text("Downloading… " + Self.mb(p.received) + " of " + Self.mb(p.total))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text(up.progressText).font(.caption).foregroundColor(.secondary)
                }
            }
            if let e = up.windowError {
                Text(e).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Skip This Version") { up.skip(rel.tag_name) }
                Spacer()
                Button("Later") { CoveWindows.close(Updater.windowID) }
                Button("Install and Restart") { Task { await up.install() } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(installing)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .frame(minWidth: 420, minHeight: 320)
    }

    static func mb(_ n: Int64) -> String { String(format: "%.1f MB", Double(n) / 1_000_000) }
}

/// What's New in Cove <version>: the notes of the running version and Continue.
struct WhatsNewView: View {
    let version: String
    /// nil: the notes couldn't be loaded
    let notes: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowHeader(title: "What's New in Cove \(AppVersion.pretty(version))", subtitle: nil)
            if let notes {
                NotesText(markdown: notes).frame(minHeight: 160)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load the release notes.").foregroundColor(.secondary)
                    Link("See all releases on GitHub", destination: URL(string: "https://github.com/\(Updater.repo)/releases")!)
                }
                Spacer()
            }
            HStack {
                Spacer()
                Button("Continue") { CoveWindows.close(WhatsNew.windowID) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .frame(minWidth: 420, minHeight: 320)
    }
}

/// What's New: once after the app was updated, and from the Cove menu / Settings.
@MainActor
enum WhatsNew {
    static let windowID = "whatsNew"
    static let lastSeenKey = "LastSeenVersion"
    /// Saved by the updater right before it swaps the app: ["version": tag, "body": notes].
    static let pendingKey = "PendingWhatsNew"

    /// Only after an update to a higher version; a fresh install (nothing seen yet) or a downgrade shows nothing.
    nonisolated static func shouldShow(lastSeen: String?, current: String) -> Bool {
        guard let lastSeen else { return false }
        return Updater.isNewer(current, than: lastSeen)
    }

    nonisolated static func sameVersion(_ a: String, _ b: String) -> Bool {
        !Updater.isNewer(a, than: b) && !Updater.isNewer(b, than: a)
    }

    /// At launch: records the version and, right after an update, shows its notes (silently skipped if they can't be loaded).
    static func onLaunch() async {
        guard let cur = Updater.shared.current else { return }
        let d = UserDefaults.standard
        let last = d.string(forKey: lastSeenKey)
        d.set(cur, forKey: lastSeenKey)
        let saved = takePending(for: cur)
        guard shouldShow(lastSeen: last, current: cur) else { return }
        var notes = saved
        if notes == nil { notes = await Updater.fetchRelease(tag: cur)?.body }
        guard let notes else { return }
        CoveWindows.show(windowID, title: "What's New in Cove", WhatsNewView(version: cur, notes: notes))
    }

    /// Cove menu and Settings.
    static func show() {
        guard let cur = Updater.shared.current else {
            CoveWindows.show(windowID, title: "What's New in Cove", WhatsNewView(version: AppVersion.label, notes: nil))
            return
        }
        Task {
            let notes = await Updater.fetchRelease(tag: cur)?.body
            CoveWindows.show(windowID, title: "What's New in Cove", WhatsNewView(version: cur, notes: notes))
        }
    }

    private static func takePending(for cur: String) -> String? {
        let d = UserDefaults.standard
        guard let p = d.dictionary(forKey: pendingKey) else { return nil }
        d.removeObject(forKey: pendingKey)
        guard let v = p["version"] as? String, sameVersion(v, cur) else { return nil }
        return p["body"] as? String
    }
}

/// The app icon for Cove's own windows (Software Update, What's New, About). AppIcon.png carries the Dock's
/// 3 px translucent white rim and a drop shadow around the rounded square; drawn inside a window that rim read
/// as a grey frame. Here only the rounded square itself is shown: the picture is scaled so the square fills the
/// frame and clipped just inside the rim, high-quality interpolation, no extra background, stroke or shadow.
struct AppIconView: View {
    var size: CGFloat = 64
    /// The opaque square in the 1024 px AppIcon.png runs from 103 to 921 px; a little inside that, so no rim shows.
    private static let inner: CGFloat = 812
    var body: some View {
        let scale = 1024 / Self.inner
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high).antialiased(true)
            .frame(width: size * scale, height: size * scale)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
