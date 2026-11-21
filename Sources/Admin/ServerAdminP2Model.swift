import Foundation

/// Users tab state. Passwords live only in the sheet's fields and the request body; nothing here logs them.
@MainActor
final class ServerUsersModel: ObservableObject {
    @Published var users: [AdminUser] = []
    @Published var loaded = false
    @Published var error: String?
    @Published var ratings: [(value: Int, name: String)] = []
    @Published var folders: [(id: String, name: String)] = []

    let kind: ServerAdminKind
    let api: ServerAdminAPI
    var me: String { api.userId }

    init(kind: ServerAdminKind, api: ServerAdminAPI) { self.kind = kind; self.api = api }

    func load() async {
        let (d, st) = await api.request(UserAdminAPI.list)
        if st == 200, let d, let u = AdminUser.decodeList(d) { users = u; error = nil }
        else { error = AdminMessage.text(status: st == 200 ? 500 : st, action: "read the users") }
        loaded = true
        if ratings.isEmpty, case let (d?, 200) = await api.request(UserAdminAPI.parentalRatings) { ratings = UserAdminAPI.decodeRatings(d) }
        if folders.isEmpty, case let (d?, 200) = await api.request(UserAdminAPI.mediaFolders) { folders = UserAdminAPI.decodeFolders(d) }
    }

    func ratingName(_ v: Int?) -> String {
        guard let v else { return "No limit" }
        return ratings.first { $0.value == v }?.name ?? String(v)
    }

    /// The user's fresh record (the Policy sent back must be the server's current one).
    func fresh(_ id: String) async -> AdminUser? {
        guard case let (d?, 200) = await api.request(UserAdminAPI.user(id)),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return AdminUser.decode(o)
    }

    /// nil = done; else the sentence.
    func create(name: String, password: String) async -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "Type a name." }
        if users.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return "A user called \u{201C}\(n)\u{201D} already exists." }
        let (d, st) = await api.request(UserAdminAPI.create(name: n, password: password, kind: kind))
        if let m = AdminMessage.text(status: st, action: "create the user") { return m }
        if UserAdminAPI.createNeedsPasswordStep(kind, password: password),
           let id = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["Id"] as? String {
            let (_, ps) = await api.request(UserAdminAPI.password(userId: id, new: password))
            if let m = AdminMessage.text(status: ps, action: "set the password") { await load(); return "The user was created, but: " + m }
        }
        await load()
        return nil
    }

    /// Saves name, password and policy (only what changed). Returns (summary lines, error).
    func save(user: AdminUser, name: String, edit: UserPolicyEdit, original: UserPolicyEdit,
              newPassword: String, currentPassword: String, resetPassword: Bool) async -> (done: [String], error: String?) {
        var done: [String] = []
        if let m = UserAdminRules.validate(edit, user: user, me: me, users: users) { return ([], m) }
        guard let cur = await fresh(user.id) else { return ([], "Couldn't read the user from the server. Try again.") }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, n != cur.name {
            let (_, st) = await api.request(UserAdminAPI.rename(cur, to: n))
            if let m = AdminMessage.text(status: st, action: "rename the user") { return (done, m) }
            done.append("Name: \(n)")
        }
        if resetPassword {
            let (_, st) = await api.request(UserAdminAPI.resetPassword(userId: user.id))
            if let m = AdminMessage.text(status: st, action: "reset the password") { return (done, m) }
            done.append("Password removed")
        } else if !newPassword.isEmpty {
            let (_, st) = await api.request(UserAdminAPI.password(userId: user.id, new: newPassword,
                                                                   current: user.id == me ? currentPassword : nil))
            if let m = AdminMessage.text(status: st, action: "set the password") {
                return (done, st == 400 || st == 403 && user.id == me ? "The current password isn't right." : m)
            }
            done.append("Password changed")
        }
        let changes = edit.changes(from: original, ratingName: ratingName)
        if !changes.isEmpty {
            let (_, st) = await api.request(UserAdminAPI.policy(userId: user.id, edit.apply(to: cur.policy)))
            if let m = AdminMessage.text(status: st, action: "save the user's permissions") { return (done, m) }
            done += changes
        }
        await load()
        return (done, nil)
    }

    func delete(_ user: AdminUser) async -> String? {
        guard UserAdminRules.canDelete(user, me: me) else { return "You can't delete your own account." }
        let (_, st) = await api.request(UserAdminAPI.delete(user.id))
        if let m = AdminMessage.text(status: st, action: "delete the user") { return m }
        await load()
        return nil
    }
}

/// Libraries tab state.
@MainActor
final class ServerLibrariesModel: ObservableObject {
    @Published var libraries: [AdminLibrary] = []
    @Published var counts: [String: Int] = [:]
    @Published var loaded = false
    @Published var error: String?

    let kind: ServerAdminKind
    let api: ServerAdminAPI

    init(kind: ServerAdminKind, api: ServerAdminAPI) { self.kind = kind; self.api = api }

    func load() async {
        let (d, st) = await api.request(LibraryAdminAPI.list)
        if st == 200, let d, let l = AdminLibrary.decodeList(d) { libraries = l; error = nil }
        else { error = AdminMessage.text(status: st == 200 ? 500 : st, action: "read the libraries") }
        loaded = true
        for l in libraries where !l.itemId.isEmpty {
            if case let (cd?, 200) = await api.request(LibraryAdminAPI.count(userId: api.userId, libraryId: l.itemId, type: l.collectionType)),
               let n = LibraryAdminAPI.decodeCount(cd) { counts[l.id] = n }
        }
    }

    /// Runs one request, reloads, returns nil or the sentence.
    func run(_ r: AdminRequest, action: String, reload: Bool = true) async -> String? {
        let (_, st) = await api.request(r)
        if let m = AdminMessage.text(status: st, action: action) { return m }
        if reload { await load() }
        return nil
    }
}
