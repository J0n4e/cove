import SwiftUI

// Glass3D Now Playing (v1.18.4): a bigger glass card per session over the item's blurred backdrop, the client
// icon, time left and ▶/⏸, the play method as a tinted glass pill, the IP only on hover, live progress and a
// click that opens the item. The progress line is the existing ClassicSessionLine, unchanged (owner: it matches
// the player's timeline). The Glass theme keeps NowPlayingView (Sources/Glass/GlassNowPlaying.swift).

/// Pure text / symbol rules for the page (tested).
enum NowPlayingStyle {
    /// "1 active", "3 active".
    static func activeText(_ n: Int) -> String { "\(n) active" }

    /// An SF Symbol for the kind of client: globe = web, ipad / iphone, tv = TV apps, macbook = desktop,
    /// play.rectangle = anything else.
    static func clientIcon(client: String?, device: String?) -> String {
        let c = (client ?? "").lowercased(), d = (device ?? "").lowercased(), all = c + " " + d
        func has(_ words: [String], _ s: String = all) -> Bool { words.contains { s.contains($0) } }
        if has(["web", "browser", "chrome", "firefox", "safari", "edge"], c) { return "globe" }
        if has(["tv", "roku", "kodi", "fire stick", "firestick", "shield", "tizen", "webos", "xbox", "playstation"]) { return "tv" }
        if has(["ipad", "tablet"]) { return "ipad" }
        if has(["iphone", "ios", "android", "phone", "mobile"]) { return "iphone" }
        if has(["cove", "mac", "windows", "linux", "desktop", "theater", "media player", "mpv", "infuse", "laptop"]) { return "macbook" }
        if has(["browser", "chrome", "firefox", "safari"], d) { return "globe" }
        return "play.rectangle"
    }

    /// "4:42 left" (nil without a known length).
    static func timeLeft(position: Double, duration: Double) -> String? {
        guard duration > 0 else { return nil }
        return "\(timeString(max(0, duration - position))) left"
    }

    enum Tint: Equatable { case green, blue, orange }
    /// The play method pill: label and tint (PlayState.PlayMethod: DirectPlay / DirectStream / Transcode).
    static func playMethod(_ method: String?) -> (label: String, tint: Tint) {
        switch method?.lowercased() {
        case "transcode": return ("Transcoding", .orange)
        case "directstream": return ("Direct stream", .blue)
        default: return ("Direct play", .green)
        }
    }
    static func color(_ t: Tint) -> Color {
        switch t { case .green: return .green; case .blue: return .blue; case .orange: return .orange }
    }

    /// "catalin · Samsung Browser Android".
    static func whoLine(user: String?, device: String?) -> String {
        [user, device].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// Where playback is now: the reported position plus the time since it was fetched while playing (smooth
    /// progress between refreshes), never past the end.
    static func livePosition(reported: Double, duration: Double, paused: Bool, elapsed: Double) -> Double {
        let p = reported + (paused ? 0 : max(0, elapsed))
        return duration > 0 ? min(p, duration) : p
    }
}

/// v1.19.0: where Now Playing gets its sessions. Jellyfin with the live connection on and the socket up: the
/// server pushes them (SessionsStart "0,1500" = first at once, then at most every 1.5 s, as jellyfin-web's
/// dashboard). Anything else (Emby, live connection off, socket down): GET /Sessions every 5 s.
enum NowPlayingLive {
    enum Source: Equatable { case socket, polling }
    static let startText = #"{"MessageType":"SessionsStart","Data":"0,1500"}"#
    static let stopText = #"{"MessageType":"SessionsStop"}"#
    static let pollInterval: TimeInterval = 5
    /// Socket updates count as live for this long; after that the page polls again.
    static let socketStale: TimeInterval = 10

