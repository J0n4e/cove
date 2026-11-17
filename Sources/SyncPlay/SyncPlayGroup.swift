import Combine
import Foundation

// SyncPlay phase 2: groups. Create / join / leave a Jellyfin SyncPlay group and play, pause and seek together.
// Protocol, checked against the server source (jellyfin/jellyfin master):
// - Jellyfin.Api/Controllers/SyncPlayController.cs: GET /SyncPlay/List, POST /SyncPlay/New {GroupName},
//   /Join {GroupId}, /Leave, /SetNewQueue {PlayingQueue, PlayingItemPosition, StartPositionTicks}, /Pause,
//   /Unpause, /Seek {PositionTicks}, /Stop, /Buffering and /Ready {When, PositionTicks, IsPlaying, PlaylistItemId},
//   /Ping {Ping (ms)}.
// - MediaBrowser.Model/SyncPlay: GroupUpdate<T> {GroupId, Type, Data}; GroupInfoDto {GroupId, GroupName, State,
//   Participants, LastUpdatedAt}; GroupStateUpdate {State, Reason}; PlayQueueUpdate {Reason, LastUpdate, Playlist
//   [{ItemId, PlaylistItemId}], PlayingItemIndex, StartPositionTicks, IsPlaying, ShuffleMode, RepeatMode};
//   SendCommand {GroupId, PlaylistItemId, When, PositionTicks, Command, EmittedAt}.
// Client flow as in jellyfin-web (src/plugins/syncPlay/core): a command runs at its `When` on our clock (late:
// at once, an Unpause then jumps ahead by the time missed); a PlayQueue update loads the item and reports
// Buffering then Ready; while in a group the user's own play / pause / seek are sent as requests and only
// happen when the server's command comes back (it is sent to every member, us included).

/// GroupInfoDto
struct SyncPlayGroupInfo: Decodable, Equatable, Identifiable {
    let GroupId: String
    let GroupName: String
    let State: String?
    let Participants: [String]?
    var id: String { GroupId }
}

/// PlayQueueUpdate
struct SyncPlayQueueUpdate: Decodable, Equatable {
    struct Entry: Decodable, Equatable { let ItemId: String; let PlaylistItemId: String }
    let Reason: String
    let LastUpdate: String?
    let Playlist: [Entry]
    let PlayingItemIndex: Int
    let StartPositionTicks: Int64
    let IsPlaying: Bool

    var playing: Entry? { Playlist.indices.contains(PlayingItemIndex) ? Playlist[PlayingItemIndex] : nil }
}

@MainActor
final class SyncPlayGroup: ObservableObject {
    struct Info: Equatable {
        var id: String
        var name: String
        var participants: [String]
        /// GroupStateType: Idle, Waiting, Paused, Playing
        var state: String
    }

    enum State: Equatable {
        case notInGroup
        case joining
        case inGroup(Info)
    }

    /// What the user did in the player, sent to the group instead of applied.
    enum LocalAction: Equatable {
        case play, pause
        case seek(ticks: Int64)
    }

    nonisolated static let ticksPerSecond: Double = 10_000_000
    nonisolated static let pingInterval: TimeInterval = 10

    @Published private(set) var state: State = .notInGroup
    /// "ldoctoru joined" for a few seconds
    @Published private(set) var toast: String?
    @Published private(set) var groups: [SyncPlayGroupInfo] = []
    @Published private(set) var loadingList = false
    /// Phase 3: "Don't wait for others" (POST /SyncPlay/SetIgnoreWait). Per session, like jellyfin-web's
    /// followingGroupPlayback (Manager.js), which isn't saved either.
    @Published private(set) var ignoreWait = false
    /// The playlist entry the group is on (sent back with Ready / Buffering).
    private(set) var playlistItemId: String?
    private(set) var playingItemId: String?

    var info: Info? { if case .inGroup(let i) = state { return i }; return nil }
    var isInGroup: Bool { info != nil }
    var isActive: Bool { state != .notInGroup }

