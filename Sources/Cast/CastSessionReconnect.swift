import AppKit
import Foundation
import Network

// Cast phase 2: robustness. A lost connection (Mac sleep/wake, network path change, heartbeat timeout, TV off)
// re-resolves the device by its Bonjour id and reconnects with backoff (1, 2, 4, 8, 15 s, ~2 min in all). Then
// GET_STATUS: our receiver with our media still there → re-attach without reloading; another app or nothing →
// end cleanly and report the stop at the last known position. The running cast is kept in UserDefaults
// (SavedCast) so a relaunch shows the remote again while the TV still plays it. Decisions in CastContinue.swift.

@MainActor
extension CastSession {
    // MARK: System events

    func observeSystem() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CastSession.shared.systemChanged("the Mac woke up") }
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let sig = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in CastSession.shared.pathChanged(sig, up: path.status == .satisfied) }
        }
        m.start(queue: DispatchQueue(label: "eu.jonae.cove.cast.path"))
        pathMonitor = m
    }

    private func pathChanged(_ sig: String, up: Bool) {
        defer { lastPath = sig }
        guard let last = lastPath, last != sig else { return }   // the first report is the current path
        if reconnecting, up { attempt = 0; reconnectTask?.cancel(); scheduleAttempt(); return }   // try again now
        systemChanged("the network changed")
    }

    private func systemChanged(_ why: String) {
        guard isCasting, phase != .connecting, !reconnecting else { return }
        startReconnect(why)
    }

    // MARK: Reconnect

    func startReconnect(_ why: String) {
        guard phase != .idle, !reconnecting, let device else { return }
        DebugLog.write("cast: reconnecting to \(device.model) (\(why))")
        statusTime = time; statusDate = Date()   // the clock stops at the last known position
        playerState = "BUFFERING"
        reconnecting = true
        upNext = nil
        reconnectBegan = Date(); attempt = 0
        let c = channel
        channel = nil
        c?.close()
        transportId = nil; mediaSessionId = nil
        if !browsing { browsing = true; CastDeviceStore.shared.begin() }   // re-resolve the device by its id
        scheduleAttempt()
    }

    func scheduleAttempt() {
        guard reconnecting else { return }
        guard let d = CastReconnect.delay(attempt: attempt, elapsed: Date().timeIntervalSince(reconnectBegan)) else {
            endCleanly(restoring ? nil : CastReconnect.lostMessage(device?.name ?? "the TV"))
            return
        }
        attempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(d))
            guard let self, !Task.isCancelled, self.reconnecting, let old = self.device else { return }
            let dev = CastDeviceStore.shared.devices.first { $0.id == old.id } ?? old
            self.device = dev
            DebugLog.write("cast: reconnect attempt \(self.attempt)")
            self.connect(dev, reattach: true)
        }
    }

    /// RECEIVER_STATUS after reconnecting.
    func reattach(_ st: CastReceiverStatus) {
        awaitingReceiver = false
        if let v = st.volume { volume = v }
        switch CastReconnect.receiver(st, session: receiverSession) {
        case .attach(let tid, let sid):
            transportId = tid; receiverSession = sid ?? receiverSession
            awaitingMedia = true
            channel?.send(.make(CastMessage.nsConnection, ["type": "CONNECT"], to: tid))
            send(CastMessage.nsMedia, ["type": "GET_STATUS"], to: tid)
            Task { [weak self] in   // no media answer: nothing of ours is loaded
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.awaitingMedia else { return }
                self.reattached(nil)
            }
        case .takenOver:
            endCleanly(CastReconnect.takenOverMessage)
        case .idle:
            endCleanly(CastReconnect.endedMessage)
        }
    }

    /// MEDIA_STATUS after re-attaching: continue the remote without reloading, or end.
    func reattached(_ st: CastMediaStatus?) {
        awaitingMedia = false
        guard CastReconnect.mediaAlive(st, playSessionId: playSession?.id), let st else {
            endCleanly(restoring ? nil : CastReconnect.endedMessage)
            return
        }
        let name = device?.name ?? "the TV"
        DebugLog.write("cast: re-attached (\(st.playerState) at \(Int(st.currentTime)) s)")
        stopReconnect()
        loadSent = true
        apply(st)
        startClock()
        saveActive()
        show(notice: "Reconnected to \(name)")
    }

    func stopReconnect() {
        reconnecting = false; awaitingReceiver = false; awaitingMedia = false; restoring = false
        reconnectTask?.cancel(); reconnectTask = nil
        if browsing { browsing = false; CastDeviceStore.shared.end() }
    }

    /// Ends without touching the TV (it shows something else or is gone); reports the stop at the last position.
    func endCleanly(_ message: String?) {
        guard phase != .idle else { return }
        DebugLog.write("cast: ended (\(message ?? "not running any more"))")
        error = message
        end(report: true, quitReceiver: false)
    }

    func show(notice n: String) {
        notice = n
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.notice == n { self?.notice = nil }
        }
    }

    // MARK: Saved cast (relaunch)

    func saveActive() {
        guard let emby, let device, let item, let ps = playSession, phase != .idle else { return }
        SavedCast(server: emby.server, deviceId: device.id, deviceName: device.name, itemId: item.Id,
                  sourceId: request?.sourceId, receiverSession: receiverSession, playSessionId: ps.id,
                  audio: audio, sub: sub, position: time, collectionId: collection?.id, collectionName: collection?.name,
                  collectionIds: collection?.ids).save()
    }

    /// At launch (the remote bar appears): a cast still running on the TV gets its remote back.
    func restoreIfNeeded(_ emby: Emby) {
        guard !restoreTried, phase == .idle, let saved = SavedCast.load() else { return }
        restoreTried = true
        guard saved.server == emby.server, !CastStream.isLocalOnly(emby.server) else { SavedCast.clear(); return }
        Task {
            let store = CastDeviceStore.shared
            store.begin()
            defer { store.end() }
            var dev: CastDevice?
            for _ in 0..<16 {   // up to 8 s for Bonjour
                dev = saved.restorable(server: emby.server, devices: store.devices)
                if dev != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let dev, phase == .idle, let it = await emby.itemRecord(saved.itemId) else {
                DebugLog.write("cast: saved cast not restored (device or item not found)")
                SavedCast.clear(); return
            }
            var queue: CollectionQueue?
            if let cid = saved.collectionId, let ids = saved.collectionIds, !ids.isEmpty {
                var films: [Item] = []
                for id in ids { if let f = id == it.Id ? it : await emby.itemRecord(id) { films.append(f) } }
                queue = CollectionQueue(id: cid, name: saved.collectionName ?? "Collection", items: films, index: 0).at(it)
            }
            guard phase == .idle else { return }
            begin(restoring: saved, item: it, device: dev, emby: emby, collection: queue)
        }
    }

    private func begin(restoring s: SavedCast, item it: Item, device dev: CastDevice, emby e: Emby, collection q: CollectionQueue?) {
        DebugLog.write("cast: trying to re-attach to the cast on \(dev.model)")
        emby = e; device = dev; item = it; collection = q
        audio = s.audio; sub = s.sub
        request = CastRequest(itemId: it.Id, sourceId: s.sourceId, audio: s.audio, sub: s.sub, start: s.position)
        request?.transcode = CastCopyMemory.shared.failed(device: dev.id, item: it.Id)
        if case .success(let u) = CastStream.url(server: e.server, token: e.token, keyName: e.keyName, deviceId: e.deviceId,
                                                  playSessionId: s.playSessionId, req: request!, profile: dev.profile) {
            playSession = Emby.PlaySession(itemId: it.Id, sourceId: s.sourceId, method: "Transcode", url: u,
                                           server: e.server, token: e.token)
        }
        reportedStart = playSession != nil   // the server got the start before the quit
        receiverSession = s.receiverSession
        statusTime = s.position; statusDate = Date(); duration = Double(it.RunTimeTicks ?? 0) / 10_000_000
        playerState = "BUFFERING"
        phase = .loading
        restoring = true
        reconnecting = true
        reconnectBegan = Date().addingTimeInterval(-(CastReconnect.giveUpAfter - 10))   // a short try only
        attempt = 0
        Task {
            if let f = await e.full(it.Id), self.item?.Id == it.Id {
                let src = f.MediaSources?.first { $0.Id == s.sourceId } ?? f.MediaSources?.first
                streams = src?.MediaStreams ?? []
                loadContinuation(e, it, chapters: f.Chapters ?? [])
            }
        }
        connect(dev, reattach: true)
    }
}
