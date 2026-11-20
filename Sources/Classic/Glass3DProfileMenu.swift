import AppKit
import SwiftUI

/// What each menu row does. Kept apart from the views so a section can go without touching the others.
@MainActor
enum ProfileActions {
    static func close() { ProfileModel.shared.menuOpen = false }

    /// Keeps the current user's sign-in among this server's users (Switch user… must not lose it).
    static func rememberCurrent(_ emby: Emby) {
        guard emby.loggedIn else { return }
        let name = emby.currentServer?.user ?? ProfileModel.shared.name
        ProfileUserStore.prune(keeping: Set(emby.servers.map(\.id)))
        ProfileUserStore.remember(server: emby.server, userId: emby.userId, user: name, token: emby.token)
    }

    static func open(_ section: String) {
        let nav = ClassicNavState.shared
        nav.query = ""; nav.searchOpen = false
        if nav.sel == section { nav.reselect += 1 }
        nav.sel = section; nav.popToRoot()
    }

    static func perform(_ r: ProfileRow, emby: Emby) {
        close()
        switch r {
        case .changePicture: ProfilePictureWindow.show(emby: emby)
        case .removePicture: ProfilePictureWindow.remove(emby: emby)
        case .server(let id, _, let current, _):
            guard !current, let s = emby.servers.first(where: { $0.id == id }) else { return }
            rememberCurrent(emby)
            ServerPill.pick(s, emby: emby)   // keeps sign-ins; lands on Home
        case .addServer:
            rememberCurrent(emby)
            ProfileJump.shared.prefill = .init(url: "", name: "")
            emby.switchServer()
        case .switchUser:
            rememberCurrent(emby)
            ProfileJump.shared.prefill = .init(url: emby.server, name: emby.currentServer?.name ?? "")
            emby.switchServer()   // the server list keeps this user's token; the login form opens prefilled
        case .otherUser(let key, _): switchTo(key, emby: emby)
        case .search:   // no top-bar button any more: ⌘F, S or this row opens the bottom search pill
            ClassicNavState.shared.focusSearch += 1
        case .myActivity:
            ProfileJump.shared.myActivityPending = true; ProfileJump.shared.myActivityTick += 1
            open("nowplaying")
        case .favorites: open("favorites")
        case .notifications:
            NotificationCenterStore.shared.requestShowList()
            open("nowplaying")
        case .settings: ClassicNavState.shared.showSettings = true
        case .checkUpdates: Task { await Updater.shared.check(interactive: true) }
        case .about: AboutWindow.show()
        case .signOut:
            ProfileUserStore.forget(server: emby.server, userId: emby.userId)
            emby.logout()
        }
    }

    /// One click to another user signed in on this server. The token is checked first, so an expired one never
    /// replaces the current user's saved sign-in.
    static func switchTo(_ key: String, emby: Emby) {
        guard let p = ProfileUserStore.split(key), let e = ProfileUserStore.all()[key],
              let s = emby.servers.first(where: { $0.id == p.server }),
              let url = URL(string: "\(s.url)/Users/\(p.userId)") else { return }
        rememberCurrent(emby)
        Task { @MainActor in
            var r = URLRequest(url: url, timeoutInterval: 10)
            emby.authorize(&r, token: e.token)
            let status = ((try? await Net.session.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                ProfileUserStore.forget(server: p.server, userId: p.userId)
                ProfileJump.shared.prefill = .init(url: s.url, name: s.name)
                emby.switchServer()
                return
            }
            guard status == 200 else { NSSound.beep(); return }
            let entry = SavedServer(url: s.url, name: s.name, user: e.user, token: e.token, userId: p.userId)
            guard await emby.resume(entry) == .ok else { NSSound.beep(); return }
            // The server list holds the user now in use (restart resumes this user)
            if let i = emby.servers.firstIndex(where: { $0.id == s.id }) {
                emby.servers[i] = entry
                ServerStore.save(emby.servers, to: .standard)
            }
        }
    }
}

/// The glass profile menu (Glass3D): You · Servers · Users · Shortcuts · App · Sign out.
struct Glass3DProfileMenu: View {
    static let width: CGFloat = 300
    @EnvironmentObject var emby: Emby
    @ObservedObject private var profile = ProfileModel.shared
    @ObservedObject private var inbox = NotificationCenterStore.shared
    @AppStorage("accent") private var accentName = "red"
    @State private var others: [ProfileMenuInput.OtherUser] = []

    var input: ProfileMenuInput {
        ProfileMenuInput(name: profile.name, jellyfin: emby.isJellyfin, admin: profile.admin, hasPicture: profile.imageTag != nil,
                         servers: emby.servers.map { .init(id: $0.id, name: ServerPill.title(name: $0.name, address: $0.url)) },
                         currentServer: emby.server, online: profile.online, otherUsers: others, unread: inbox.unread)
    }

