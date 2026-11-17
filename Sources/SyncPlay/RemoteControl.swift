import Combine
import Foundation
import SwiftUI

// SyncPlay phase 4: remote control from the Jellyfin Dashboard (Sessions → Cove) and other clients. Jellyfin only:
// the messages come over the Jellyfin socket, which Emby never gets. Protocol (jellyfin/jellyfin master):
// - MediaBrowser.Model/Session/PlaystateRequest.cs {Command, SeekPositionTicks, ControllingUserId}, with
//   PlaystateCommand.cs: Stop, Pause, Unpause, NextTrack, PreviousTrack, Seek, Rewind, FastForward, PlayPause.
//   Sent as MessageType "Playstate".
// - GeneralCommand.cs {Name, ControllingUserId, Arguments (string → string)}, MessageType "GeneralCommand":
//   SetVolume {Volume 0-100}, VolumeUp, VolumeDown, Mute, Unmute, ToggleMute, SetAudioStreamIndex {Index},
//   SetSubtitleStreamIndex {Index, -1 = off}, ToggleFullscreen, DisplayMessage {Header, Text, TimeoutMs}.
// - PlayRequest.cs {ItemIds, StartPositionTicks, PlayCommand (PlayNow / PlayNext / PlayLast / …)}, MessageType "Play".
// Player commands act only while a player is open; DisplayMessage always. In a SyncPlay group pause / play / seek
// go through PlayerModel.togglePlay / seek, which send them to the group like the user's own.

struct RemotePlaystate: Decodable, Equatable {
    let Command: String
    let SeekPositionTicks: Int64?
}

struct RemoteGeneralCommand: Decodable, Equatable {
    let Name: String
    /// Jellyfin sends strings; numbers are accepted too
    let Arguments: [String: String]

    private enum K: String, CodingKey { case Name, Arguments }
    private struct Value: Decodable {
        let s: String?
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let v = try? c.decode(String.self) { s = v }
            else if let v = try? c.decode(Int64.self) { s = String(v) }
            else if let v = try? c.decode(Double.self) { s = String(v) }
            else if let v = try? c.decode(Bool.self) { s = String(v) }
            else { s = nil }
        }
    }

    init(Name: String, Arguments: [String: String] = [:]) { self.Name = Name; self.Arguments = Arguments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        Name = try c.decode(String.self, forKey: .Name)
        let raw = (try? c.decode([String: Value].self, forKey: .Arguments)) ?? [:]
        Arguments = raw.compactMapValues { $0.s }
    }
}

struct RemotePlayRequest: Decodable, Equatable {
    let ItemIds: [String]
    let StartPositionTicks: Int64?
    let PlayCommand: String
}

/// What a remote command does to the player.
enum RemoteAction: Equatable {
    case pause, unpause, playPause, stop
    case seek(seconds: Double)
    case skip(seconds: Double)
    case nextTrack, previousTrack
    /// 0…1
    case setVolume(Float)
    case volumeStep(Float)
    case mute, unmute, toggleMute
    case audioStream(Int)
    /// nil = subtitles off
    case subtitleStream(Int?)
    case toggleFullscreen
    case message(header: String, text: String, timeout: TimeInterval)
    case playNow(itemId: String, startSeconds: Double)

    /// Acts on an open player (DisplayMessage and Play don't need one)
    var needsPlayer: Bool {
        switch self {
        case .message, .playNow: return false
        default: return true
        }
    }
}

enum RemoteCommands {
    /// GeneralCommandType names honoured (posted as the session's SupportedCommands)
    static let supported = ["PlayState", "Play", "VolumeUp", "VolumeDown", "Mute", "Unmute", "ToggleMute",
                            "SetVolume", "SetAudioStreamIndex", "SetSubtitleStreamIndex", "ToggleFullscreen",
                            "DisplayMessage"]
    static let volumeStep: Float = 0.05
    static let defaultMessageSeconds: TimeInterval = 5

    /// The action for a socket message; nil = not a remote command, or one Cove doesn't honour (logged by the router).
    static func action(_ m: SocketMessage, skipSeconds: Int) -> RemoteAction? {
        switch m {
        case .playstate(let p):
            switch p.Command {
            case "Pause": return .pause
            case "Unpause": return .unpause
            case "PlayPause": return .playPause
            case "Stop": return .stop
            case "Seek": return p.SeekPositionTicks.map { .seek(seconds: Double(max(0, $0)) / SyncPlayGroup.ticksPerSecond) }
            case "Rewind": return .skip(seconds: -Double(skipSeconds))
            case "FastForward": return .skip(seconds: Double(skipSeconds))
            case "NextTrack": return .nextTrack
            case "PreviousTrack": return .previousTrack
            default: return nil
            }
        case .generalCommand(let g):
            let a = g.Arguments
            switch g.Name {
            case "SetVolume":
                guard let v = a["Volume"].flatMap({ Double($0) }) else { return nil }
                return .setVolume(Float(min(100, max(0, v)) / 100))
            case "VolumeUp": return .volumeStep(volumeStep)
            case "VolumeDown": return .volumeStep(-volumeStep)
            case "Mute": return .mute
            case "Unmute": return .unmute
            case "ToggleMute": return .toggleMute
            case "SetAudioStreamIndex": return a["Index"].flatMap { Int($0) }.map { .audioStream($0) }
            case "SetSubtitleStreamIndex":
                guard let i = a["Index"].flatMap({ Int($0) }) else { return nil }
                return .subtitleStream(i < 0 ? nil : i)
            case "ToggleFullscreen": return .toggleFullscreen
            case "DisplayMessage":
                let ms = a["TimeoutMs"].flatMap { Double($0) }
                let t = ms.map { $0 / 1000 } ?? defaultMessageSeconds
                return .message(header: a["Header"] ?? "", text: a["Text"] ?? "", timeout: min(60, max(1, t)))
            default: return nil
            }
        case .play(let p):
            guard p.PlayCommand == "PlayNow", let id = p.ItemIds.first else { return nil }
            return .playNow(itemId: id, startSeconds: Double(max(0, p.StartPositionTicks ?? 0)) / SyncPlayGroup.ticksPerSecond)
        default: return nil
        }
    }

