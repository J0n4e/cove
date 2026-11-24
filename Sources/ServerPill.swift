import AppKit
import SwiftUI

/// The connected server as a small glass pill at the top left of Home (both themes). Click: the current server and
/// user, the other saved servers (click to switch, landing on Home) and Switch Server…. Hidden while signed out.
enum ServerPill {
    /// The pill's title: the server's name, else its host, else the address; at most `cap` characters (…).
    nonisolated static func title(name: String, address: String, cap: Int = 30) -> String {
        var t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = URL(string: address)?.host ?? address.trimmingCharacters(in: .whitespacesAndNewlines) }
        if t.count > cap { t = String(t.prefix(max(1, cap - 1))).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    /// Another saved server: signs in with its saved session (the session change resets the page to Home);
    /// when that has expired, the server list opens to sign in again.
    @MainActor static func pick(_ s: SavedServer, emby: Emby) {
        guard s.token != nil else { emby.switchServer(); return }
        Task { @MainActor in
            switch await emby.resume(s) {
            case .ok: break
            case .expired: emby.switchServer()
            case .unreachable: NSSound.beep()   // stay on the current server
            }
        }
    }
}

/// The pill with its menu. `classic`: Glass3D's glass pill; otherwise the Glass theme's capsule.
struct ServerPillMenu: View {
    var classic: Bool
    @EnvironmentObject var emby: Emby

    var body: some View {
        if emby.loggedIn {
            let name = ServerPill.title(name: emby.currentServer?.name ?? "", address: emby.server)
            let user = emby.currentServer?.user ?? ""
            Menu {
                Button("✓ " + name + (user.isEmpty ? "" : " (\(user))")) {}.disabled(true)
                ForEach(emby.servers.filter { $0.id != emby.server.lowercased() }) { s in
                    Button(ServerPill.title(name: s.name, address: s.url) + (s.user.isEmpty ? "" : " (\(s.user))")) {
                        ServerPill.pick(s, emby: emby)
                    }
                }
                Divider()
                Button("Switch Server…") { emby.switchServer() }
            } label: {
                label(name)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(user.isEmpty ? "Connected to \(name)" : "Connected to \(name) as \(user)")
            .accessibilityLabel("Server: \(name)")
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)   // reads on a bright banner
        }
    }

    @ViewBuilder func label(_ name: String) -> some View {
        let row = HStack(spacing: Glass3DTokens.Space.s) {
            Image(systemName: "server.rack").imageScale(.small)
            Text(name).lineLimit(1)
        }
        .foregroundColor(.white)
        if classic {
            row.cvFont(12, weight: .medium)
                .padding(.horizontal, Glass3DTokens.Space.m).frame(height: 28)
                .classicGlassPill()
                .contentShape(Capsule())
        } else {
            row.coveFont(size: 12, weight: .medium)
                .padding(.horizontal, Glass3DTokens.Space.m).frame(height: 28)
                .glassCapsule()
                .contentShape(Capsule())
        }
    }
}
