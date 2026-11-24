import SwiftUI

// v1.18.8: Now Playing shows the sessions of one Jellyfin SyncPlay group as ONE card (Glass3D theme).
// Matching: GET /SyncPlay/List gives GroupInfoDto {GroupId, GroupName, State, Participants (user names),
// LastUpdatedAt} (MediaBrowser.Model/SyncPlay/GroupInfoDto.cs) and no playing item, so a session belongs to a
// group when its user name is one of the group's Participants AND it plays the group's current item: from the
// group's own PlayQueue updates when this Mac is in that group, else the one item that two or more of those
// participants' sessions play. Anything ambiguous stays as separate cards.

/// One card on the page: a session, or a SyncPlay group's sessions.
enum NowPlayingEntry: Identifiable {
    case single(ActiveSession)
    case group(id: String, name: String, members: [ActiveSession])

    var id: String {
        switch self {
        case .single(let s): return s.Id
        case .group(let id, _, _): return "group-" + id
        }
    }
    /// The sessions on the card (for the "n active" count)
    var sessions: [ActiveSession] {
        switch self {
        case .single(let s): return [s]
        case .group(_, _, let m): return m
        }
    }
}

enum NowPlayingGroups {
    /// /SyncPlay/List at most this often while the page is shown
    static let listInterval: TimeInterval = 10

    /// Groups the playing sessions into cards, in the sessions' order (a group card sits where its first member
    /// was). `own` = the group this Mac is in and the item it's on (from its PlayQueue updates).
    static func entries(_ sessions: [ActiveSession], groups: [SyncPlayGroupInfo],
                        own: (groupId: String, itemId: String?)? = nil) -> [NowPlayingEntry] {
        var taken: [String: Int] = [:]   // session id → index into `found`
        var found: [(id: String, name: String, members: [ActiveSession])] = []
        for g in groups {
            let names = Set((g.Participants ?? []).map { $0.lowercased() })
            guard names.count >= 1 else { continue }
            let candidates = sessions.filter {
                taken[$0.Id] == nil && $0.NowPlayingItem != nil && names.contains(($0.UserName ?? "").lowercased())
            }
            let item: String?
            if let own, own.groupId == g.GroupId, let id = own.itemId {
                item = id
            } else {
                // The one item two or more of them play; none or several → no reliable match
                let counts = Dictionary(grouping: candidates, by: { $0.NowPlayingItem!.Id }).filter { $0.value.count >= 2 }
                item = counts.count == 1 ? counts.first!.key : nil
            }
            guard let item else { continue }
            let members = candidates.filter { $0.NowPlayingItem?.Id == item }
            guard members.count >= 2 else { continue }
            for m in members { taken[m.Id] = found.count }
            found.append((g.GroupId, g.GroupName, members))
        }
        var out: [NowPlayingEntry] = []
        var placed = Set<Int>()
        for s in sessions {
            if let i = taken[s.Id] {
                if placed.insert(i).inserted { out.append(.group(id: found[i].id, name: found[i].name, members: found[i].members)) }
            } else {
                out.append(.single(s))
            }
        }
        return out
    }
}

/// Keeps the server's SyncPlay groups fresh while Now Playing is shown (Jellyfin with SyncPlay access only;
/// errors just leave the cards separate).
struct NowPlayingGroupFeed: ViewModifier {
    @EnvironmentObject var emby: Emby
    @Binding var groups: [SyncPlayGroupInfo]

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                let sp = emby.syncPlay
                if emby.isJellyfin, sp.syncPlayAvailable, let d = await sp.send("/SyncPlay/List", body: nil, post: false),
                   let g = try? JSONDecoder().decode([SyncPlayGroupInfo].self, from: d) {
                    groups = g
                } else {
                    groups = []
                }
                try? await Task.sleep(for: .seconds(NowPlayingGroups.listInterval))
            }
        }
    }
}

extension View {
    func nowPlayingGroups(_ groups: Binding<[SyncPlayGroupInfo]>) -> some View { modifier(NowPlayingGroupFeed(groups: groups)) }
}

/// A Now Playing card: one session, or a SyncPlay group's members.
struct Glass3DNowPlayingCard: View {
    let entry: NowPlayingEntry
    let fetchedAt: Date
    var body: some View {
        switch entry {
        case .single(let s): Glass3DSessionCard(s: s, fetchedAt: fetchedAt)
        case .group(_, let name, let m): Glass3DGroupCard(name: name, members: m, fetchedAt: fetchedAt)
        }
    }
}

/// One SyncPlay group: the item as on a session card, the progress of its first member, and a chip per member.
struct Glass3DGroupCard: View {
    @EnvironmentObject var emby: Emby
    let name: String
    let members: [ActiveSession]
    let fetchedAt: Date
    @State private var hover = false