    static func source(isJellyfin: Bool, liveSetting: Bool, socketConnected: Bool) -> Source {
        isJellyfin && liveSetting && socketConnected ? .socket : .polling
    }
    /// Whether this 5 s tick fetches /Sessions: always when polling; on the socket only until the first push
    /// arrives and whenever pushes have stopped for `socketStale`.
    static func shouldPoll(_ source: Source, lastPush: Date?, now: Date) -> Bool {
        guard source == .socket, let lastPush else { return true }
        return now.timeIntervalSince(lastPush) > socketStale
    }
}

struct ClassicNowPlayingView: View {
    @EnvironmentObject var emby: Emby
    @Environment(\.appBG) var bg
    @State private var sessions: [ActiveSession] = []
    @State private var fetchedAt = Date()
    @State private var loaded = false
    @State private var lastPush: Date?
    @State private var syncGroups: [SyncPlayGroupInfo] = []   // v1.18.8: one card per SyncPlay group
    @State private var tab = 0                                // 0 Now Playing (default), 1 Overview, 2 History, 3 Users, 4 Graphs, 5 Libraries
    @StateObject private var stats = StatsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // v1.18.11: Now Playing · Overview · History, the library header's glass tabs (Stats inside Now Playing)
                ZStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            ClassicPageTitle(text: ActivitySection.title, icon: ActivitySection.icon)
                            if tab == 0 && !sessions.isEmpty {
                                Text(NowPlayingStyle.activeText(sessions.count))
                                    .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                            }
                        }
                        Spacer()
                    }
                    Glass3DSegmentTabs(titles: ["Now Playing", "Overview", "History"] + (stats.availability == .available ? ["Users", "Graphs", "Libraries"] : []),
                                       selection: $tab)
                }
                if tab == 1 { StatsOverviewView(model: stats) }
                else if tab == 2 { StatsHistoryView(model: stats) }
                else if tab == 3 && stats.availability == .available { StatsUsersView(model: stats) }
                else if tab == 4 && stats.availability == .available { StatsGraphsView(model: stats) }
                else if tab == 5 && stats.availability == .available { StatsLibrariesView(model: stats) }
                else { sessionsContent }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .background(bg)
        .task(id: emby.server + "|" + emby.userId) { await stats.start(emby) }   // the Users tab shows only for admins with the plugin
        .task {
            // Fallback: every 5 s while the page is shown (the task ends with the page); skipped while the
            // Jellyfin socket is pushing the sessions
            while !Task.isCancelled {
                if NowPlayingLive.shouldPoll(source, lastPush: lastPush, now: Date()) {
                    let s = await emby.nowPlaying()
                    withAnimation(Glass3DTokens.Motion.slow) { sessions = s; fetchedAt = Date() }
                    loaded = true
                }
                try? await Task.sleep(for: .seconds(NowPlayingLive.pollInterval))
            }
        }
        .modifier(NowPlayingSocketFeed(sessions: $sessions, fetchedAt: $fetchedAt, loaded: $loaded, lastPush: $lastPush))
        .nowPlayingGroups($syncGroups)
    }

    @ViewBuilder private var sessionsContent: some View {
        if !loaded { Spinner().frame(maxWidth: .infinity).padding(60) }
        else if sessions.isEmpty {
            ClassicEmptyState(symbol: "play.slash", title: "Nothing playing right now",
                              message: "Playback on any device signed in to this server shows here.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 520, maximum: 600), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(entries) { Glass3DNowPlayingCard(entry: $0, fetchedAt: fetchedAt) }
            }
        }
    }

    private var entries: [NowPlayingEntry] {
        let g = emby.syncPlay.group
        return NowPlayingGroups.entries(sessions, groups: syncGroups, own: g.info.map { (groupId: $0.id, itemId: g.playingItemId) })
    }

    private var source: NowPlayingLive.Source {
        NowPlayingLive.source(isJellyfin: emby.isJellyfin, liveSetting: SyncPlayService.liveSocketDefault(),
                              socketConnected: emby.syncPlay.connected)
    }
}

/// v1.19.0: subscribes to Jellyfin's Sessions messages while the page is shown (again after a reconnect) and
/// feeds them into the page; unsubscribes when it goes away.
private struct NowPlayingSocketFeed: ViewModifier {
    @EnvironmentObject var emby: Emby
    @Binding var sessions: [ActiveSession]
    @Binding var fetchedAt: Date
    @Binding var loaded: Bool
    @Binding var lastPush: Date?

    func body(content: Content) -> some View {
        content
            .onReceive(emby.syncPlay.sessions) { all in
                guard live else { return }
                withAnimation(Glass3DTokens.Motion.slow) { sessions = Emby.playingSessions(all); fetchedAt = Date() }
                loaded = true
                lastPush = Date()
            }
            .onReceive(emby.syncPlay.$connected.removeDuplicates()) { up in
                if up { subscribe() } else { lastPush = nil }   // down: the 5 s polling takes over
            }
            .onDisappear {
                let sp = emby.syncPlay
                Task { await sp.sendSocketText(NowPlayingLive.stopText) }
            }
    }

    private var live: Bool {
        NowPlayingLive.source(isJellyfin: emby.isJellyfin, liveSetting: SyncPlayService.liveSocketDefault(),
                              socketConnected: emby.syncPlay.connected) == .socket
    }
    private func subscribe() {
        guard live else { return }
        let sp = emby.syncPlay
        Task { await sp.sendSocketText(NowPlayingLive.startText) }
    }
}

/// One session: a glass card over the item's blurred, darkened backdrop. Click = the item's page.
struct Glass3DSessionCard: View {
    @EnvironmentObject var emby: Emby
    let s: ActiveSession
    let fetchedAt: Date
    @State private var hover = false

