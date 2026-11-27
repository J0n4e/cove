import IOKit.pwr_mgt
import SwiftUI
import AVKit

struct ClassicLoginView: View {
    @EnvironmentObject var emby: Emby
    @State private var adding = false
    @State private var server = ""
    @State private var serverLabel = ""   // optional name shown in the server list
    @State private var user = ""
    @State private var pw = ""
    @State private var error = ""
    @State private var busy = false
    @FocusState private var focus: Field?
    @Environment(\.appBG) private var bg
    enum Field { case name, server, user, pw }

    var showForm: Bool { adding || emby.servers.isEmpty }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()   // Settings → General → Background, as every other page
            VStack(spacing: Glass3DTokens.Space.l) {
                if showForm { form } else { serverList }
                if !error.isEmpty { Text(error).foregroundColor(Glass3DTokens.Status.warning).cvFont(10, weight: .regular).multilineTextAlignment(.center) }
            }
            .frame(width: showForm ? 340 : 520).padding(36)
            .modifier(PanelSurface(classic: true))   // dark glass, as the player panels
        }
        .onAppear { if let p = ProfileJump.shared.takePrefill() { server = p.url; serverLabel = p.name; user = ""; pw = ""; error = ""; adding = true } }
    }

    var serverList: some View {
        VStack(spacing: Glass3DTokens.Space.l) {
            Text("Select Server").cvFont(22, weight: .bold).padding(.bottom, Glass3DTokens.Space.s)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Glass3DTokens.Space.l)], spacing: Glass3DTokens.Space.l) {
                ForEach(emby.servers) { s in serverCard(s) }
                Button { startAdd() } label: {
                    VStack(spacing: Glass3DTokens.Space.m) {
                        Image(systemName: "plus").cvFont(34, weight: .light)
                            .frame(width: 150, height: 100)
                            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                        Text("Add Server").cvFont(13, weight: .bold)
                        Text(" ").cvFont(10, weight: .regular)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plainHand)
            }
            if busy { Spinner().controlSize(.small) }
        }
    }

    func serverCard(_ s: SavedServer) -> some View {
        LoginServerCard(s: s, busy: busy, kind: emby.kindLabel(s),
                        open: { open(s) }, edit: { edit(s) }, remove: { emby.removeServer(s) })
    }

    var form: some View {
        VStack(spacing: Glass3DTokens.Space.l) {
            HStack {
                if !emby.servers.isEmpty {
                    Button { adding = false; error = "" } label: { Label("Back", systemImage: "chevron.left").classicGlassPill(size: 34) }
                        .buttonStyle(HoverButton()).helpLabel("Back to servers")
                }
                Spacer()
                Text(emby.servers.isEmpty ? "Sign In" : "Add Server").cvFont(22, weight: .bold)
                Spacer()
                if !emby.servers.isEmpty { Color.clear.frame(width: 34, height: 34) }
            }.padding(.bottom, Glass3DTokens.Space.s)
            TextField("Name (optional, e.g. Home Jellyfin)", text: $serverLabel).focused($focus, equals: .name)
                .onSubmit { focus = .server }.modifier(GlassField())
            TextField("Server (e.g. 192.168.1.10:8096)", text: $server).focused($focus, equals: .server)
                .onSubmit { focus = .user }.modifier(GlassField())
            TextField("Username", text: $user).focused($focus, equals: .user).onSubmit { focus = .pw }.modifier(GlassField())
            SecureField("Password", text: $pw).focused($focus, equals: .pw).onSubmit(go).modifier(GlassField())
            Button(action: go) {
                HStack {
                    if busy { Spinner().controlSize(.small) }
                    Text("Sign In").cvFont(14, weight: .bold)
                }.frame(maxWidth: .infinity).frame(height: 40).classicPrimaryPill()   // Glass3D's primary pill
            }.buttonStyle(HoverButton()).disabled(busy || server.isEmpty || user.isEmpty)
            .opacity(busy || server.isEmpty || user.isEmpty ? 0.5 : 1)
        }
        .onAppear { focus = server.isEmpty ? .server : .pw }
    }

    func startAdd() { server = ""; user = ""; pw = ""; error = ""; adding = true }

    func edit(_ s: SavedServer) { server = s.url; serverLabel = s.name; user = s.user; pw = ""; error = ""; adding = true; focus = .pw }

    func open(_ s: SavedServer) {
        error = ""
        guard s.token != nil else { edit(s); return }
        busy = true
        Task {
            let result = await emby.resume(s)
            busy = false
            switch result {
            case .ok: break
            case .expired: edit(s); error = "Session expired. Enter your password to sign in again."
            case .unreachable: error = "Couldn't reach \(s.name). Check that the server is running and try again."
            }
        }
    }

    func go() {
        guard !busy else { return }
        busy = true; error = ""
        Task {
            // https when the server has it; warn before a password goes out unencrypted over the internet
            let address = await Emby.resolveAddress(server)
            if ConnectionSecurity.kind(address) == .remotePlain, !ConnectionSecurity.confirmPlainHTTP(address) { busy = false; return }
            do { try await emby.login(server: address, user: user, pw: pw, name: serverLabel); pw = ""; adding = false }
            catch { self.error = (error as? LoginError)?.errorDescription ?? Emby.describe(error) }
            busy = false
        }
    }
}