    // Injected so tests run without a server or a player
    /// POST (body non-nil or `post`) / GET a SyncPlay path; nil = no answer (or not allowed / not Jellyfin).
    var send: @MainActor (_ path: String, _ body: Data?, _ post: Bool) async -> Data? = { _, _, _ in nil }
    var available: @MainActor () -> Bool = { false }
    var socketNeeded: @MainActor (Bool) -> Void = { _ in }
    /// Waits until the socket is up (the server only sends group updates over it).
    var waitConnected: @MainActor () async -> Void = {}
    var clock: @MainActor () -> TimeSync = { TimeSync() }
    var now: @MainActor () -> Date = { Date() }
    var playback: @MainActor () -> SyncPlayPlayback? = { nil }
    /// Opens the player on an item, paused, at a position in seconds.
    var opener: @MainActor (_ itemId: String, _ start: Double) async -> Void = { _, _ in }
    var log: @MainActor (String) -> Void = { DebugLog.write($0) }
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    private var scheduled: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var bag: Set<AnyCancellable> = []
    // Phase 3: drift correction and mid-playback buffering (SyncCorrection.swift)
    private(set) var driver = SyncDriver()
    private var driverTask: Task<Void, Never>?
    /// A load / seek's Buffering → Ready report is running (no corrections, no stall reports meanwhile)
    private(set) var busy = false
    nonisolated static let driverInterval: TimeInterval = 0.25
    /// Tests run the driver by hand
    var runsDriver = true
    private var rejoining = false
    private var lastRejoin: Date?

    init() {}

    /// Follows the socket's SyncPlay messages.
    func listen(to messages: PassthroughSubject<SocketMessage, Never>) {
        messages.sink { [weak self] m in
            MainActor.assumeIsolated { self?.handle(m) }
        }.store(in: &bag)
    }

    // MARK: Requests