    var body: some View {
        let it = s.NowPlayingItem!
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
        Button { open(it.Id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    CachedImage(url: emby.image(it.SeriesId ?? it.Id, width: 200)) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 84, height: 126)
                    .clipShape(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous)
                        .strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.75))
                    .g3Shadow(Glass3DTokens.shadowMedium)
                    SessionInfo(s: s, it: it, hover: hover)
                    Spacer(minLength: 0)
                }
                SessionProgress(s: s, it: it, fetchedAt: fetchedAt)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { SessionBackdrop(url: emby.image(it.SeriesId ?? it.Id, "Backdrop", width: 780)) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hover ? Glass3DTokens.Stroke.strong : Glass3DTokens.Stroke.subtle), lineWidth: 1))
            .g3Shadow(Glass3DTokens.shadowLarge)
            .contentShape(shape)
        }
        .buttonStyle(.plainHand)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        .accessibilityLabel("Open \(it.SeriesName ?? it.Name)")
    }

    private func open(_ id: String) {
        Task { if let item = await emby.itemRecord(id) { emby.openPage(item) } }
    }
}

/// The blurred, darkened backdrop behind a session card.
private struct SessionBackdrop: View {
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

/// Title, episode, who / where, the client and the play method pill (+ the IP on hover).
private struct SessionInfo: View {
    let s: ActiveSession
    let it: ActiveSession.NowItem
    let hover: Bool
    var body: some View {
        let method = NowPlayingStyle.playMethod(s.PlayState?.PlayMethod)
        VStack(alignment: .leading, spacing: 5) {
            Text(it.SeriesName ?? it.Name).cvFont(Glass3DTokens.Text.cardTitle, weight: .bold).lineLimit(1)
            if it.SeriesName != nil {
                Text("S\(it.ParentIndexNumber ?? 0):E\(it.IndexNumber ?? 0) - \(it.Name)")
                    .cvFont(13, weight: .medium).foregroundColor(Glass3DTokens.Grey.primary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: NowPlayingStyle.clientIcon(client: s.Client, device: s.DeviceName))
                    .cvFont(12, weight: .semibold).frame(width: 18)
                Text(NowPlayingStyle.whoLine(user: s.UserName, device: s.DeviceName)).lineLimit(1)
            }
            .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.primary)
            .padding(.top, 2)
            Text("\(s.Client ?? "Unknown") \(s.ApplicationVersion ?? "")")
                .cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
            HStack(spacing: 8) {
                PlayMethodPill(label: method.label, tint: NowPlayingStyle.color(method.tint),
                               reason: s.TranscodingInfo?.TranscodeReasons?.joined(separator: ", "))
                // Private: the address only while the pointer is on the card
                if hover, let ip = s.RemoteEndPoint {
                    Text(ip).cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary).transition(.opacity)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// "Direct play" / "Direct stream" / "Transcoding" on a subtly tinted glass pill; the reason in the tooltip.
private struct PlayMethodPill: View {
    let label: String
    let tint: Color
    let reason: String?
    var body: some View {
        Text(label).cvFont(10, weight: .semibold)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.25)))
            .background(Capsule().fill(Color.white.opacity(Glass3DTokens.Fill.subtle)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.strong), lineWidth: 0.5))
            .tip(reason.map { $0.isEmpty ? label : "\(label): \($0)" } ?? label)
    }
}

/// ▶/⏸, "36:54 / 41:36 · 4:42 left" and the existing progress line, moving smoothly between refreshes.
private struct SessionProgress: View {
    let s: ActiveSession
    let it: ActiveSession.NowItem
    let fetchedAt: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let paused = s.PlayState?.IsPaused == true
            let dur = Double(it.RunTimeTicks ?? 0) / 10_000_000
            let pos = NowPlayingStyle.livePosition(reported: Double(s.PlayState?.PositionTicks ?? 0) / 10_000_000,
                                                   duration: dur, paused: paused,
                                                   elapsed: ctx.date.timeIntervalSince(fetchedAt))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: paused ? "pause.fill" : "play.fill").cvFont(10, weight: .bold)
                        .accessibilityLabel(paused ? "Paused" : "Playing")
                    Text("\(timeString(pos)) / \(timeString(dur))").monospacedDigit()
                    if let left = NowPlayingStyle.timeLeft(position: pos, duration: dur) {
                        Text("· \(left)").monospacedDigit()
                    }
                }
                .cvFont(Glass3DTokens.Text.meta, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                ClassicSessionLine(watched: dur > 0 ? min(1, pos / dur) : 0,
                                   converted: (s.TranscodingInfo?.CompletionPercentage).map { min(1, $0 / 100) })
            }
        }
    }
}
