import SwiftUI

/// Shown instead of an empty page when the server couldn't be reached or answered with an error (both themes).
struct ErrorStateView: View {
    @Environment(\.classicGlass) private var classic
    let message: String
    var retry: () -> Void
    var switchServer: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message).font(.headline).multilineTextAlignment(.center).frame(maxWidth: 460)
            if classic {
                // Classic theme: glass buttons
                HStack(spacing: 12) {
                    Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise").classicGlassPill(size: 40, iconOnly: false) }
                        .buttonStyle(HoverButton()).keyboardShortcut(.defaultAction)
                    if let switchServer {
                        Button(action: switchServer) { Label("Switch Server", systemImage: "server.rack").classicGlassPill(size: 40, iconOnly: false) }
                            .buttonStyle(HoverButton())
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
                    if let switchServer { Button("Switch Server", action: switchServer) }
                }
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

/// "Couldn't load more" at the end of a library grid, with a button to try the next page again.
struct LoadMoreFailedView: View {
    var retry: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text("Couldn't load more.").foregroundStyle(.secondary)
            Button("Try Again", action: retry)
        }
        .padding(20)
    }
}

extension View {
    /// The server stopped accepting the sign-in: offer to sign in again (both themes' root views).
    func sessionExpiredAlert(_ emby: Emby) -> some View {
        alert("Signed out", isPresented: Binding(get: { emby.sessionExpired }, set: { emby.sessionExpired = $0 })) {
            Button("Sign In Again") { emby.expireSession() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("\(emby.currentServerName) no longer accepts your sign-in. Sign in again to keep using it.")
        }
    }
}
