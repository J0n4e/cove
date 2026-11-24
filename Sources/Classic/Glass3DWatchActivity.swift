import SwiftUI

// Detail page → Watch activity (admins only): a compact glass pill ("👁 3/10 watched" only; no avatars, owner: it must stay small with many users) in the
// info line; hovering it (or a click) opens a glass list of every user with their state, last played date, play
// count and ♥. Model and rules: Shared/WatchActivity.swift.

struct WatchActivityPill: View {
    let item: Item
    @EnvironmentObject var emby: Emby
    @ObservedObject private var store = WatchActivityStore.shared
    @ObservedObject private var profile = ProfileModel.shared
    @State private var open = false
    @State private var hoverPill = false
    @State private var hoverList = false

    private var folder: Bool { WatchActivity.isFolder(item.`Type`) }

    var body: some View {
        if profile.admin == true {
            let d = store.data[store.key(emby, item.id)]
            Group {
                if let d, !d.entries.isEmpty { pill(d) }
                else { Color.clear.frame(width: 0, height: 0) }
            }
            .task(id: item.id) { await store.load(emby, itemId: item.id) }
        }
    }

    private func pill(_ d: WatchActivityData) -> some View {
        let s = WatchActivity.summary(d.entries, folder: folder)
        return Button { open.toggle() } label: {
            HStack(spacing: Glass3DTokens.Space.s) {
                Image(systemName: "eye").cvFont(11, weight: .semibold)
                Text(s.text).cvFont(11, weight: .semibold) { $0.monospacedDigit() }
            }
            .foregroundColor(.white)
            .padding(.horizontal, Glass3DTokens.Space.m).frame(height: 26)
            .classicGlassPill(iconOnly: false)
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
        .accessibilityLabel("Watch activity: \(s.text)")
        .onHover { h in hoverPill = h; hoverChanged() }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WatchActivityList(item: item, data: d, folder: folder)
                .onHover { h in hoverList = h; hoverChanged() }
        }
    }

    /// Opens on hover (after a short pause), closes a moment after the pointer left both the pill and the list.
    private func hoverChanged() {
        let inside = hoverPill || hoverList
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(inside ? 350 : 400))
            let now = hoverPill || hoverList
            if now == inside { open = inside }
        }
    }
}

struct WatchActivityAvatar: View {
    let user: WatchActivityUser
    var size: CGFloat = 22
    @EnvironmentObject var emby: Emby
    var body: some View {
        let color = StatsUsersStyle.avatars[StatsUsersAggregate.colorIndex(user.name, count: StatsUsersStyle.avatars.count)]
        ZStack {
            Circle().fill(color.opacity(0.75))
            Text(AdminUser.initials(user.name)).cvFont(size * 0.4, weight: .bold).foregroundColor(.white)
            if let tag = user.imageTag,
               let u = URL(string: "\(emby.server)/Users/\(user.id)/Images/Primary?tag=\(tag)&maxHeight=\(Int(size * 3))&quality=90") {
                CachedImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 1))
    }
}

struct WatchActivityList: View {
    let item: Item
    let data: WatchActivityData
    let folder: Bool
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        let s = WatchActivity.summary(data.entries, folder: folder)
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            HStack {
                Text("Watch activity").cvFont(14, weight: .bold).foregroundColor(.white)
                Spacer()
                Text(s.text).cvFont(12, weight: .semibold) { $0.monospacedDigit() }.foregroundColor(Glass3DTokens.Grey.secondary)
            }
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                if let a = data.dateAdded {
                    Text("Date added: " + a.formatted(date: .abbreviated, time: .shortened))
                }
                if let l = s.lastPlayed {
                    Text("Last played " + LastActive.ago(l) + (s.lastPlayedBy.map { " by " + $0 } ?? ""))
                        .tip(LastActive.exact(l))
                }
                if let f = s.favouritesText { Text(f) }
            }
            .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                    ForEach(WatchActivity.sorted(data.entries, folder: folder)) { e in row(e) }
                }
            }
            .frame(maxHeight: 360)
            .scrollIndicators(.never)
        }
        .padding(Glass3DTokens.Space.l).frame(width: 400, alignment: .leading)
        .preferredColorScheme(.dark)
    }

    private func row(_ e: WatchActivityEntry) -> some View {
        let st = WatchActivity.state(e, folder: folder)
        return HStack(spacing: Glass3DTokens.Space.m) {
            WatchActivityAvatar(user: e.user, size: 24)
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                HStack(spacing: Glass3DTokens.Space.s) {
                    Text(e.user.name).cvFont(12, weight: .semibold).foregroundColor(.white).lineLimit(1)
                    if e.user.disabled { Text("Disabled").cvFont(9, weight: .bold).foregroundColor(Glass3DTokens.Grey.tertiary) }
                    if e.favorite { Image(systemName: "heart.fill").cvFont(10).foregroundColor(Theme.accent(accentName)).tip("Favourite") }
                }
                stateView(st)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: Glass3DTokens.Space.xs) {
                if let l = e.lastPlayed {
                    Text(LastActive.ago(l)).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                        .tip("Last played " + LastActive.exact(l))
                } else {
                    Text("—").cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary)
                }
                if e.playCount > 0 {
                    Text(e.playCount == 1 ? "1 play" : "\(e.playCount) plays").cvFont(10).foregroundColor(Glass3DTokens.Grey.tertiary)
                }
            }
        }
        .opacity(e.user.disabled ? 0.45 : 1)
    }

    @ViewBuilder private func stateView(_ st: WatchActivityState) -> some View {
        switch st {
        case .watched:
            Label("Watched", systemImage: "checkmark").cvFont(11, weight: .semibold).foregroundColor(Glass3DTokens.Status.success)
        case .notStarted:
            Text("Not started").cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary)
        case .progress(let f, _):
            HStack(spacing: Glass3DTokens.Space.s) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Theme.accent(accentName)).frame(width: max(3, g.size.width * f))
                    }
                }
                .frame(width: 70, height: 4)
                Text(WatchActivity.stateText(st)).cvFont(11) { $0.monospacedDigit() }.foregroundColor(Glass3DTokens.Grey.primary)
            }
        }
    }
}
