import SwiftUI

/// Shown instead of an empty page when the server couldn't be reached or answered with an error.
struct ErrorStateView: View {
    let message: String
    var retry: () -> Void
    var switchServer: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Glass3DTokens.Space.l) {
            Image(systemName: "wifi.exclamationmark").coveFont(size: 40, weight: .light).foregroundStyle(Glass3DTokens.Grey.secondary)
                .accessibilityHidden(true)
            Text(message).coveFont(size: 13, weight: .bold).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: Glass3DTokens.Space.m) {
                Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise").classicPrimaryPill(size: 40) }
                    .buttonStyle(HoverButton()).keyboardShortcut(.defaultAction)
                if let switchServer {
                    Button(action: switchServer) { Label("Switch Server", systemImage: "server.rack").classicGlassPill(size: 40, iconOnly: false) }
                        .buttonStyle(HoverButton())
                }
            }
        }
        .padding(Glass3DTokens.Space.pageWide)
        .frame(maxWidth: .infinity)
    }
}

/// "Couldn't load more" at the end of a library grid, with a button to try the next page again.
struct LoadMoreFailedView: View {
    var retry: () -> Void
    var body: some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            Text("Couldn't load more.").foregroundStyle(Glass3DTokens.Grey.secondary)
            // A glass pill, not a grey system button
            Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise").classicGlassPill(size: 32, iconOnly: false) }
                .buttonStyle(HoverButton())
        }
        .padding(Glass3DTokens.Space.xl)
    }
}

extension View {
    /// The server stopped accepting the sign-in: offer to sign in again (the root view).
    func sessionExpiredAlert(_ emby: Emby) -> some View {
        alert("Signed out", isPresented: Binding(get: { emby.sessionExpired }, set: { emby.sessionExpired = $0 })) {
            Button("Sign In Again") { emby.expireSession() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("\(emby.currentServerName) no longer accepts your sign-in. Sign in again to keep using it.")
        }
    }
}