/// A text field as a glass capsule (sign-in form).
struct GlassField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).cvFont(13).foregroundColor(.white)
            .padding(.horizontal, Glass3DTokens.Space.l).frame(height: 38)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .background(ClassicGlassBacking(shape: Capsule()))
            .focusGlowField(in: Capsule())   // accent ring while typing in it
    }
}


/// One saved server on the sign-in screen. The hover look follows the card's own rounded square (owner: the round
/// pill hover looked off on a square card), and a ✕ on hover removes the server after a confirmation (owner: make
/// removing a server easy; right-click → Remove Server still works).
struct LoginServerCard: View {
    let s: SavedServer
    let busy: Bool
    let kind: String
    let open: () -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var hover = false
    @State private var confirm = false
    private var tileShape: RoundedRectangle { RoundedRectangle(cornerRadius: Glass3DTokens.Radius.panel, style: .continuous) }

    var body: some View {
        Button(action: open) {
            VStack(spacing: Glass3DTokens.Space.m) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "server.rack").cvFont(38)
                        .frame(width: 150, height: 100)
                        .background(tileShape.fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: tileShape))
                        .modifier(PillHoverEffect(hover: hover, pressed: false, shape: tileShape))
                    if s.token != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(Glass3DTokens.Space.s)
                            .helpLabel("Signed in")
                    }
                }
                HStack(spacing: Glass3DTokens.Space.xs) { ConnectionBadge(address: s.url).cvFont(10, weight: .regular); Text(s.name).cvFont(13, weight: .bold).lineLimit(1) }
                Text((s.user.isEmpty ? s.url : "\(s.user) · \(s.url)") + " · " + kind)
                    .cvFont(10, weight: .regular).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 150).contentShape(Rectangle())
        }
        .buttonStyle(.plainHand).disabled(busy)
        .overlay(alignment: .topLeading) {
            if hover && !busy {
                Button { confirm = true } label: {
                    Image(systemName: "xmark.circle.fill").cvFont(20)
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.6))
                        .padding(Glass3DTokens.Space.xs)
                }
                .buttonStyle(.plainHand).helpLabel("Remove server")
                .transition(.opacity)
            }
        }
        .onHover { hover = $0 }
        .animation(Glass3DTokens.Motion.fast, value: hover)
        .contextMenu {
            Button("Edit / Sign In Again", action: edit)
            Button("Remove Server", role: .destructive) { confirm = true }
        }
        .confirmationDialog("Remove \(s.name)?", isPresented: $confirm) {
            Button("Remove Server", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cove forgets this server and its sign-in. Nothing on the server is changed.")
        }
    }
}
