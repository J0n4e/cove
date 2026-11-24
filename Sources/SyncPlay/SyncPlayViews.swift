import SwiftUI

// SyncPlay phase 2: the pieces both themes share: the "Watch together" pill on a detail page with its group
// list, the player's SyncPlay button wrapper and the "ldoctoru joined" toast. The player panels themselves are
// in Classic/ClassicSyncPlayPanel.swift.

extension SyncPlayGroup {
    /// The panel's state line.
    nonisolated static func stateText(_ state: String) -> String {
        switch state {
        case "Waiting": return "Waiting for others…"
        case "Paused": return "Paused"
        case "Playing": return "Playing"
        default: return "Nothing playing yet"
        }
    }

    /// The persistent pill at the top of the player while the group waits (nil = no pill). Jellyfin's
    /// GroupStateUpdate {State, Reason} doesn't say who is buffering, so other members get the generic text
    /// unless a name is known; the Mac that stalled itself says so.
    nonisolated static func waitingText(state: String?, selfStalled: Bool, waitingFor name: String? = nil) -> String? {
        guard state == "Waiting" else { return nil }
        if selfStalled { return "Buffering… the group is waiting for you" }
        if let n = name, !n.isEmpty { return "Waiting for \(n)…" }
        return "Waiting for others…"
    }

    nonisolated static func watchingText(_ n: Int) -> String { n == 1 ? "1 watching" : "\(n) watching" }

    nonisolated static func defaultName(user: String?) -> String {
        guard let u = user, !u.isEmpty else { return "Watch together" }
        return "\(u)'s group"
    }
}

extension View {
    /// The theme's font (Glass3D: the Classic font; Glass: the system font), following the text size.
    func spFont(_ classic: Bool, _ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        coveFont { f in
            let s = TextScale.scaledSize(base: size, scale: f)
            return classic ? Font.cv(s, weight: weight) : Font.system(size: s, weight: weight)
        }
    }
}

/// A secondary pill in the theme's look: Glass3D's glass pill, else the Glass theme's material capsule.
struct SyncPlayPill: ViewModifier {
    let classic: Bool
    var height: CGFloat = 34
    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            content.padding(.horizontal, Glass3DTokens.Space.l).frame(minHeight: height).classicGlassPill()
        } else {
            content.padding(.horizontal, Glass3DTokens.Space.l).frame(height: height).background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// "Watch together" next to the Play buttons of a film or episode (Jellyfin with SyncPlay only).
struct WatchTogetherButton: View {
    @EnvironmentObject var emby: Emby
    let item: Item?
    /// Resume position in seconds (the group starts there)
    let start: Double
    let classic: Bool
    var body: some View {
        WatchTogetherInner(service: emby.syncPlay, item: item, start: start, classic: classic, isJellyfin: emby.isJellyfin)
    }
}

private struct WatchTogetherInner: View {
    @ObservedObject var service: SyncPlayService
    let item: Item?
    let start: Double
    let classic: Bool
    let isJellyfin: Bool
    @State private var open = false

    var body: some View {
        if isJellyfin, service.syncPlayAvailable, let item, item.playable {
            Button { open.toggle() } label: { label }
                .buttonStyle(HoverButton())
                .helpLabel("Watch together")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    SyncPlayGroupPicker(group: service.group, service: service, item: item, start: start,
                                        classic: classic) { open = false }
                }
        }
    }

    @ViewBuilder var label: some View {
        if classic {
            Label("Watch together", systemImage: "person.2.fill").classicGlassPill(size: 44, iconOnly: false)
        } else {
            Label("Watch together", systemImage: "person.2.fill").coveFont(size: 17, weight: .semibold)
                .padding(.horizontal, Glass3DTokens.Space.xxl).frame(height: 46)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// The popover: the server's groups (Join) and New group with this item.
struct SyncPlayGroupPicker: View {
    @ObservedObject var group: SyncPlayGroup
    @ObservedObject var service: SyncPlayService
    let item: Item?
    let start: Double
    let classic: Bool
    let done: () -> Void

    var canCreate: Bool { service.syncPlayAccess == "CreateAndJoinGroups" }

    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            Text("Watch together").spFont(classic, 16, weight: .bold)
            if let i = group.info {
                groupRow(i.name, SyncPlayGroup.watchingText(i.participants.count), current: true) {
                    Button { Task { await group.leave() }; done() } label: {
                        Text("Leave").spFont(classic, 13, weight: .semibold).modifier(SyncPlayPill(classic: classic, height: 28))
                    }.buttonStyle(HoverButton())
                }
            } else if group.state == .joining {
                HStack(spacing: Glass3DTokens.Space.s) { ProgressView().controlSize(.small); Text("Joining…").spFont(classic, 13).foregroundColor(.secondary) }
            } else {
                if group.groups.isEmpty {
                    Text(group.loadingList ? "Looking for groups…" : "No groups on the server yet")
                        .spFont(classic, 13).foregroundColor(.secondary)
                }
                ForEach(group.groups) { g in
                    groupRow(g.GroupName, SyncPlayGroup.watchingText(g.Participants?.count ?? 0), current: false) {
                        Button { Task { await group.join(g.GroupId) }; done() } label: {
                            Text("Join").spFont(classic, 13, weight: .semibold).modifier(SyncPlayPill(classic: classic, height: 28))
                        }.buttonStyle(HoverButton())
                    }
                }
                if canCreate {
                    Divider().padding(.vertical, 2)
                    Button {
                        let name = SyncPlayGroup.defaultName(user: service.userName)
                        let ticks = Int64(max(0, start) * SyncPlayGroup.ticksPerSecond)
                        Task { await group.create(name: name, itemId: item?.Id, startTicks: ticks) }
                        done()
                    } label: {
                        Label("New group", systemImage: "plus").spFont(classic, 13, weight: .semibold)
                            .modifier(SyncPlayPill(classic: classic))
                    }.buttonStyle(HoverButton()).helpLabel("Start a group with this video")
                }
            }
        }
        .padding(Glass3DTokens.Space.l)
        .frame(width: 300, alignment: .leading)
        .environment(\.colorScheme, .dark)
        .task { await group.refreshList() }
    }

    func groupRow<B: View>(_ name: String, _ sub: String, current: Bool, @ViewBuilder _ button: () -> B) -> some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            Image(systemName: "person.2.fill").spFont(classic, 13).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).spFont(classic, 13, weight: .medium).lineLimit(1)
                Text(current ? "You're in this group · " + sub : sub).spFont(classic, 11).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            button()
        }
    }
}