    nonisolated static func body(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    nonisolated static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    @discardableResult
    private func post(_ path: String, _ o: [String: Any]? = nil, quiet: Bool = false) async -> Data? {
        if !quiet { log("SyncPlay: sending \(path)") }
        return await send(path, o.map { Self.body($0) }, true)
    }

    func refreshList() async {
        guard available() else { groups = []; return }
        loadingList = true
        defer { loadingList = false }
        guard let d = await send("/SyncPlay/List", nil, false),
              let g = try? JSONDecoder().decode([SyncPlayGroupInfo].self, from: d) else { groups = []; return }
        groups = g
    }

    /// New group, then (when `itemId` is given) its queue: the PlayQueue update that follows opens the player.
    func create(name: String, itemId: String?, startTicks: Int64) async {
        guard available(), !isActive else { return }
        state = .joining
        socketNeeded(true)
        await waitConnected()
        guard let d = await post("/SyncPlay/New", ["GroupName": name]),
              let g = try? JSONDecoder().decode(SyncPlayGroupInfo.self, from: d) else {
            log("SyncPlay: creating the group failed")
            dropOut()
            return
        }
        joined(g)
        if let itemId {
            await post("/SyncPlay/SetNewQueue", ["PlayingQueue": [itemId], "PlayingItemPosition": 0,
                                                 "StartPositionTicks": max(0, startTicks)])
        }
    }

    func join(_ groupId: String) async {
        guard available(), !isActive else { return }
        state = .joining
        socketNeeded(true)
        await waitConnected()
        // 204 No Content: the empty answer is a success; GroupJoined comes over the socket
        if await post("/SyncPlay/Join", ["GroupId": groupId]) == nil {
            log("SyncPlay: joining failed")
            dropOut()
        }
    }

    func leave() async {
        guard isActive else { return }
        log("SyncPlay: leaving \(info?.name ?? "group")")
        dropOut()
        await post("/SyncPlay/Leave")
    }

    /// Back to no group (also after sign-out / server switch, where Leave is sent by the service).
    func reset() {
        scheduled?.cancel(); scheduled = nil
        pingTask?.cancel(); pingTask = nil
        driverTask?.cancel(); driverTask = nil
        if driver.stopped() { playback()?.syncPlaySetRate(1.0) }
        busy = false; ignoreWait = false; rejoining = false
        loadTask?.cancel(); loadTask = nil
        playlistItemId = nil; playingItemId = nil
        state = .notInGroup
    }

    private func dropOut() {
        reset()
        socketNeeded(false)
    }

    /// The player's play / pause / seek while in a group: sent as a request, not applied. False = not in a
    /// group, the player does it itself.
    func intercept(_ a: LocalAction) -> Bool {
        guard isInGroup else { return false }
        Task {
            switch a {
            case .play: await post("/SyncPlay/Unpause")
            case .pause: await post("/SyncPlay/Pause")
            case .seek(let t): await post("/SyncPlay/Seek", ["PositionTicks": max(0, t)])
            }
        }
        return true
    }

    /// The player was closed while in a group: leave it.
    func playerClosed() {
        guard isActive else { return }
        Task { await leave() }
    }

    private func report(_ path: String, ticks: Int64, playing: Bool) async {
        guard let pid = playlistItemId else { return }
        await post(path, ["When": Self.iso(clock().serverNow(local: now())), "PositionTicks": max(0, ticks),
                          "IsPlaying": playing, "PlaylistItemId": pid])
    }

    /// Buffering, then Ready once the player is ready (as jellyfin-web does after a load or a seek).
    private func reportBufferingThenReady() async {
        busy = true
        defer { busy = false }
        let p = playback()
        await report("/SyncPlay/Buffering", ticks: p?.syncPlayTicks ?? 0, playing: false)
        for _ in 0..<240 {   // up to a minute
            if let p = playback(), p.syncPlayReady, playingItemId == nil || p.syncPlayItemId == playingItemId { break }
            do { try await sleep(0.25) } catch { return }
        }
        guard !Task.isCancelled, let p = playback() else { return }
        await report("/SyncPlay/Ready", ticks: p.syncPlayTicks, playing: p.syncPlayIsPlaying)
    }

    // MARK: Messages

    func handle(_ m: SocketMessage) {
        switch m {
        case .syncPlayCommand(let c): handle(c)
        case .syncPlayGroupUpdate(let u): handle(u)
        default: break
        }
    }

    private func joined(_ g: SyncPlayGroupInfo) {
        let wasIn = info?.id == g.GroupId
        state = .inGroup(Info(id: g.GroupId, name: g.GroupName, participants: g.Participants ?? [], state: g.State ?? "Idle"))
        if !wasIn { log("SyncPlay: joined \"\(g.GroupName)\" (\((g.Participants ?? []).count) watching)") }
        else if rejoining { log("SyncPlay: back in \"\(g.GroupName)\"") }
        rejoining = false
        startPing()
        startDriver()
    }

    func handle(_ u: SyncPlayGroupUpdate) {
        switch u.type {
        case "GroupJoined":
            if let g = u.group { joined(g) }
        case "UserJoined":
            guard var i = info, i.id == u.GroupId, let name = u.text else { return }
            i.participants.append(name); state = .inGroup(i)
            log("SyncPlay: \(name) joined"); show("\(name) joined")
        case "UserLeft":
            guard var i = info, i.id == u.GroupId, let name = u.text else { return }
            if let k = i.participants.firstIndex(of: name) { i.participants.remove(at: k) }
            state = .inGroup(i)
            log("SyncPlay: \(name) left"); show("\(name) left")
        case "GroupLeft":
            guard isActive else { return }
            log("SyncPlay: \(u.type)"); dropOut()
        case "NotInGroup":
            // The server forgot us (its session ended while we were away): try to get back in once
            guard isActive else { return }
            log("SyncPlay: NotInGroup")
            if isInGroup, !rejoining, lastRejoin.map({ now().timeIntervalSince($0) > 30 }) ?? true {
                Task { await rejoin() }
            } else if !rejoining {
                dropOut()
            }
        case "GroupDoesNotExist", "LibraryAccessDenied":
            log("SyncPlay: \(u.type)")
            if u.type == "GroupDoesNotExist" { show(rejoining ? Self.endedText : "That group no longer exists") }
            else { show("No access to what the group is playing") }
            dropOut()
        case "StateUpdate":
            guard var i = info, i.id == u.GroupId, let s = u.state else { return }
            i.state = s; state = .inGroup(i)
        case "PlayQueue":
            guard isInGroup, let q = u.queue else { return }
            handle(q)
        default: break
        }
    }

    func handle(_ q: SyncPlayQueueUpdate) {
        guard let e = q.playing else { playlistItemId = nil; return }
        playlistItemId = e.PlaylistItemId
        guard ["NewPlaylist", "SetCurrentItem", "NextItem", "PreviousItem"].contains(q.Reason) else { return }
        // Playing: the group has moved on since LastUpdate
        var ticks = q.StartPositionTicks
        if q.IsPlaying, let s = q.LastUpdate, let d = TimeSync.parseDate(s) {
            let elapsed = now().timeIntervalSince(clock().localDate(forServer: d))
            if elapsed > 0 { ticks += Int64(elapsed * Self.ticksPerSecond) }
        }
        if driver.stopped() { playback()?.syncPlaySetRate(1.0) }
        log("SyncPlay: play queue \(q.Reason), item at \(Int(Double(ticks) / Self.ticksPerSecond)) s")
        let itemId = e.ItemId
        playingItemId = itemId
        loadTask?.cancel()
        loadTask = Task {
            if let p = playback(), p.syncPlayItemId == itemId {
                p.syncPlayPause(); p.syncPlaySeek(ticks: ticks)
            } else {
                await opener(itemId, Double(ticks) / Self.ticksPerSecond)
            }
            guard !Task.isCancelled else { return }
            await reportBufferingThenReady()
        }
    }

    func handle(_ c: SyncPlayCommand) {
        guard let i = info, i.id == c.GroupId, let w = TimeSync.parseDate(c.When) else { return }
        let at = clock().localDate(forServer: w)
        let delay = at.timeIntervalSince(now())
        log("SyncPlay: \(c.Command) received, runs in \(Int(delay * 1000)) ms")
        scheduled?.cancel()
        if delay > 0 {
            scheduled = Task {
                do { try await sleep(delay) } catch { return }
                guard !Task.isCancelled else { return }
                apply(c, late: 0)
            }
        } else {
            apply(c, late: -delay)
        }
    }

    /// Runs a command `late` seconds after its time.
    private func apply(_ c: SyncPlayCommand, late: TimeInterval) {
        guard let p = playback() else { return }
        if c.Command != "Unpause", driver.stopped() { p.syncPlaySetRate(1.0) }
        switch c.Command {
        case "Unpause":
            if let pos = c.PositionTicks {
                let target = pos + Int64(late * Self.ticksPerSecond)
                if late > 0 || abs(p.syncPlayTicks - target) > Int64(0.5 * Self.ticksPerSecond) { p.syncPlaySeek(ticks: target) }
                if let w = TimeSync.parseDate(c.When) {
                    if driver.stopped() { p.syncPlaySetRate(1.0) }
                    driver.unpaused(.init(positionTicks: pos, when: w, playlistItemId: c.PlaylistItemId, appliedAt: now()))
                }
            }
            p.syncPlayPlay()
        case "Pause":
            p.syncPlayPause()
            if let pos = c.PositionTicks { p.syncPlaySeek(ticks: pos) }
        case "Seek":
            p.syncPlayPause()
            if let pos = c.PositionTicks { p.syncPlaySeek(ticks: pos) }
            loadTask?.cancel()
            loadTask = Task { await reportBufferingThenReady() }
        case "Stop":
            p.syncPlayPause()
        default: break
        }
    }

    // MARK: Phase 3: drift correction, mid-playback buffering, rejoin, don't wait

    nonisolated static let endedText = "The group has ended"

    private func startDriver() {
        guard runsDriver, driverTask == nil else { return }
        driverTask = Task {
            while !Task.isCancelled, isInGroup {
                do { try await sleep(Self.driverInterval) } catch { return }
                driverStep()
            }
        }
    }

    /// One look at the player: corrects drift, reports a stall as Buffering and its end as Ready.
    func driverStep() {
        guard isInGroup, let p = playback() else { return }
        let t = now()
        let out = driver.step(now: t, serverNow: clock().serverNow(local: t), ticks: p.syncPlayTicks,
                              playing: p.syncPlayIsPlaying, stalled: p.syncPlayStalled, busy: busy,
                              playlistItemId: playlistItemId)
        for o in out {
            switch o {
            case .resetRate: p.syncPlaySetRate(1.0)
            case .correct(let a, let d):
                switch a {
                case .speed(let rate, let duration):
                    log("SyncPlay: \(Int(abs(d))) ms \(d > 0 ? "behind" : "ahead"), SpeedToSync x"
                        + String(format: "%.2f for %.1f s", rate, duration))
                    p.syncPlaySetRate(rate)
                case .skip(let ticks):
                    log("SyncPlay: \(Int(abs(d))) ms \(d > 0 ? "behind" : "ahead"), SkipToSync")
                    p.syncPlaySeek(ticks: ticks)
                case .none: break
                }
            case .buffering:
                // Don't wait for others: the group isn't held up by this client (the server ignores its
                // buffering too); it catches up by SkipToSync once playing again
                guard !ignoreWait else { log("SyncPlay: stalled, not holding up the group"); continue }
                log("SyncPlay: stalled, telling the group to wait")
                let ticks = p.syncPlayTicks, playing = p.syncPlayIsPlaying
                Task { await report("/SyncPlay/Buffering", ticks: ticks, playing: playing) }
            case .ready:
                guard !ignoreWait else { continue }
                log("SyncPlay: playing again, ready")
                let ticks = p.syncPlayTicks, playing = p.syncPlayIsPlaying
                Task { await report("/SyncPlay/Ready", ticks: ticks, playing: playing) }
            }
        }
    }

    /// The socket came back (Wi-Fi, sleep): the server may have dropped us. Join the group again if it still
    /// exists (the server restores the session and sends its state and queue), else leave it.
    func rejoin() async {
        guard let i = info, !rejoining else { return }
        rejoining = true
        lastRejoin = now()
        log("SyncPlay: reconnected, checking \"\(i.name)\" still exists")
        if driver.stopped() { playback()?.syncPlaySetRate(1.0) }
        guard let d = await send("/SyncPlay/List", nil, false),
              let list = try? JSONDecoder().decode([SyncPlayGroupInfo].self, from: d) else {
            log("SyncPlay: couldn't list the groups")
            rejoining = false
            return
        }
        guard info?.id == i.id else { rejoining = false; return }
        guard list.contains(where: { $0.GroupId == i.id }) else {
            log("SyncPlay: the group has ended")
            show(Self.endedText)
            dropOut()
            return
        }
        if await post("/SyncPlay/Join", ["GroupId": i.id]) == nil {
            log("SyncPlay: joining again failed")
            rejoining = false
            return
        }
        if ignoreWait { await post("/SyncPlay/SetIgnoreWait", ["IgnoreWait": true]) }
        // GroupJoined clears `rejoining`; don't hang on it if it never comes
        Task { try? await sleep(10); rejoining = false }
    }

    /// "Don't wait for others": the group keeps playing while this client buffers (server: Group.cs
    /// SetIgnoreGroupWait; a member with IgnoreGroupWait doesn't count as buffering). This client then skips
    /// back into step when its stream recovers.
    func setIgnoreWait(_ on: Bool) async {
        guard isInGroup else { return }
        ignoreWait = on
        await post("/SyncPlay/SetIgnoreWait", ["IgnoreWait": on])
    }

    // MARK: Ping, toast

    private func startPing() {
        guard pingTask == nil else { return }
        pingTask = Task {
            while !Task.isCancelled, isInGroup {
                let ms = Int64(((clock().best?.delay ?? 0) * 1000).rounded())
                await post("/SyncPlay/Ping", ["Ping": max(0, ms)], quiet: true)
                do { try await sleep(Self.pingInterval) } catch { return }
            }
        }
    }

    private func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
