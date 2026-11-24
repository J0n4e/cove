import SwiftUI

/// Activity → Now Playing, on each session card: an 'i' with the stream details (everyone) and, for admins on
/// other people's sessions, a '⋯' with Send message…, Stop playback and Sign out device… (confirmed).
struct SessionAdminControls: View {
    @EnvironmentObject var emby: Emby
    @ObservedObject private var profile = ProfileModel.shared
    @AppStorage("accent") private var accentName = "red"
    let s: ActiveSession
    @State private var info = false
    @State private var messageOpen = false
    @State private var confirmOpen = false
    @State private var text = ""
    @State private var busy = false
    @State private var note: String?

    private var admin: Bool {
        SessionAdminAPI.offersActions(isAdmin: profile.admin, sessionDeviceId: s.DeviceId, myDeviceId: emby.deviceId)
    }
    private var kind: ServerAdminKind { emby.isJellyfin ? .jellyfin : .emby }

    var body: some View {
        HStack(spacing: 6) {
            if let note { Text(note).cvFont(11, weight: .semibold).foregroundColor(.white).padding(.horizontal, 8).frame(height: 24).classicGlassPill(iconOnly: false) }
            if profile.admin == true {
            Button { info.toggle() } label: {
                Image(systemName: "info").cvFont(11, weight: .bold).frame(width: 26, height: 26).classicGlassPill()
            }
            .buttonStyle(.plainHand).tip("Stream details")
            .popover(isPresented: $info, arrowEdge: .bottom) { details }
            }
            if admin {
                GlassListButton(list: {
                    let acts: [(String, () -> Void)] = [("Send message…", { messageOpen = true }),
                                                         ("Stop playback", { stop() }),
                                                         ("Sign out device…", { confirmOpen = true })]
                    return (acts.map { $0.0 }, Set<Int>(), Set<Int>(), { i in if i >= 0 && i < acts.count { acts[i].1() } })
                }) {
                    Label("Session actions", systemImage: "ellipsis").labelStyle(.iconOnly).cvFont(11, weight: .bold)
                        .frame(width: 26, height: 26).classicGlassPill()
                }
                .popover(isPresented: $messageOpen, arrowEdge: .bottom) { messageForm }
                .popover(isPresented: $confirmOpen, arrowEdge: .bottom) { confirmForm }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stream details").cvFont(13, weight: .bold).foregroundColor(.white)
            ForEach(StreamDetails.rows(s), id: \.label) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.label).cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary).frame(width: 64, alignment: .leading)
                    Text(r.value).cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(width: 320, alignment: .leading)
        .preferredColorScheme(.dark)
    }

    private var messageForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Message to \(s.UserName ?? "this session")").cvFont(13, weight: .bold).foregroundColor(.white)
            TextField("Shown on their screen for 8 seconds", text: $text).textFieldStyle(.roundedBorder).cvFont(13)
                .onChange(of: text) { _, v in if v.count > SessionAdminAPI.messageLimit { text = String(v.prefix(SessionAdminAPI.messageLimit)) } }
            HStack {
                Text("\(text.count)/\(SessionAdminAPI.messageLimit)").cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary)
                Spacer()
                Button("Cancel") { messageOpen = false }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                Button("Send") { send() }.buttonStyle(AboutButton(primary: true, accentName: accentName))
                    .disabled(busy || SessionAdminAPI.clampMessage(text).isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 340).preferredColorScheme(.dark)
    }

    private var confirmForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign out \(s.DeviceName ?? "this device")?").cvFont(13, weight: .bold).foregroundColor(.white)
            Text("This signs the device out. Playback stops and it has to sign in again.")
                .cvFont(12).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmOpen = false }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                Button("Sign out") { signOut() }.buttonStyle(GlassButtonStyle(.destructive)).disabled(busy)
            }
        }
        .padding(14).frame(width: 320).preferredColorScheme(.dark)
    }

    private func run(_ r: AdminRequest) async -> Int { await emby.adminCall(r.method, r.path, body: r.body).1 }

    private func flash(_ t: String) {
        withAnimation { note = t }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); withAnimation { note = nil } }
    }

    private func send() {
        busy = true
        Task {
            let st = await run(SessionAdminAPI.message(s.Id, text: text))
            busy = false; messageOpen = false
            flash(AdminMessage.text(status: st, action: "send the message") == nil ? "Message sent" : "Couldn't send")
            if (200..<300).contains(st) { text = "" }
        }
    }

    private func stop() {
        Task {
            let st = await run(SessionAdminAPI.stop(s.Id))
            flash((200..<300).contains(st) ? "Stopped" : "Couldn't stop")
        }
    }

    private func signOut() {
        guard admin, let devId = s.DeviceId, devId != emby.deviceId else { return }
        busy = true
        Task {
            _ = await run(SessionAdminAPI.stop(s.Id))
            var target: String?
            if case let (d?, 200) = await emby.adminCall("GET", DeviceAdminAPI.list.path), let list = AdminDevice.decodeList(d) {
                target = SessionAdminAPI.device(for: devId, in: list)?.id
            }
            var st = 404
            if let target { st = await run(DeviceAdminAPI.remove(target, kind: kind)) }
            busy = false; confirmOpen = false
            flash((200..<300).contains(st) ? "Signed out" : "Couldn't sign out")
        }
    }
}
