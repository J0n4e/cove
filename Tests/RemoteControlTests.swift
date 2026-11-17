import Combine
import XCTest
@testable import Cove

// SyncPlay phase 4: Jellyfin remote control. Every Playstate / GeneralCommand / Play message decodes from
// server-shaped JSON and maps to the right action on a fake player; player commands need an open player,
// DisplayMessage doesn't; Emby gets nothing; SupportedCommands lists exactly what is honoured.

@MainActor
final class FakeRemotePlayer: RemotePlayer {
    var playing = true
    var calls: [String] = []
    var remoteIsPlaying: Bool { playing }
    var remoteVolume: Float = 0.8
    func remoteTogglePlay() { playing.toggle(); calls.append("toggle") }
    func remoteSeek(to seconds: Double) { calls.append("seek \(seconds)") }
    func remoteSkip(_ seconds: Double) { calls.append("skip \(seconds)") }
    func remoteClose() { calls.append("close") }
    func remoteNext() { calls.append("next") }
    func remotePrevious() { calls.append("previous") }
    func remoteSetAudio(_ index: Int) { calls.append("audio \(index)") }
    func remoteSetSubtitle(_ index: Int?) { calls.append("sub \(index.map(String.init) ?? "off")") }
    func remoteToggleFullscreen() { calls.append("fullscreen") }
}

