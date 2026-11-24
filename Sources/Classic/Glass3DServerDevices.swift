import SwiftUI

// MARK: - Devices tab

struct ServerDevicesTab: View {
    @StateObject private var model: ServerDevicesModel
    @AppStorage("accent") private var accentName = "red"
    @State private var query = ""
    @State private var sheet: Sheet?
    @State private var message: String?

    enum Sheet: Identifiable {
        case rename(AdminDevice), remove(AdminDevice)
        var id: String {
            switch self { case .rename(let d): return "rn" + d.id; case .remove(let d): return "rm" + d.id }
        }
    }

    init(admin: ServerAdmin, myDeviceId: String = "") {
        _model = StateObject(wrappedValue: ServerDevicesModel(kind: admin.kind, api: admin.api, myDeviceId: myDeviceId))
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
                HStack {
                    ServerSearchField(placeholder: "Search devices", text: $query)
                    if let m = message { Text(m).cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).lineLimit(2) }
                    Spacer()
                    if model.loaded {
                        Text(model.devices.count == 1 ? "1 device" : "\(model.devices.count) devices")
                            .cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                }
                if let e = model.error, model.devices.isEmpty {
                    ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
                } else if !model.loaded {
                    SkeletonShimmer(rows: 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).skeletonCrossfade()
                } else {
                    ScrollView {
                        LazyVStack(spacing: Glass3DTokens.Space.s) {
                            ForEach(model.devices.filter { AdminDevice.matches($0, query) }) { row($0) }
                        }.padding(.bottom, Glass3DTokens.Space.s)
                    }.scrollIndicators(.never)
                }
            }
            if let s = sheet {
                ServerDeviceSheet(model: model, sheet: s) { r in sheet = nil; if let r { message = r } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
    }

    func row(_ d: AdminDevice) -> some View {
        let own = d.isOwn(model.myDeviceId)
        return ServerAdminCard {
            HStack(spacing: Glass3DTokens.Space.m) {
                Image(systemName: d.icon).cvFont(18).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    HStack(spacing: Glass3DTokens.Space.s) {
                        Text(d.displayName).cvFont(14, weight: .bold).foregroundColor(.white).lineLimit(1)
                        if own { ServerBadge(text: "This Mac", color: Theme.accent(accentName)) }
                    }
                    Text([d.appName + (d.appVersion.isEmpty ? "" : " " + d.appVersion), d.lastUser.map { "Last user: " + $0 } ?? ""]
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · "))
                        .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                }
                Spacer()
                if let s = d.lastSeen {
                    Text(ServerAdminDate.relative(s)).cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary).lineLimit(1)
                }
                GlassListButton(list: {
                    var acts: [(String, () -> Void)] = [("Rename…", { sheet = .rename(d) })]
                    if !own { acts.append(("Remove (signs it out)…", { sheet = .remove(d) })) }
                    return (acts.map { $0.0 }, Set<Int>(), Set<Int>(), { i in if i >= 0 && i < acts.count { acts[i].1() } })
                }) {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: 30, height: 30).classicGlassPill()
                }
            }
        }
    }
}

struct ServerDeviceSheet: View {
    @ObservedObject var model: ServerDevicesModel
    let sheet: ServerDevicesTab.Sheet
    let done: (String?) -> Void
    @AppStorage("accent") private var accentName = "red"
    @State private var name = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        ServerSheet(width: 460, dismiss: { done(nil) }) {
            switch sheet {
            case .rename(let d):
                Text("Rename \u{201C}\(d.displayName)\u{201D}").cvFont(17, weight: .bold).foregroundColor(.white)
                ServerField(title: "Name shown on the server", text: $name)
                Text("Leave empty to use the name the device reports (\(d.name)).").cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
            case .remove(let d):
                Text("Remove \u{201C}\(d.displayName)\u{201D}?").cvFont(17, weight: .bold).foregroundColor(.white)
                Text("This signs the device out. It has to sign in again to use the server.")
                    .cvFont(13).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty { Text(error).cvFont(12).foregroundColor(Glass3DTokens.Status.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                switch sheet {
                case .rename: Button("Rename") { go() }.buttonStyle(AboutButton(primary: true, accentName: accentName)).disabled(busy)
                case .remove: Button("Remove") { go() }.buttonStyle(GlassButtonStyle(.destructive)).disabled(busy)
                }
            }
        }
        .onAppear { if case .rename(let d) = sheet { name = d.customName ?? "" } }
        .keepsWindowOpen(busy)
    }

    func go() {
        busy = true; error = ""
        Task {
            let e: String?, ok: String
            switch sheet {
            case .rename(let d): e = await model.rename(d, to: name); ok = "Renamed."
            case .remove(let d): e = await model.remove(d); ok = "Removed \u{201C}\(d.displayName)\u{201D}."
            }
            busy = false
            if let e { error = e } else { done(ok) }
        }
    }
}

/// Reads Cove's own device id from the environment (the tab's init can't).
struct ServerDevicesTabHost: View {
    let admin: ServerAdmin
    @EnvironmentObject var emby: Emby
    var body: some View { ServerDevicesTab(admin: admin, myDeviceId: emby.deviceId) }
}

// MARK: - Plugins tab

struct ServerPluginsTab: View {
    @ObservedObject var admin: ServerAdmin
    @StateObject private var model: ServerPluginsModel
    @AppStorage("accent") private var accentName = "red"
    @State private var confirm: AdminPlugin?
    @State private var message: String?
    @State private var busy: String?