    var body: some View {
        let s = members[0], it = s.NowPlayingItem!
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            HStack(alignment: .top, spacing: Glass3DTokens.Space.l) {
                CachedImage(url: emby.image(it.SeriesId ?? it.Id, width: 200)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 84, height: 126)
                .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous)
                    .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
                .g3Shadow(Glass3DTokens.shadowMedium)
                VStack(alignment: .leading, spacing: Glass3DTokens.Space.xs) {
                    Text(it.SeriesName ?? it.Name).cvFont(Glass3DTokens.Text.cardTitle, weight: .bold).lineLimit(1)
                    if it.SeriesName != nil {
                        Text("S\(it.ParentIndexNumber ?? 0):E\(it.IndexNumber ?? 0) - \(it.Name)")
                            .cvFont(13, weight: .medium).foregroundColor(Glass3DTokens.Grey.primary).lineLimit(1)
                    }
                    HStack(spacing: Glass3DTokens.Space.s) {
                        Image(systemName: "person.2.fill").cvFont(11, weight: .semibold)
                        Text("Watching together · \(name)").lineLimit(1)
                    }
                    .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.primary)
                    .padding(.top, 2)
                    FlowChips(members: members)
                }
                Spacer(minLength: 0)
            }
            GroupProgress(s: s, fetchedAt: fetchedAt)
        }
        .padding(Glass3DTokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { GroupBackdrop(url: emby.image(it.SeriesId ?? it.Id, "Backdrop", width: 780)) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(hover ? Glass3DTokens.Stroke.strong : Glass3DTokens.Stroke.subtle), lineWidth: 1))
        .g3Shadow(Glass3DTokens.shadowLarge)
        .contentShape(shape)
        .onTapGesture { Task { if let item = await emby.itemRecord(it.Id) { emby.openPage(item) } } }
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .accessibilityLabel("\(it.SeriesName ?? it.Name), watched together by \(members.count)")
    }
}

/// The members, wrapped two per line
private struct FlowChips: View {
    let members: [ActiveSession]
    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
            ForEach(Array(stride(from: 0, to: members.count, by: 2)), id: \.self) { i in
                HStack(spacing: Glass3DTokens.Space.s) {
                    ForEach(members[i..<min(i + 2, members.count)], id: \.Id) { MemberChip(s: $0) }
                }
            }
        }
        .padding(.top, Glass3DTokens.Space.xs)
    }
}

/// "jonae · 💻 · Direct play"; the IP only while the pointer is on the chip
private struct MemberChip: View {
    let s: ActiveSession
    @State private var hover = false
    var body: some View {
        let method = NowPlayingStyle.playMethod(s.PlayState?.PlayMethod)
        HStack(spacing: Glass3DTokens.Space.xs) {
            Text(s.UserName ?? "Unknown").cvFont(11, weight: .semibold)
            Image(systemName: NowPlayingStyle.clientIcon(client: s.Client, device: s.DeviceName)).cvFont(10, weight: .semibold)
                .help(s.DeviceName ?? s.Client ?? "")
            Text(method.label).cvFont(10, weight: .semibold)
                .padding(.horizontal, Glass3DTokens.Space.s).padding(.vertical, 2)
                .background(Capsule().fill(NowPlayingStyle.color(method.tint).opacity(0.25)))
            if hover, let ip = s.RemoteEndPoint {
                Text(ip).cvFont(10).foregroundColor(Glass3DTokens.Grey.tertiary).transition(.opacity)
            }
        }
        .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.xs)
        .background(Capsule().fill(Color.white.opacity(Glass3DTokens.Fill.subtle)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.5))
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
    }
}

private struct GroupBackdrop: View {
    let url: URL?
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            CachedImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill).blur(radius: 20, opaque: true)
            } placeholder: { Color.clear }
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// The same time line and red bar as a session card, from the group's first member
private struct GroupProgress: View {
    let s: ActiveSession
    let fetchedAt: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let paused = s.PlayState?.IsPaused == true
            let dur = Double(s.NowPlayingItem?.RunTimeTicks ?? 0) / 10_000_000
            let pos = NowPlayingStyle.livePosition(reported: Double(s.PlayState?.PositionTicks ?? 0) / 10_000_000,
                                                   duration: dur, paused: paused,
                                                   elapsed: ctx.date.timeIntervalSince(fetchedAt))
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                HStack(spacing: Glass3DTokens.Space.s) {
                    Image(systemName: paused ? "pause.fill" : "play.fill").cvFont(10, weight: .bold)
                    Text("\(timeString(pos)) / \(timeString(dur))").monospacedDigit()
                    if let left = NowPlayingStyle.timeLeft(position: pos, duration: dur) { Text("· \(left)").monospacedDigit() }
                }
                .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                ClassicSessionLine(watched: dur > 0 ? min(1, pos / dur) : 0,
                                   converted: (s.TranscodingInfo?.CompletionPercentage).map { min(1, $0 / 100) })
            }
        }
    }
}
