import SwiftUI

// MARK: - Users tab

struct ServerUsersTab: View {
    @StateObject private var model: ServerUsersModel
    @EnvironmentObject var emby: Emby
    @AppStorage("accent") private var accentName = "red"
    @State private var query = ""
    @State private var selected: AdminUser?
    @State private var adding = false

    init(admin: ServerAdmin) { _model = StateObject(wrappedValue: ServerUsersModel(kind: admin.kind, api: admin.api)) }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ServerSearchField(placeholder: "Search users", text: $query)
                    Spacer()
                    Button { adding = true } label: { Label("Add user…", systemImage: "person.badge.plus") }
                        .buttonStyle(AboutButton(primary: true, accentName: accentName))
                }
                if let e = model.error, model.users.isEmpty {
                    ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
                } else if !model.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let list = model.users.filter { AdminUser.matches($0, query) }
                    ScrollView {
                        ServerAdminCard(title: list.count == 1 ? "1 user" : "\(list.count) users") {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, u in
                                if i > 0 { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5) }
                                Button { selected = u } label: { row(u) }.buttonStyle(.plain)
                            }
                        }.padding(.bottom, 8)
                    }.scrollIndicators(.never)
                }
            }
            if adding { ServerAddUserSheet(model: model) { adding = false } }
            if let u = selected { ServerUserSheet(model: model, user: u) { selected = nil } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
    }

    func row(_ u: AdminUser) -> some View {
        HStack(spacing: 12) {
            ServerUserAvatar(user: u)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(u.name).cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(1)
                    if u.id == model.me { ServerBadge(text: "You", color: .gray) }
                    if u.isAdmin { ServerBadge(text: "Admin", color: Theme.accent(accentName)) }
                    if u.isDisabled { ServerBadge(text: "Disabled", color: .red) }
                    if u.isHidden { ServerBadge(text: "Hidden", color: .gray) }
                }
                Text(u.activityLine() + " · " + (u.hasPassword ? "Has password" : "No password"))
                    .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ServerUserAvatar: View {
    let user: AdminUser
    var size: CGFloat = 34
    @EnvironmentObject var emby: Emby
    var body: some View {
        let initials = ZStack {
            Circle().fill(Color.white.opacity(0.14))
            Text(AdminUser.initials(user.name)).cvFont(size * 0.38, weight: .bold).foregroundColor(.white)
        }
        Group {
            if let tag = user.imageTag, let url = URL(string: "\(emby.server)/Users/\(user.id)/Images/Primary?maxWidth=96&quality=80&tag=\(tag)") {
                CachedImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { initials }
            } else { initials }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
    }
}

struct ServerBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).cvFont(10, weight: .bold).foregroundColor(.white)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Capsule().fill(color.opacity(0.55)))
    }
}

struct ServerSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).cvFont(13).foregroundColor(.white)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Glass3DTokens.Grey.secondary) }
                    .buttonStyle(.plainHand)
            }
        }
        .padding(.horizontal, 12).frame(height: 30).frame(maxWidth: 320)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
    }
}

/// A dimmed in-window sheet in the Overview confirm style.
struct ServerSheet<C: View>: View {
    var width: CGFloat = 460
    let dismiss: () -> Void
    @ViewBuilder var content: C
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { dismiss() }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(20).frame(width: width)
                .modifier(PanelSurface(classic: true))
        }
    }
}

struct ServerField: View {
    let title: String
    @Binding var text: String
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
            Group {
                if secure { SecureField(title, text: $text) } else { TextField(title, text: $text) }
            }
            .textFieldStyle(.roundedBorder).cvFont(13)
        }
    }
}

// MARK: - Add user

