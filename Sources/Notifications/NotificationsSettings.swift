import SwiftUI
import AppKit

/// Settings → Home → Notifications: new movies and episodes as macOS notifications (both themes; the same
/// PrefSection / PrefRow rows as the rest of Settings).
struct NotificationsSettings: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var service = NewMediaService.shared
    @AppStorage(NewMediaPrefs.moviesKey) private var movies = true
    @AppStorage(NewMediaPrefs.episodesKey) private var episodes = true
    @AppStorage(NewMediaPrefs.followedKey) private var onlyFollowed = false
    @AppStorage(NewMediaPrefs.libsOffKey) private var libsOff = ""
    @AppStorage(NewMediaPrefs.tvModesKey) private var tvModes = ""
    @State private var testing = false

    private var libraries: [LibPref] { emby.libs.filter { NewMediaLibrary.eligible(kind: $0.kind) } }
    private var prefs: NewMediaPrefs {
        NewMediaPrefs(movies: movies, episodes: episodes, onlyFollowed: onlyFollowed,
                      libsOff: Set(libsOff.split(separator: ",").map(String.init)),
                      tvModes: NewMediaPrefs.decodeModes(tvModes))
    }

    /// On / off for this library on this server (a plain id from before applies everywhere: switching on clears it)
    private func libBinding(_ id: String) -> Binding<Bool> {
        let key = NewMediaPrefs.libKey(server: emby.server, library: id)
        return Binding(get: { prefs.libraryOn(server: emby.server, library: id) }, set: { on in
            var s = Set(libsOff.split(separator: ",").map(String.init))
            s.remove(id)
            if on { s.remove(key) } else { s.insert(key) }
            libsOff = s.sorted().joined(separator: ",")
        })
    }

    private func modeBinding(_ id: String) -> Binding<NewMediaTVMode> {
        Binding(get: { prefs.tvMode(server: emby.server, library: id) }, set: { m in
            var d = NewMediaPrefs.decodeModes(tvModes)
            d[NewMediaPrefs.libKey(server: emby.server, library: id)] = m
            tvModes = NewMediaPrefs.encodeModes(d)
        })
    }

    /// Turning a toggle on asks macOS for permission the first time.
    private func askIfOn(_ on: Bool) {
        guard on else { return }
        Task { await service.ensurePermission() }
    }

    var body: some View {
        PrefSection(title: "Notifications", last: true) {
            PrefRow(label: "Notify me about") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("New movies", isOn: $movies)
                    Toggle("New episodes", isOn: $episodes)
                }
            }
            if !libraries.isEmpty {
                PrefRow(label: "Libraries") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(libraries) { lib in
                            NotifLibraryRow(title: lib.title, tv: lib.kind != "movies", episodes: episodes,
                                            on: libBinding(lib.id), mode: modeBinding(lib.id))
                        }
                    }
                }.disabled(!movies && !episodes)
                PrefNote("Per library, for this server. \u{201C}Series I\u{2019}m watching\u{201D}: in your Favorites, or with an episode watched or started. Things you\u{2019}ve already started or watched are never announced.")
            }
            PrefRow(label: "Test") {
                Button("Send test notification") {
                    testing = true
                    Task { await service.sendTest(); testing = false }
                }.disabled(testing)
            }
            if service.permission == .denied {
                PrefRow {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Notifications are off for Cove in System Settings", systemImage: "bell.slash")
                            .foregroundColor(.secondary)
                        Button("Open System Settings") { NewMediaService.openSystemSettings() }
                    }
                }
            }
            PrefNote("Cove checks your server every 10 minutes while it's open (Jellyfin with the live connection on: within seconds). Several new episodes of a show (or 4+ movies) arrive as one notification with a picture; clicking one opens it.")
        }
        .onChange(of: movies) { _, on in askIfOn(on) }
        .onChange(of: episodes) { _, on in askIfOn(on) }
        .task {
            await service.refreshPermission()
            // Already on (the default) and never asked: ask now, while the user is looking at it
            if (movies || episodes) && service.permission == .notDetermined { await service.ensurePermission() }
        }
        // Back from System Settings: show the new answer
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.refreshPermission() }
        }
    }
}

/// One library in Settings → Notifications: its switch and, for shows, which new episodes notify.
private struct NotifLibraryRow: View {
    let title: String
    let tv: Bool
    let episodes: Bool
    @Binding var on: Bool
    @Binding var mode: NewMediaTVMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: $on)
            if tv && on && episodes {
                menuPicker($mode, [(NewMediaTVMode.all, "All new episodes"),
                                   (NewMediaTVMode.followed, "Only series I\u{2019}m watching or in Favorites")])
                    .fixedSize()
                    .padding(.leading, 20)
            }
        }
    }
}