    /// For the log: the command's name only (no ids, no message text)
    static func name(_ m: SocketMessage) -> String? {
        switch m {
        case .playstate(let p): return "Playstate \(p.Command)"
        case .generalCommand(let g): return "GeneralCommand \(g.Name)"
        case .play(let p): return "Play \(p.PlayCommand)"
        default: return nil
        }
    }
}

/// The open player as remote control sees it (tests use a fake).
@MainActor
protocol RemotePlayer: AnyObject {
    var remoteIsPlaying: Bool { get }
    var remoteVolume: Float { get set }
    func remoteTogglePlay()
    func remoteSeek(to seconds: Double)
    func remoteSkip(_ seconds: Double)
    func remoteClose()
    func remoteNext()
    func remotePrevious()
    func remoteSetAudio(_ index: Int)
    func remoteSetSubtitle(_ index: Int?)
    func remoteToggleFullscreen()
}

@MainActor
final class RemoteCommandRouter {
    static let shared = RemoteCommandRouter()

    var player: @MainActor () -> RemotePlayer? = { PlayerRemoteHandle.current }
    var isJellyfin: @MainActor () -> Bool = { false }
    var skipSeconds: @MainActor () -> Int = {
        let s = UserDefaults.standard.integer(forKey: "skipSeconds")
        return s > 0 ? s : 10
    }
    var showMessage: @MainActor (_ header: String, _ text: String, _ timeout: TimeInterval) -> Void = { h, t, s in
        RemoteMessageCenter.shared.show(header: h, text: t, timeout: s)
    }
    var openItem: @MainActor (_ itemId: String, _ start: Double) async -> Void = { _, _ in }
    /// In a SyncPlay group, PlayNow goes to the group (true = sent; the PlayQueue update opens it here)
    var groupPlayNow: @MainActor (_ itemId: String, _ start: Double) -> Bool = { _, _ in false }
    var log: @MainActor (String) -> Void = { DebugLog.write($0) }

    /// The volume before Mute, for Unmute
    private(set) var volumeBeforeMute: Float?
    private var bag: Set<AnyCancellable> = []

    init() {}

    func attach(to emby: Emby, messages: PassthroughSubject<SocketMessage, Never>) {
        isJellyfin = { [weak emby] in emby?.isJellyfin ?? false }
        openItem = { [weak emby] id, start in await emby?.remotePlayNow(id, start: start) }
        bag = []
        listen(to: messages)
    }

    func listen(to messages: PassthroughSubject<SocketMessage, Never>) {
        messages.sink { [weak self] m in
            MainActor.assumeIsolated { _ = self?.handle(m) }
        }.store(in: &bag)
    }

    /// Runs a remote command; returns the action taken (nil = none).
    @discardableResult
    func handle(_ m: SocketMessage) -> RemoteAction? {
        guard let name = RemoteCommands.name(m) else { return nil }
        guard isJellyfin() else { return nil }
        guard let a = RemoteCommands.action(m, skipSeconds: skipSeconds()) else {
            log("Remote: \(name) received, not supported, ignored")
            return nil
        }
        if !a.needsPlayer {
            log("Remote: \(name) received")
            switch a {
            case .message(let h, let t, let s): showMessage(h, t, s)
            case .playNow(let id, let start):
                if !groupPlayNow(id, start) { Task { await openItem(id, start) } }
            default: break
            }
            return a
        }
        guard let p = player() else {
            log("Remote: \(name) received, no player open, ignored")
            return nil
        }
        log("Remote: \(name) received")
        perform(a, on: p)
        return a
    }