    init(admin: ServerAdmin) {
        self.admin = admin
        _model = StateObject(wrappedValue: ServerPluginsModel(kind: admin.kind, api: admin.api))
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
                if model.restartNeeded { restartBanner }
                HStack {
                    if let m = message { Text(m).cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).lineLimit(2) }
                    Spacer()
                    let n = model.plugins.filter { $0.update != nil }.count
                    if n > 0 { Text(n == 1 ? "1 update available" : "\(n) updates available").cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Status.success) }
                }
                if let e = model.error, model.plugins.isEmpty {
                    ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
                } else if !model.loaded {
                    SkeletonShimmer(rows: 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).skeletonCrossfade()
                } else if model.plugins.isEmpty {
                    ServerAdminNotice(icon: "puzzlepiece.extension", text: "No plugins installed.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: Glass3DTokens.Space.s) { ForEach(model.plugins) { row($0) } }.padding(.bottom, Glass3DTokens.Space.s)
                    }.scrollIndicators(.never)
                }
            }
            if let p = confirm {
                ServerSheet(dismiss: { confirm = nil }) {
                    Text("Uninstall \u{201C}\(p.name)\u{201D}?").cvFont(17, weight: .bold).foregroundColor(.white)
                    Text("The plugin is removed from the server. A server restart finishes it.")
                        .cvFont(13).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { confirm = nil }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                        Button("Uninstall") { confirm = nil; act(p, PluginAdminAPI.uninstall(p, kind: model.kind), "uninstall the plugin", "Uninstalled \u{201C}\(p.name)\u{201D}.") }
                            .buttonStyle(GlassButtonStyle(.destructive))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
        .keepsWindowOpen(confirm != nil || busy != nil)
    }

    var restartBanner: some View {
        ServerAdminCard {
            HStack(spacing: Glass3DTokens.Space.m) {
                Image(systemName: "arrow.clockwise.circle.fill").cvFont(16).foregroundColor(Glass3DTokens.Status.warning)
                Text(restartText).cvFont(13).foregroundColor(.white)
                Spacer()
                Button("Restart server") { Task { await admin.restart() } }
                    .buttonStyle(GlassButtonStyle(.destructive)).disabled(admin.power == .restarting)
            }
        }
    }

    var restartText: String {
        switch admin.power {
        case .restarting: return "Restarting…"
        case .back: return "The server is back."
        case .timedOut: return "The server hasn't come back yet."
        default: return "Restart required to finish the plugin changes."
        }
    }

    func row(_ p: AdminPlugin) -> some View {
        ServerAdminCard {
            HStack(spacing: Glass3DTokens.Space.m) {
                Image(systemName: "puzzlepiece.extension").cvFont(18).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    HStack(spacing: Glass3DTokens.Space.s) {
                        Text(p.name).cvFont(14, weight: .bold).foregroundColor(.white).lineLimit(1)
                        if let s = p.statusTitle {
                            ServerBadge(text: s, color: p.status?.lowercased() == "active" ? Glass3DTokens.Status.success : (p.needsRestart ? Glass3DTokens.Status.warning : .gray))
                        }
                    }
                    Text(p.version.isEmpty ? "" : "Version \(p.version)").cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                }
                .help(p.description.isEmpty ? p.name : p.description)
                Spacer()
                if busy == p.id { ProgressView().controlSize(.small) }
                if let u = p.update {
                    Button { act(p, nil, "", "") } label: { Label("Update to \(u)", systemImage: "arrow.down.circle") }
                        .buttonStyle(AboutButton(primary: true, accentName: accentName)).disabled(busy != nil)
                }
                let acts = actions(p)
                if !acts.isEmpty {
                    GlassListButton(list: {
                        (acts.map { $0.0 }, Set<Int>(), Set<Int>(), { i in if i >= 0 && i < acts.count { acts[i].1() } })
                    }) {
                        Label("More", systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: 30, height: 30).classicGlassPill()
                    }
                }
            }
        }
    }

    func actions(_ p: AdminPlugin) -> [(String, () -> Void)] {
        var a: [(String, () -> Void)] = []
        if PluginAdminAPI.canToggle(model.kind), p.status != nil {
            if p.isDisabled { a.append(("Enable", { act(p, PluginAdminAPI.enable(p, true), "enable the plugin", "Enabled \u{201C}\(p.name)\u{201D}.") })) }
            else { a.append(("Disable", { act(p, PluginAdminAPI.enable(p, false), "disable the plugin", "Disabled \u{201C}\(p.name)\u{201D}.") })) }
        }
        if p.canUninstall { a.append(("Uninstall…", { confirm = p })) }
        return a
    }

    /// r == nil: install the update.
    func act(_ p: AdminPlugin, _ r: AdminRequest?, _ action: String, _ ok: String) {
        busy = p.id
        Task {
            let e: String?
            if let r { e = await model.run(r, action: action, restart: true) } else { e = await model.update(p) }
            busy = nil
            message = e ?? (r == nil ? "Installing the update for \u{201C}\(p.name)\u{201D}." : ok)
        }
    }
}
