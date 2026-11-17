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
    @State private var testing = false

    private var libraries: [LibPref] { emby.libs.filter { NewMediaLibrary.eligible(kind: $0.kind) } }
    private var offSet: Set<String> { Set(libsOff.split(separator: ",").map(String.init)) }

    private func libBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !offSet.contains(id) }, set: { on in
            var s = offSet
            if on { s.remove(id) } else { s.insert(id) }
            libsOff = s.sorted().joined(separator: ",")
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
                    Toggle("Only for shows I follow", isOn: $onlyFollowed)
                        .disabled(!episodes)
                        .padding(.leading, 20)
                }
            }
            PrefNote("A show you follow is one in your Favorites or with at least one episode watched. Things you've already started or watched are never announced.")
            if !libraries.isEmpty {
                PrefRow(label: "Libraries") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(libraries) { lib in Toggle(lib.title, isOn: libBinding(lib.id)) }
                    }
                }.disabled(!movies && !episodes)
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
            PrefNote("Cove checks your server every 10 minutes while it's open (Jellyfin with the live connection on: within seconds). Several new items arrive as one notification; clicking one opens it.")
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