struct ServerAddUserSheet: View {
    @ObservedObject var model: ServerUsersModel
    let close: () -> Void
    @AppStorage("accent") private var accentName = "red"
    @State private var name = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        ServerSheet(dismiss: close) {
            Text("Add user").cvFont(17, weight: .bold).foregroundColor(.white)
            ServerField(title: "Name", text: $name)
            ServerField(title: "Password (optional)", text: $password, secure: true)
            Text("The new user can see all libraries and has no administrator rights. Change that in the user's settings.")
                .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary).fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty { Text(error).cvFont(12).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { close() }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                Button("Add") {
                    busy = true; error = ""
                    Task {
                        let e = await model.create(name: name, password: password)
                        busy = false
                        if let e { error = e } else { password = ""; close() }
                    }
                }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - User detail

struct ServerUserSheet: View {
    @ObservedObject var model: ServerUsersModel
    let user: AdminUser
    let close: () -> Void
    @AppStorage("accent") private var accentName = "red"
    @State private var name = ""
    @State private var edit = UserPolicyEdit()
    @State private var original = UserPolicyEdit()
    @State private var newPassword = ""
    @State private var currentPassword = ""
    @State private var resetPassword = false
    @State private var busy = false
    @State private var error = ""
    @State private var summary: [String] = []
    @State private var deleting = false
    @State private var deleteName = ""

    var isSelf: Bool { user.id == model.me }

    var body: some View {
        ServerSheet(width: 600, dismiss: close) {
            HStack(spacing: 12) {
                ServerUserAvatar(user: user, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name).cvFont(17, weight: .bold).foregroundColor(.white)
                    Text(user.activityLine()).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ServerField(title: "Name", text: $name)
                    passwordSection
                    permissions
                    libraries
                    dangerZone
                }.padding(.trailing, 4)
            }
            .frame(maxHeight: 400).scrollIndicators(.never)
            if !error.isEmpty { Text(error).cvFont(12).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if !summary.isEmpty {
                Text("Saved: " + summary.joined(separator: " · ")).cvFont(12).foregroundColor(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { close() }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(AboutButton(primary: true, accentName: accentName)).disabled(busy)
            }
        }
        .task {
            name = user.name
            let e = UserPolicyEdit.from(user.policy)
            edit = e; original = e
        }
    }

    var passwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Password · " + (user.hasPassword ? "set" : "none"))
            if isSelf { ServerField(title: "Current password", text: $currentPassword, secure: true) }
            ServerField(title: "New password", text: $newPassword, secure: true).disabled(resetPassword)
            if user.hasPassword && !isSelf {
                Toggle("Remove the password (the user signs in without one)", isOn: $resetPassword).cvFont(12)
            }
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Permissions")
            ForEach(UserPolicyEdit.boolKeys.filter { $0.key != "EnableAllFolders" }, id: \.key) { k in
                let locked = isSelf && (k.key == "IsAdministrator" || k.key == "IsDisabled")
                Toggle(k.title, isOn: Binding(get: { edit[keyPath: k.path] }, set: { edit[keyPath: k.path] = $0 }))
                    .cvFont(13).disabled(locked)
                    .help(locked ? "You can't change this for your own account." : "")
            }
            HStack {
                Text("Max parental rating").cvFont(13).foregroundColor(.white)
                Spacer()
                GlassPicker(selection: $edit.maxParentalRating, options: ratingOptions)
            }
            if edit.syncPlayAccess != nil {
                HStack {
                    Text("SyncPlay").cvFont(13).foregroundColor(.white)
                    Spacer()
                    GlassPicker(selection: Binding(get: { edit.syncPlayAccess ?? "None" }, set: { edit.syncPlayAccess = $0 }),
                                options: UserAdminAPI.syncPlayOptions.map { ($0, UserAdminAPI.syncPlayTitle($0)) })
                }
            }
        }
    }

    var ratingOptions: [(Int?, String)] {
        var o: [(Int?, String)] = [(nil, "No limit")]
        for r in model.ratings { o.append((r.value, r.name)) }
        if let v = edit.maxParentalRating, !model.ratings.contains(where: { $0.value == v }) { o.append((v, String(v))) }
        return o
    }

    var libraries: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Library access")
            Toggle("All libraries", isOn: $edit.enableAllFolders).cvFont(13)
            if !edit.enableAllFolders {
                ForEach(model.folders, id: \.id) { f in
                    Toggle(f.name, isOn: Binding(
                        get: { edit.enabledFolders.contains { UserAdminAPI.sameId($0, f.id) } },
                        set: { on in
                            edit.enabledFolders.removeAll { UserAdminAPI.sameId($0, f.id) }
                            if on { edit.enabledFolders.append(f.id) }
                        })).cvFont(13).padding(.leading, 16)
                }
            }
        }
    }

    @ViewBuilder var dangerZone: some View {
        if UserAdminRules.canDelete(user, me: model.me) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Delete")
                if deleting {
                    Text("Type \u{201C}\(user.name)\u{201D} to delete this user. Their watch history and settings are removed too.")
                        .cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(user.name, text: $deleteName).textFieldStyle(.roundedBorder).cvFont(13)
                        Button("Delete user") { delete() }.buttonStyle(ServerDangerButton())
                            .disabled(!UserAdminRules.deleteConfirmed(deleteName, user: user) || busy)
                    }
                } else {
                    Button("Delete user…") { deleting = true }.buttonStyle(ServerDangerButton())
                }
            }
        }
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).cvFont(11, weight: .semibold).kerning(0.6).foregroundColor(Glass3DTokens.Grey.secondary).padding(.top, 4)
    }

    func save() {
        busy = true; error = ""; summary = []
        Task {
            let r = await model.save(user: user, name: name, edit: edit, original: original, newPassword: newPassword,
                                     currentPassword: currentPassword, resetPassword: resetPassword)
            busy = false
            newPassword = ""; currentPassword = ""; resetPassword = false
            summary = r.done
            if let e = r.error { error = e } else {
                original = edit
                if r.done.isEmpty { summary = ["nothing changed"] }
            }
        }
    }

    func delete() {
        busy = true; error = ""
        Task {
            let e = await model.delete(user)
            busy = false
            if let e { error = e } else { close() }
        }
    }
}