@MainActor
final class RemoteControlTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    private func msg(_ s: String) -> SocketMessage {
        guard let m = SocketEnvelope.decode(s)?.message else { XCTFail("didn't decode: \(s)"); return .other("") }
        return m
    }

    static func playstate(_ c: String, ticks: Int64? = nil) -> String {
        let t = ticks.map { #","SeekPositionTicks":\#($0)"# } ?? ""
        return #"{"MessageType":"Playstate","MessageId":"m1","Data":{"Command":"\#(c)"\#(t),"ControllingUserId":"c0ffee00000040008000000000000001"}}"#
    }

    static func general(_ name: String, _ args: String = "{}") -> String {
        #"{"MessageType":"GeneralCommand","MessageId":"m2","Data":{"Name":"\#(name)","ControllingUserId":"c0ffee00000040008000000000000001","Arguments":\#(args)}}"#
    }

    static func play(_ cmd: String, ticks: Int64 = 0) -> String {
        #"{"MessageType":"Play","MessageId":"m3","Data":{"ItemIds":["film42"],"StartPositionTicks":\#(ticks),"PlayCommand":"\#(cmd)","ControllingUserId":"c0ffee00000040008000000000000001"}}"#
    }

    private final class Box {
        var messages: [(String, String, TimeInterval)] = []
        var opened: [(String, Double)] = []
        var logs: [String] = []
    }

    private func router(_ fake: FakeRemotePlayer?, jellyfin: Bool = true, box: Box = Box()) -> RemoteCommandRouter {
        let r = RemoteCommandRouter()
        r.player = { fake }
        r.isJellyfin = { jellyfin }
        r.skipSeconds = { 15 }
        r.showMessage = { box.messages.append(($0, $1, $2)) }
        r.openItem = { box.opened.append(($0, $1)) }
        r.log = { box.logs.append($0) }
        return r
    }

    // MARK: Decoding and mapping

    func testEveryPlaystateCommandDecodesAndMaps() {
        let cases: [(String, Int64?, RemoteAction)] = [
            ("Pause", nil, .pause), ("Unpause", nil, .unpause), ("PlayPause", nil, .playPause), ("Stop", nil, .stop),
            ("Seek", 1_234_500_000, .seek(seconds: 123.45)), ("Rewind", nil, .skip(seconds: -15)),
            ("FastForward", nil, .skip(seconds: 15)), ("NextTrack", nil, .nextTrack), ("PreviousTrack", nil, .previousTrack),
        ]
        for (c, t, want) in cases {
            let m = msg(Self.playstate(c, ticks: t))
            guard case .playstate(let p) = m else { return XCTFail(c) }
            XCTAssertEqual(p.Command, c)
            XCTAssertEqual(RemoteCommands.action(m, skipSeconds: 15), want, c)
        }
        XCTAssertNil(RemoteCommands.action(msg(Self.playstate("Seek")), skipSeconds: 15))   // no position
    }

    func testEveryGeneralCommandDecodesAndMaps() {
        let cases: [(String, String, RemoteAction)] = [
            ("SetVolume", #"{"Volume":"40"}"#, .setVolume(0.4)),
            ("SetVolume", #"{"Volume":250}"#, .setVolume(1)),
            ("VolumeUp", "{}", .volumeStep(RemoteCommands.volumeStep)),
            ("VolumeDown", "{}", .volumeStep(-RemoteCommands.volumeStep)),
            ("Mute", "{}", .mute), ("Unmute", "{}", .unmute), ("ToggleMute", "{}", .toggleMute),
            ("SetAudioStreamIndex", #"{"Index":"2"}"#, .audioStream(2)),
            ("SetSubtitleStreamIndex", #"{"Index":"5"}"#, .subtitleStream(5)),
            ("SetSubtitleStreamIndex", #"{"Index":"-1"}"#, .subtitleStream(nil)),
            ("ToggleFullscreen", "{}", .toggleFullscreen),
            ("DisplayMessage", #"{"Header":"Hi","Text":"Dinner's ready","TimeoutMs":"8000"}"#,
             .message(header: "Hi", text: "Dinner's ready", timeout: 8)),
            ("DisplayMessage", #"{"Header":"Hi","Text":"x"}"#, .message(header: "Hi", text: "x", timeout: RemoteCommands.defaultMessageSeconds)),
        ]
        for (name, args, want) in cases {
            let m = msg(Self.general(name, args))
            guard case .generalCommand(let g) = m else { return XCTFail(name) }
            XCTAssertEqual(g.Name, name)
            XCTAssertEqual(RemoteCommands.action(m, skipSeconds: 10), want, name + args)
        }
        XCTAssertNil(RemoteCommands.action(msg(Self.general("GoHome")), skipSeconds: 10))
        XCTAssertNil(RemoteCommands.action(msg(Self.general("SetVolume")), skipSeconds: 10))
    }

    func testPlayDecodesAndOnlyPlayNowIsHonoured() {
        let m = msg(Self.play("PlayNow", ticks: 600_000_000))
        guard case .play(let p) = m else { return XCTFail() }
        XCTAssertEqual(p.ItemIds, ["film42"])
        XCTAssertEqual(RemoteCommands.action(m, skipSeconds: 10), .playNow(itemId: "film42", startSeconds: 60))
        XCTAssertNil(RemoteCommands.action(msg(Self.play("PlayNext")), skipSeconds: 10))
        XCTAssertNil(RemoteCommands.action(msg(Self.play("PlayLast")), skipSeconds: 10))
    }

    func testBadPayloadStaysOther() {
        XCTAssertEqual(msg(#"{"MessageType":"Playstate","Data":"nope"}"#), .other("Playstate"))
        XCTAssertEqual(msg(#"{"MessageType":"UserDataChanged","Data":{}}"#), .other("UserDataChanged"))
    }

    // MARK: The router on a fake player

    func testPlaystateActsOnThePlayer() {
        let fake = FakeRemotePlayer()
        let r = router(fake)
        r.handle(msg(Self.playstate("Unpause")))          // already playing: nothing
        r.handle(msg(Self.playstate("Pause")))
        r.handle(msg(Self.playstate("Pause")))            // already paused: nothing
        r.handle(msg(Self.playstate("Unpause")))
        r.handle(msg(Self.playstate("PlayPause")))
        r.handle(msg(Self.playstate("Seek", ticks: 300_000_000)))
        r.handle(msg(Self.playstate("Rewind")))
        r.handle(msg(Self.playstate("FastForward")))
        r.handle(msg(Self.playstate("NextTrack")))
        r.handle(msg(Self.playstate("PreviousTrack")))
        r.handle(msg(Self.playstate("Stop")))
        XCTAssertEqual(fake.calls, ["toggle", "toggle", "toggle", "seek 30.0", "skip -15.0", "skip 15.0",
                                    "next", "previous", "close"])
    }

    func testGeneralCommandsActOnThePlayer() {
        let fake = FakeRemotePlayer()
        let r = router(fake)
        r.handle(msg(Self.general("SetVolume", #"{"Volume":"50"}"#)))
        XCTAssertEqual(fake.remoteVolume, 0.5, accuracy: 0.001)
        r.handle(msg(Self.general("VolumeUp")))
        XCTAssertEqual(fake.remoteVolume, 0.55, accuracy: 0.001)
        r.handle(msg(Self.general("Mute")))
        XCTAssertEqual(fake.remoteVolume, 0)
        r.handle(msg(Self.general("Unmute")))
        XCTAssertEqual(fake.remoteVolume, 0.55, accuracy: 0.001)   // back to where it was
        r.handle(msg(Self.general("ToggleMute")))
        XCTAssertEqual(fake.remoteVolume, 0)
        r.handle(msg(Self.general("ToggleMute")))
        XCTAssertEqual(fake.remoteVolume, 0.55, accuracy: 0.001)
        r.handle(msg(Self.general("VolumeDown")))
        XCTAssertEqual(fake.remoteVolume, 0.5, accuracy: 0.001)
        r.handle(msg(Self.general("SetAudioStreamIndex", #"{"Index":"1"}"#)))
        r.handle(msg(Self.general("SetSubtitleStreamIndex", #"{"Index":"3"}"#)))
        r.handle(msg(Self.general("SetSubtitleStreamIndex", #"{"Index":"-1"}"#)))
        r.handle(msg(Self.general("ToggleFullscreen")))
        XCTAssertEqual(fake.calls, ["audio 1", "sub 3", "sub off", "fullscreen"])
    }

    func testPlayerCommandsNeedAnOpenPlayerButMessagesDont() {
        let box = Box()
        let r = router(nil, box: box)
        XCTAssertNil(r.handle(msg(Self.playstate("Pause"))))
        XCTAssertNil(r.handle(msg(Self.general("SetVolume", #"{"Volume":"10"}"#))))
        XCTAssertEqual(r.handle(msg(Self.general("DisplayMessage", #"{"Header":"Hi","Text":"there","TimeoutMs":"3000"}"#))),
                       .message(header: "Hi", text: "there", timeout: 3))
        XCTAssertEqual(box.messages.count, 1)
        XCTAssertEqual(box.messages.first?.0, "Hi"); XCTAssertEqual(box.messages.first?.2, 3)
        XCTAssertTrue(box.logs.contains { $0.contains("no player open") })
        XCTAssertFalse(box.logs.contains { $0.contains("there") })   // the log has command names only
    }

    func testPlayNowOpensTheItemAndPlayNextIsIgnored() async {
        let box = Box()
        let r = router(nil, box: box)
        XCTAssertNil(r.handle(msg(Self.play("PlayNext"))))
        XCTAssertTrue(box.logs.contains { $0.contains("not supported") })
        r.handle(msg(Self.play("PlayNow", ticks: 100_000_000)))
        let ok = await waitUntil { !box.opened.isEmpty }
        XCTAssertTrue(ok)
        XCTAssertEqual(box.opened.first?.0, "film42"); XCTAssertEqual(box.opened.first?.1, 10)
    }

    func testEmbyIsIgnored() async {
        let fake = FakeRemotePlayer(), box = Box()
        let r = router(fake, jellyfin: false, box: box)
        XCTAssertNil(r.handle(msg(Self.playstate("Pause"))))
        XCTAssertNil(r.handle(msg(Self.general("DisplayMessage", #"{"Header":"Hi","Text":"x"}"#))))
        XCTAssertNil(r.handle(msg(Self.play("PlayNow"))))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(fake.calls.isEmpty); XCTAssertTrue(box.messages.isEmpty); XCTAssertTrue(box.opened.isEmpty)
    }

    func testSyncPlayMessagesAreNotRemoteCommands() {
        let r = router(FakeRemotePlayer())
        XCTAssertNil(r.handle(msg(GroupFixtures.command("Pause", when: Date()))))
        XCTAssertNil(r.handle(.keepAlive))
    }

    func testRouterFollowsTheSocketMessages() async {
        let fake = FakeRemotePlayer()
        let r = router(fake)
        let subject = PassthroughSubject<SocketMessage, Never>()
        r.listen(to: subject)
        subject.send(msg(Self.playstate("Pause")))
        XCTAssertEqual(fake.calls, ["toggle"])
    }

    // MARK: Capabilities

    func testSupportedCommandsAreExactlyWhatIsHonoured() throws {
        XCTAssertEqual(Set(SyncPlayService.supportedCommands), Set(RemoteCommands.supported))
        // Every GeneralCommand advertised maps to an action (PlayState / Play are the Playstate and Play messages)
        for name in RemoteCommands.supported where !["PlayState", "Play"].contains(name) {
            let args = name == "SetVolume" ? #"{"Volume":"5"}"# : name.hasSuffix("StreamIndex") ? #"{"Index":"1"}"#
                : name == "DisplayMessage" ? #"{"Header":"h","Text":"t"}"# : "{}"
            XCTAssertNotNil(RemoteCommands.action(msg(Self.general(name, args)), skipSeconds: 10), name)
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncPlayService.capabilitiesBody()) as? [String: Any])
        XCTAssertEqual(Set(body["SupportedCommands"] as? [String] ?? []), Set(RemoteCommands.supported))
        XCTAssertEqual(body["SupportsMediaControl"] as? Bool, true)
    }
}