    var body: some View {
        let sections = ProfileMenuSpec.sections(input, shown: ProfileMenuSpec.shown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { i, s in
                if i > 0 { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5).padding(.horizontal, 12) }
                section(s.0, s.1).padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
        .modifier(PanelSurface(classic: true))
        .task {
            others = ProfileUserStore.others(ProfileUserStore.all(), server: emby.server, currentUserId: emby.userId)
                .map { .init(key: $0.key, name: $0.entry.user) }
            await profile.checkOnline(emby.servers)
        }
    }

    @ViewBuilder func section(_ s: ProfileSection, _ rows: [ProfileRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch s {
            case .you: youHeader
            case .servers: heading("SERVERS")
            case .users: heading("USERS")
            case .shortcuts, .app, .signOut: EmptyView()
            }
            ForEach(rows) { r in row(r) }
        }
    }

    var youHeader: some View {
        HStack(spacing: 12) {
            ProfileAvatar(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? (emby.currentServer?.user ?? "") : profile.name)
                    .cvFont(14, weight: .bold).foregroundColor(.white).lineLimit(1)
                Text(ProfileMenuSpec.subtitle(jellyfin: emby.isJellyfin, admin: profile.admin))
                    .cvFont(11).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
    }

    func heading(_ t: String) -> some View {
        Text(t).cvFont(10, weight: .semibold).kerning(0.6).foregroundColor(.secondary)
            .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 2)
    }

    func icon(_ r: ProfileRow) -> String {
        switch r {
        case .changePicture: return "camera"
        case .removePicture: return "trash"
        case .server: return "server.rack"
        case .addServer: return "plus"
        case .switchUser: return "person.2"
        case .otherUser: return "person.crop.circle"
        case .search: return "magnifyingglass"
        case .myActivity: return ActivitySection.icon
        case .favorites: return "heart"
        case .notifications: return "bell"
        case .settings: return "gearshape"
        case .checkUpdates: return "arrow.down.circle"
        case .about: return "info.circle"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        }
    }

    func row(_ r: ProfileRow) -> some View {
        Button { ProfileActions.perform(r, emby: emby) } label: {
            HStack(spacing: 10) {
                if r == .signOut { Image(systemName: icon(r)).cvFont(12).frame(width: 18).foregroundColor(.red) }
                else { Image(systemName: icon(r)).cvFont(12).frame(width: 18).foregroundStyle(.tint) }
                if case .notifications(let n) = r {
                    Text("Notifications").cvFont(13).lineLimit(1)
                    if n > 0 {
                        Text("\(n)").cvFont(10, weight: .bold).foregroundColor(.white)
                            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Color.red))
                    }
                } else {
                    Text(ProfileMenuSpec.title(r)).cvFont(13, weight: r == .signOut ? .semibold : .regular).lineLimit(1)
                        .foregroundColor(r == .signOut ? .red : .white)
                }
                Spacer(minLength: 0)
                trailing(r)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle(glass: true))
        .padding(.horizontal, 4)
    }

    @ViewBuilder func trailing(_ r: ProfileRow) -> some View {
        switch r {
        case .server(_, _, let current, let online):
            Circle().fill(online == true ? Color.green : Color.gray.opacity(0.6)).frame(width: 7, height: 7)
                .help(online == nil ? "Checking…" : online! ? "Reachable" : "Not reachable")
            if current { Image(systemName: "checkmark").cvFont(11, weight: .bold).foregroundStyle(.tint) }
            else { Color.clear.frame(width: 11) }
        case .settings: Text("⌘,").cvFont(11).foregroundColor(.secondary)
        case .search: Text("⌘F").cvFont(11).foregroundColor(.secondary)
        default: EmptyView()
        }
    }
}

/// Activity's tab after "My activity": Overview; for admins with the Playback Reporting plugin the Users tab
/// drilled to the signed-in user. Applied with one `.modifier(...)` line in ClassicNowPlayingView.
struct ProfileActivityJump: ViewModifier {
    @Binding var tab: Int
    @ObservedObject var stats: StatsModel
    @EnvironmentObject var emby: Emby
    @ObservedObject private var jump = ProfileJump.shared
    @State private var drilling = false

    func body(content: Content) -> some View {
        content
            .onAppear { take() }
            .onChange(of: jump.myActivityTick) { take() }
            .onChange(of: stats.availability) { drill() }
            .onChange(of: stats.users.count) { drill() }
    }

    private func take() {
        guard jump.myActivityPending else { return }
        jump.myActivityPending = false
        tab = 2; drilling = true
        drill()
    }

    private func drill() {
        guard drilling, let a = stats.availability else { return }
        guard a == .available else { drilling = false; return }   // not admin: the normal Overview
        tab = 4
        let me = StatsDecode.norm(emby.userId)
        if let u = stats.users.first(where: { StatsDecode.norm($0.id) == me }) {
            drilling = false
            stats.userOverview = []; stats.selectedUser = u
        } else if stats.users.isEmpty && !stats.usersLoading {
            Task { await stats.loadUsers() }
        } else if !stats.usersLoading { drilling = false }
    }
}
