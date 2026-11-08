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
        guard !checkedThisLaunch, Self.autoCheck else { return }
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
        status = .checking
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: d) else {
            status = .failed("Couldn't reach GitHub.")
            if interactive { alert("Couldn't check for updates", "GitHub didn't answer. Try again later.") }
            return
        }
        latest = rel
        if Self.isNewer(rel.tag_name, than: cur) {
            status = .available(rel.tag_name)
            prompt(rel, current: cur)
        } else {
            status = .upToDate
            if interactive { alert("You're up to date", "\(AppVersion.pretty(cur)) is the latest version.") }
        }
    }

    static var signingKey: Curve25519.Signing.PublicKey? {
        Data(base64Encoded: publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    // MARK: Version compare ("v1.2" > "v1.1" > "v1.0" > "v0.10Beta"; a release beats a beta of the same number)

    static func key(_ tag: String) -> (nums: [Int], release: Bool) {
        let t = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let numPart = t.prefix { $0.isNumber || $0 == "." }
        let nums = numPart.split(separator: ".").compactMap { Int($0) }
        return (nums, numPart.count == t.count)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
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

    private func prompt(_ rel: Release, current: String) {
        var notes = (rel.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        let a = NSAlert()
        a.messageText = "Version \(AppVersion.pretty(rel.tag_name)) is available"
        a.informativeText = "You have \(AppVersion.pretty(current)).\n\n\(notes)"
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Release Notes")
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install() }
        case .alertThirdButtonReturn: if let u = URL(string: rel.html_url) { NSWorkspace.shared.open(u) }
        default: break
        }
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
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("CoveUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Err("Download failed.") }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
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
            try relaunch(replacing: target, with: newApp, work: work)
        } catch {
            fail((error as? Err)?.msg ?? error.localizedDescription)
        }
    }

    /// Hands off to a small shell script that waits for us to quit, swaps the bundle (restoring the old one if
    /// anything fails), clears quarantine and opens the new app. The new app goes exactly where the running one is,
    /// under the same name, so no other copy of Cove in that folder is touched.
    private func relaunch(replacing target: URL, with newApp: URL, work: URL) throws {
        let script = """
        #!/bin/sh
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        T="$2"; N="$3"
        rm -rf "$T.old"
        if mv "$T" "$T.old" && ditto "$N" "$T"; then
          rm -rf "$T.old"
        else
          rm -rf "$T"; mv "$T.old" "$T"
        fi
        xattr -dr com.apple.quarantine "$T" 2>/dev/null
        open "$T"
        rm -rf "$4"
        """
        let s = work.appendingPathComponent("swap.sh")
        try script.write(to: s, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [s.path, String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path, work.path]
        try p.run()
        // An open sheet (Settings, where the update is usually started) can keep the app from quitting, and the
        // script then waits forever. Close sheets first, and if the app is still running a moment later, quit anyway.
        for w in NSApp.windows { for sheet in w.sheets { w.endSheet(sheet) } }
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
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
        alert("Update failed", m)
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
                    Button("Install Update") { Task { await up.install() } }
                } else {
                    Button("Check for Updates") { Task { await up.check(interactive: true) } }
                        .disabled(up.status == .checking || up.status == .installing)
                }
                if up.status == .checking || up.status == .installing { Spinner().controlSize(.small) }
                Text(statusText).foregroundColor(.secondary).lineLimit(2)
            }
            Toggle("Check for updates automatically", isOn: $auto)
        }
    }
}
