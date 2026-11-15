import AppKit
import CryptoKit
import SwiftUI

/// Checks GitHub for a newer full release, downloads it, swaps it in place of the running app and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "J0n4e/cove"
    /// Ed25519 public key that release zips are signed with (scripts/make-update-key.swift creates the pair; the
    /// private half is the COVE_UPDATE_KEY secret of the "release" environment). An update installs only if
    /// Cove.zip.sig verifies. Changing this key needs a rotation release (RELEASING.md).
    static let publicKey = "0qZwLSzqChcnofE15nvcUzLNEZuAB2SSaC3mdEC5Ysc="

    enum Status: Equatable { case idle, checking, upToDate, available(String), installing, failed(String) }
    @Published var status: Status = .idle
    /// Bytes received / expected while the update downloads (nil until the size is known).
    @Published var progress: (received: Int64, total: Int64)?
    @Published var progressText = ""
    /// An install failure, shown in red in the Software Update window.
    @Published var windowError: String?
    static let windowID = "softwareUpdate"
    /// The tag the user chose "Skip This Version" for; automatic checks don't offer it again.
    static let skippedKey = "SkippedUpdateVersion"
    private var latest: Release?
    private var checkedThisLaunch = false

    struct Release: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String
        let assets: [Asset]
        /// `digest`: "sha256:…", computed by GitHub when the file was uploaded.
        struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String? }
    }

    /// Raw version from the bundle ("v1.2"), nil when run outside a built app.
    var current: String? {
        let v = Bundle.main.infoDictionary?["CoveVersion"] as? String
        return (v?.isEmpty ?? true) ? nil : v
    }

    static var autoCheck: Bool { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }

    /// Once per launch, a few seconds after start; only speaks up when there is an update.
    func checkOnLaunch() async {
        guard !checkedThisLaunch, Self.autoCheck, !Self.isDevBuild else { return }
        checkedThisLaunch = true
        try? await Task.sleep(for: .seconds(5))
        await check(interactive: false)
    }

    /// `interactive`: also tell the user when they're up to date or the check failed.
    func check(interactive: Bool) async {
        guard let cur = current else {
            status = .failed("Updates work only in the built app.")
            if interactive { alert("Can't check for updates", "This copy isn't a built app bundle.") }
            return
        }
        if status == .installing { showWindow(); return }
        status = .checking
        guard let rel = await Self.fetch("releases/latest") else {
            status = .failed("Couldn't reach GitHub.")
            if interactive { alert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        latest = rel
        if Self.isNewer(rel.tag_name, than: cur) {
            let d = UserDefaults.standard
            let skipped = d.string(forKey: Self.skippedKey)
            if Self.suppressed(rel.tag_name, skipped: skipped, interactive: interactive) { status = .idle; return }
            // A newer release than the skipped one, or asked for by hand: the skip no longer applies
            if skipped != nil { d.removeObject(forKey: Self.skippedKey) }
            status = .available(rel.tag_name)
            showWindow()
        } else {
            status = .upToDate
            if interactive { alert("You're up to date", "\(AppVersion.pretty(cur)) is the latest version.") }
        }
    }

    /// Automatic checks stay quiet about the exact version the user skipped; a manual check, or any other
    /// (newer) version, is shown.
    nonisolated static func suppressed(_ tag: String, skipped: String?, interactive: Bool) -> Bool {
        !interactive && skipped == tag
    }

    /// GET https://api.github.com/repos/<repo>/<path> as a release; nil on any failure.
    nonisolated static func fetch(_ path: String) async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else { return nil }
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Release.self, from: d)
    }

    /// The release with this tag ("v1.17.1", as the release tags are written).
    nonisolated static func fetchRelease(tag: String) async -> Release? {
        guard let t = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) else { return nil }
        return await fetch("releases/tags/\(t)")
    }

    static var signingKey: Curve25519.Signing.PublicKey? {
        Data(base64Encoded: publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// A local build between releases ("v1.16.0-5-gc5f529b": commits after the tag, from make-app.sh). It would
    /// always look older than the release it's based on, so it doesn't ask at launch; Check for Updates still works.
    static var isDevBuild: Bool {
        let v = Bundle.main.infoDictionary?["CoveVersion"] as? String ?? ""
        return v.range(of: #"-\d+-g[0-9a-f]+$"#, options: .regularExpression) != nil
    }

    // MARK: Version compare ("v1.2" > "v1.1" > "v1.0" > "v0.10Beta"; a release beats a beta of the same number)

    nonisolated static func key(_ tag: String) -> (nums: [Int], release: Bool) {
        let t = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let numPart = t.prefix { $0.isNumber || $0 == "." }
        let nums = numPart.split(separator: ".").compactMap { Int($0) }
        return (nums, numPart.count == t.count)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = key(a), y = key(b)
        for i in 0..<max(x.nums.count, y.nums.count) {
            let p = i < x.nums.count ? x.nums[i] : 0, q = i < y.nums.count ? y.nums[i] : 0
            if p != q { return p > q }
        }
        return x.release && !y.release
    }

    // MARK: UI

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Opens (or brings to the front) the Software Update window for the pending release.
    func showWindow() {
        guard let rel = latest, let cur = current else { return }
        switch status {
        case .available, .installing, .failed: break
        default: return
        }
        if status != .installing { windowError = nil }
        CoveWindows.show(Self.windowID, title: "Software Update", UpdateWindowView(rel: rel, current: cur))
    }

    func skip(_ tag: String) {
        UserDefaults.standard.set(tag, forKey: Self.skippedKey)
        CoveWindows.close(Self.windowID)
    }

    // MARK: Install

    func install() async {
        guard let rel = latest,
              let asset = rel.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let url = URL(string: asset.browser_download_url) else {
            fail("This release has no app download."); return
        }
        guard let key = Self.signingKey else {
            fail("This copy of Cove can't check update signatures. Download the new version from GitHub instead."); return
        }
        guard let sigAsset = rel.assets.first(where: { $0.name == asset.name + ".sig" }),
              let sigURL = URL(string: sigAsset.browser_download_url) else {
            fail("This release isn't signed, so it won't be installed. Download it from GitHub if you trust it."); return
        }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            fail("Can't replace the app in \(target.deletingLastPathComponent().path). Download it from GitHub instead.")
            return
        }
        status = .installing
        windowError = nil
        progress = nil
        progressText = "Downloading \(AppVersion.pretty(rel.tag_name))…"
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("CoveUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let zip = work.appendingPathComponent("update.zip")
            let resp = try await Self.download(url, to: zip) { got, total in
                Task { @MainActor in
                    guard Updater.shared.status == .installing else { return }
                    Updater.shared.progress = total > 0 ? (got, total) : nil
                }
            }
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Err("Download failed.") }
            progress = nil
            progressText = "Verifying…"
            // Before anything in the download is opened: it must be exactly what Cove's release key signed
            let zipData = try Data(contentsOf: zip)
            if let d = asset.digest?.lowercased(), d.hasPrefix("sha256:"),
               d.dropFirst(7) != SHA256.hash(data: zipData).map({ String(format: "%02x", $0) }).joined() {
                throw Err("The download is damaged (checksum mismatch).")
            }
            let (sig, sresp) = try await URLSession.shared.data(for: URLRequest(url: sigURL, timeoutInterval: 20))
            guard (sresp as? HTTPURLResponse)?.statusCode == 200, key.isValidSignature(sig, for: zipData) else {
                throw Err("The update's signature is not valid, so it was not installed.")
            }
            // Unzip exactly the bytes that were checked (not the downloaded file, which could change after the check)
            let verified = work.appendingPathComponent("verified.zip")
            guard FileManager.default.createFile(atPath: verified.path, contents: zipData,
                                                 attributes: [.posixPermissions: 0o600]) else { throw Err("Couldn't save the update.") }
            let out = work.appendingPathComponent("new")
            guard await run("/usr/bin/ditto", ["-x", "-k", verified.path, out.path]) == 0 else { throw Err("Couldn't unzip the update.") }
            // Any app in the zip (releases ship Cove.app)
            let found = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
            guard let newApp = found.first(where: { $0.pathExtension == "app" }) else { throw Err("The download didn't contain the app.") }
            guard await run("/usr/bin/codesign", ["-v", newApp.path]) == 0 else { throw Err("The downloaded app failed its signature check.") }
            // What's New after the relaunch shows these notes (no second request to GitHub)
            UserDefaults.standard.set(["version": rel.tag_name, "body": rel.body ?? ""], forKey: WhatsNew.pendingKey)
            progressText = "Restarting…"
            try relaunch(replacing: target, with: newApp, work: work)
        } catch {
            fail((error as? Err)?.msg ?? error.localizedDescription)
        }
    }

    /// The swap script. Arguments: pid to wait for, the app to replace, the new app, the work folder (removed at
    /// the end), and optionally the command that opens the app afterwards (`open`; the tests pass `true`).
    /// The running app is only ever moved aside, never deleted, until the new one is fully in place; whatever
    /// fails, the original app ends up back where it was and is opened again.
    nonisolated static let swapScript = """
        #!/bin/sh
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        T="$2"; N="$3"; W="$4"; OPEN="${5:-open}"
        reopen() { xattr -dr com.apple.quarantine "$T" 2>/dev/null; "$OPEN" "$T"; rm -rf "$W"; }
        # A leftover from an earlier attempt: clear it, and if that fails don't touch the app
        rm -rf "$T.old" 2>/dev/null
        if [ -e "$T.old" ]; then echo "swap: couldn't remove $T.old" >&2; reopen; exit 1; fi
        if ! mv "$T" "$T.old"; then echo "swap: couldn't move the app aside" >&2; reopen; exit 1; fi
        if ! ditto "$N" "$T"; then
          echo "swap: couldn't copy the new app, restoring the old one" >&2
          rm -rf "$T"; mv "$T.old" "$T"; reopen; exit 1
        fi
        rm -rf "$T.old"
        reopen
        """

    /// Hands off to a small shell script that waits for us to quit, swaps the bundle (restoring the old one if
    /// anything fails), clears quarantine and opens the new app. The new app goes exactly where the running one is,
    /// under the same name, so no other copy of Cove in that folder is touched.
    private func relaunch(replacing target: URL, with newApp: URL, work: URL) throws {
        let script = Self.swapScript
        let s = work.appendingPathComponent("swap.sh")
        try script.write(to: s, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [s.path, String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path, work.path]
        try p.run()
        // An open sheet (Settings, where the update is usually started) can keep the app from quitting, and the
        // script then waits forever. Close sheets first, and if the app is still running a moment later, quit anyway.
        for w in NSApp.windows { for sheet in w.sheets { w.endSheet(sheet) } }
        SettingsWindow.close()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    /// Downloads to `dest` (moved there before the temporary file goes away), reporting bytes received / expected.
    nonisolated private static func download(_ url: URL, to dest: URL,
                                             progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URLResponse {
        final class Box: @unchecked Sendable { var obs: NSKeyValueObservation? }
        let box = Box()
        return try await withCheckedThrowingContinuation { c in
            let task = URLSession.shared.downloadTask(with: url) { file, resp, err in
                box.obs?.invalidate()
                guard let file, let resp else { c.resume(throwing: err ?? Err("Download failed.")); return }
                do { try FileManager.default.moveItem(at: file, to: dest); c.resume(returning: resp) }
                catch { c.resume(throwing: error) }
            }
            box.obs = task.progress.observe(\.completedUnitCount) { [weak task] _, _ in
                guard let task else { return }
                progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
            }
            task.resume()
        }
    }

    private func run(_ tool: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
    }

    private func fail(_ m: String) {
        status = .failed(m)
        progress = nil
        // In the window when it's open (buttons enabled again for a retry), otherwise an alert
        if CoveWindows.isOpen(Self.windowID) { windowError = m } else { alert("Update failed", m) }
    }

    private struct Err: Error { let msg: String; init(_ m: String) { msg = m } }
}

/// Settings → About row.
struct UpdateRow: View {
    @ObservedObject var up = Updater.shared
    @AppStorage("autoUpdateCheck") private var auto = true

    var statusText: String {
        switch up.status {
        case .idle: return ""
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let v): return "\(AppVersion.pretty(v)) available"
        case .installing: return "Downloading and installing…"
        case .failed(let m): return m
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if case .available = up.status {
                    Button("Install Update…") { up.showWindow() }
                } else if up.status == .installing {
                    Button("Show Progress…") { up.showWindow() }
                } else {
                    Button("Check for Updates") { Task { await up.check(interactive: true) } }
                        .disabled(up.status == .checking || up.status == .installing)
                }
                if up.status == .checking || up.status == .installing { Spinner().controlSize(.small) }
                Text(statusText).foregroundColor(.secondary).lineLimit(2)
            }
            Toggle("Check for updates automatically", isOn: $auto)
            Button("What's New in Cove…") { WhatsNew.show() }
                .buttonStyle(.link).font(.caption)
        }
    }
}
