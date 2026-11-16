import AppKit
import CryptoKit
import Foundation
import IOKit
import Security
import SwiftUI

// Small security helpers shared by both themes.

/// Links that come from the server's metadata (trailers, external links) are opened only when they are web
/// links. Anything else (file://, smb://, other apps' URL schemes) could make macOS mount a share or launch an app.
enum SafeLink {
    static func url(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              u.host?.isEmpty == false else { return nil }
        return u
    }
}

/// The URLSession for talking to the media server. Follows redirects only to the same host (and never from
/// https down to http), so the token in our headers and links can't be forwarded to another server.
enum Net {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // No response cache: API answers (and the requests with our sign-in headers) would otherwise be written
        // to ~/Library/Caches and stay there after signing out
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    /// Same scheme, host and port (default ports filled in: http 80, https 443). The scheme must match so a
    /// reply from an https server can't point us (and our token) at http://same-host:443/. Order of the
    /// arguments doesn't matter; http → https upgrades of redirects are handled in SameHostRedirects.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let sa = a.scheme?.lowercased(), let sb = b.scheme?.lowercased(), sa == sb,
              sa == "http" || sa == "https", let ha = a.host?.lowercased(), !ha.isEmpty else { return false }
        func port(_ u: URL) -> Int { u.port ?? (sa == "https" ? 443 : 80) }
        return ha == b.host?.lowercased() && port(a) == port(b)
    }
}

final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url ?? response.url, let to = request.url else { completionHandler(nil); return }
        let downgrade = from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https"
        // Allow an upgrade to https on the same host (port changes from 80 to 443 there)
        let upgrade = from.scheme?.lowercased() == "http" && to.scheme?.lowercased() == "https"
            && from.host?.lowercased() == to.host?.lowercased()
        // nil = don't follow; the caller gets the redirect response itself (and treats it as a failure)
        completionHandler(!downgrade && (Net.sameOrigin(from, to) || upgrade) ? request : nil)
    }
}

/// Player debug log at ~/Library/Logs/Cove.log. Off unless switched on in Settings → Playback; kept under
/// about 1 MB (the previous part is moved to Cove.old.log).
enum DebugLog {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugLog") }
    private static let maxBytes = 1_000_000
    private static let lock = NSLock()
    private static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs") }

    static func write(_ m: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(m)\n"
        let u = dir.appendingPathComponent("Cove.log"), old = dir.appendingPathComponent("Cove.old.log")
        lock.withLock {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int, size > maxBytes {
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: u, to: old)
            }
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: u) }
        }
    }
}