/// The player's SyncPlay button: only while in a group.
struct SyncPlayPlayerButton<B: View>: View {
    @ObservedObject var group: SyncPlayGroup
    let button: () -> B
    init(group: SyncPlayGroup, @ViewBuilder button: @escaping () -> B) {
        self.group = group
        self.button = button
    }
    var body: some View {
        if group.isActive { button() }
    }
}

/// "ldoctoru joined" at the top of the player for a few seconds.
struct SyncPlayToast: View {
    @ObservedObject var group: SyncPlayGroup
    var classic = true
    var body: some View {
        VStack(spacing: Glass3DTokens.Space.s) {
            if let w = Self.waiting(group) {
                HStack(spacing: Glass3DTokens.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(w).spFont(classic, 14, weight: .semibold)
                }
                .toastStyle(height: Glass3DTokens.Toast.compactHeight)
                .transition(.toast(from: .top))
            }
            if let t = group.toast {
                Label(t, systemImage: "person.2.fill").spFont(classic, 14, weight: .semibold)
                    .toastStyle(height: Glass3DTokens.Toast.compactHeight)
                    .transition(.toast(from: .top))
            }
            Spacer()
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(Glass3DTokens.Toast.animation, value: group.toast)
        .animation(Glass3DTokens.Toast.animation, value: Self.waiting(group))
    }

    static func waiting(_ g: SyncPlayGroup) -> String? {
        SyncPlayGroup.waitingText(state: g.info?.state, selfStalled: g.selfStalled && !g.ignoreWait)
    }
}

/// Phase 3: the panels' "Don't wait for others" switch (off by default, for this session only, as in jellyfin-web).
struct SyncPlayIgnoreWaitRow: View {
    @ObservedObject var group: SyncPlayGroup
    let classic: Bool
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        HStack(spacing: Glass3DTokens.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Don't wait for others").spFont(classic, 13, weight: .medium)
                Text("Keep the group playing while this Mac buffers").spFont(classic, 11).foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { group.ignoreWait },
                                     set: { on in Task { await group.setIgnoreWait(on) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .tint(Theme.accent(accentName))
        }
        .padding(.horizontal, Glass3DTokens.Space.xl).padding(.vertical, Glass3DTokens.Space.s)
        .helpLabel("When this Mac's stream stalls, the others keep playing and it catches up afterwards")
    }
}