    func perform(_ a: RemoteAction, on p: RemotePlayer) {
        switch a {
        case .pause: if p.remoteIsPlaying { p.remoteTogglePlay() }
        case .unpause: if !p.remoteIsPlaying { p.remoteTogglePlay() }
        case .playPause: p.remoteTogglePlay()
        case .stop: p.remoteClose()
        case .seek(let s): p.remoteSeek(to: s)
        case .skip(let s): p.remoteSkip(s)
        case .nextTrack: p.remoteNext()
        case .previousTrack: p.remotePrevious()
        case .setVolume(let v): p.remoteVolume = v
        case .volumeStep(let d): p.remoteVolume = min(1, max(0, p.remoteVolume + d))
        case .mute: mute(p)
        case .unmute: unmute(p)
        case .toggleMute: if p.remoteVolume > 0 { mute(p) } else { unmute(p) }
        case .audioStream(let i): p.remoteSetAudio(i)
        case .subtitleStream(let i): p.remoteSetSubtitle(i)
        case .toggleFullscreen: p.remoteToggleFullscreen()
        case .message, .playNow: break
        }
    }

    private func mute(_ p: RemotePlayer) {
        guard p.remoteVolume > 0 else { return }
        volumeBeforeMute = p.remoteVolume
        p.remoteVolume = 0
    }

    private func unmute(_ p: RemotePlayer) {
        guard p.remoteVolume == 0 else { return }
        p.remoteVolume = volumeBeforeMute ?? 1
    }
}

/// The open player for remote control: the engine plus the view's own actions (close, next / previous episode,
/// full screen), registered by the player view when it appears.
@MainActor
final class PlayerRemoteHandle: RemotePlayer {
    private static var active: PlayerRemoteHandle?

    /// The open player, nil when it's closed
    static var current: RemotePlayer? {
        guard let a = active, a.model != nil, a.emby?.playing != nil else { return nil }
        return a
    }

    private weak var model: PlayerModel?
    private weak var emby: Emby?
    private let close: @MainActor () -> Void
    private let next: @MainActor () -> Void
    private let previous: @MainActor () -> Void
    private let fullScreen: @MainActor () -> Void

    private init(_ model: PlayerModel, emby: Emby, close: @escaping @MainActor () -> Void, next: @escaping @MainActor () -> Void,
                 previous: @escaping @MainActor () -> Void, fullScreen: @escaping @MainActor () -> Void) {
        self.model = model; self.emby = emby
        self.close = close; self.next = next; self.previous = previous; self.fullScreen = fullScreen
    }

    static func attach(_ model: PlayerModel, emby: Emby, close: @escaping @MainActor () -> Void, next: @escaping @MainActor () -> Void,
                       previous: @escaping @MainActor () -> Void, fullScreen: @escaping @MainActor () -> Void) {
        active = PlayerRemoteHandle(model, emby: emby, close: close, next: next, previous: previous, fullScreen: fullScreen)
    }

    var remoteIsPlaying: Bool { (model?.player?.rate ?? 0) > 0 }
    var remoteVolume: Float {
        get { model?.volume ?? 0 }
        set { model?.volume = newValue }
    }
    func remoteTogglePlay() { model?.togglePlay() }
    func remoteSeek(to seconds: Double) { model?.seek(to: seconds) }
    func remoteSkip(_ seconds: Double) { model?.skip(seconds) }
    func remoteClose() { close() }
    func remoteNext() { next() }
    func remotePrevious() { previous() }
    func remoteSetAudio(_ index: Int) {
        guard let model, let emby else { return }
        Task { await model.setAudio(emby, index) }
    }
    func remoteSetSubtitle(_ index: Int?) {
        guard let model, let emby else { return }
        Task { await model.setSub(emby, index) }
    }
    func remoteToggleFullscreen() { fullScreen() }
}

extension Emby {
    /// Play → PlayNow: open the item at the start position.
    func remotePlayNow(_ itemId: String, start: Double) async {
        guard let it: Item = try? await get("/Users/\(userId)/Items/\(itemId)") else {
            DebugLog.write("Remote: couldn't load the item to play")
            return
        }
        playing = PlayRequest(item: it, start: start > 0 ? start : nil)
    }
}

// MARK: - DisplayMessage toast

@MainActor
final class RemoteMessageCenter: ObservableObject {
    struct Message: Equatable {
        let id = UUID()
        let header: String
        let text: String
    }

    static let shared = RemoteMessageCenter()
    @Published private(set) var message: Message?
    private var hideTask: Task<Void, Never>?

    func show(header: String, text: String, timeout: TimeInterval) {
        guard !(header.isEmpty && text.isEmpty) else { return }
        message = Message(header: header, text: text)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// A message sent from the Dashboard: a glass pill at the bottom of the window for its TimeoutMs.
struct RemoteMessageToast: View {
    @ObservedObject var center = RemoteMessageCenter.shared
    var body: some View {
        VStack {
            Spacer()
            if let m = center.message {
                VStack(spacing: 3) {
                    if !m.header.isEmpty { Text(m.header).coveFont(size: 15, weight: .bold) }
                    if !m.text.isEmpty { Text(m.text).coveFont(size: 13).multilineTextAlignment(.center) }
                }
                .foregroundColor(.white)
                .frame(maxWidth: 460)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .searchGlass()
                .environment(\.colorScheme, .dark)
                .transition(.coveGlassPopIn)
                .id(m.id)
            }
        }
        .padding(.bottom, 130)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(.coveGlassPopIn, value: center.message)
    }
}