/// Keychain items for sign-in tokens (one per server, account = the server's address in lower case).
/// Not used for storage right now (see Emby.saveServers): only read once to move tokens that test builds put
/// there back to the preferences file, then deleted. Ready for when Cove has an Apple Developer ID.
enum TokenStore {
    private static let service = "eu.jonae.cove.token"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// nil (or empty) deletes the item.
    static func set(_ token: String?, for account: String) {
        let q = query(account)
        guard let token, !token.isEmpty else { SecItemDelete(q as CFDictionary); return }
        if get(account) == token { return }
        let data = Data(token.utf8)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Cove sign-in (\(account))"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Whether a server address is encrypted, and whether plain http stays on the home network.
enum ConnectionSecurity {
    enum Kind { case encrypted, localPlain, remotePlain }

    static func kind(_ address: String) -> Kind {
        guard let u = URL(string: address), u.scheme?.lowercased() == "http" else { return .encrypted }
        return isPrivate(u.host ?? "") ? .localPlain : .remotePlain
    }

    /// LAN, loopback, link-local, Tailscale (CGNAT range and *.ts.net, both inside its encrypted tunnel) and local names.
    static func isPrivate(_ rawHost: String) -> Bool {
        let h = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { return false }
        // A bare number (http://134744072, http://0x7f000001) is an IP address in disguise, not a local name
        let numeric = h.allSatisfy(\.isNumber) || h.hasPrefix("0x")
        if h == "localhost" || !h.contains(".") && !h.contains(":") && !numeric { return true }   // single-label name
        for suffix in [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain", ".ts.net"] where h.hasSuffix(suffix) { return true }
        // Only plain dotted quads: no leading zeros (010 can mean octal 8) or other number forms
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        func octet(_ s: Substring) -> Bool {
            !s.isEmpty && s.count <= 3 && s.allSatisfy { $0.isASCII && $0.isNumber } && (s.count == 1 || s.first != "0")
        }
        let plain = parts.count == 4 && parts.allSatisfy(octet)
        let p = plain ? parts.compactMap { Int($0) } : []
        if plain, p.count == 4, p.allSatisfy({ (0...255).contains($0) }) {
            switch (p[0], p[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if h.contains(":") {                                                               // IPv6
            return h == "::1" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9")
                || h.hasPrefix("fea") || h.hasPrefix("feb")
        }
        return false
    }

    /// Asked before a password is sent unencrypted over the internet. true = go ahead.
    @MainActor static func confirmPlainHTTP(_ address: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "This connection isn't encrypted"
        a.informativeText = "\(address) uses plain http and isn't on your home network, so your password and the "
            + "sign-in can be read by anyone on the networks in between (for example public Wi-Fi).\n\n"
            + "If the server has an https address, use that instead."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Sign In Anyway")
        return a.runModal() == .alertSecondButtonReturn
    }
}

/// Lock icon for a saved server: encrypted, plain http at home, or plain http over the internet.
struct ConnectionBadge: View {
    let address: String
    var body: some View {
        switch ConnectionSecurity.kind(address) {
        case .encrypted:
            Image(systemName: "lock.fill").foregroundColor(.secondary).tip("Encrypted connection (https)")
        case .localPlain:
            Image(systemName: "lock.open").foregroundColor(.secondary).tip("Not encrypted (http), on your home network")
        case .remotePlain:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                .tip("Not encrypted (http) over the internet: the sign-in can be read on the network. Use an https address if the server has one.")
        }
    }
}

/// Small secrets in the preferences file, sealed (AES-GCM) with a key made from this Mac's hardware id, so they
/// never appear as plain text there and a copied preferences file is useless on another Mac. This is scrambling,
/// not real protection: another program running as you on this Mac can rebuild the key. The Keychain waits for an
/// Apple Developer ID for the same reason as the server tokens (see TokenStore).
enum SealedPrefs {
    private static func derive(_ seed: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("eu.jonae.cove.sealed.\(seed)".utf8)))
    }

    private static let hardwareId: String? = {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if svc != 0 { IOObjectRelease(svc) } }
        let id = IORegistryEntryCreateCFProperty(svc, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        if id?.isEmpty ?? true { coveLog.error("This Mac's hardware id could not be read; sealing with a random key") }
        return id?.isEmpty == false ? id : nil
    }()

    /// Before 1.18 a missing hardware id silently gave the same key on every Mac; still opened, never written.
    private static let legacyKey = derive("cove")

    /// Key for new data: from the hardware id, or (if it can't be read) a random seed saved once in `d`.
    private static func key(_ d: UserDefaults) -> SymmetricKey {
        if let hw = hardwareId { return derive(hw) }
        if let r = d.string(forKey: "sealedSeed") { return derive("random." + r) }
        let r = UUID().uuidString
        d.set(r, forKey: "sealedSeed")
        return derive("random." + r)
    }

    static func get(_ name: String, in d: UserDefaults = .standard) -> String? {
        guard let data = d.data(forKey: name), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        for k in [key(d), legacyKey] {
            if let plain = try? AES.GCM.open(box, using: k) { return String(data: plain, encoding: .utf8) }
        }
        return nil
    }

    /// nil (or empty) removes it.
    static func set(_ value: String?, for name: String, in d: UserDefaults = .standard) {
        guard let value, !value.isEmpty else { d.removeObject(forKey: name); return }
        guard let box = try? AES.GCM.seal(Data(value.utf8), using: key(d)).combined else {
            coveLog.error("Could not seal \(name, privacy: .public)"); return
        }
        d.set(box, forKey: name)
    }
}
