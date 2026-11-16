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
    enum Field { case name, server, user, pw }

    var showForm: Bool { adding || emby.servers.isEmpty }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                if showForm { form } else { serverList }
                if !error.isEmpty { Text(error).foregroundColor(.orange).font(.cv(10, weight: .regular)).multilineTextAlignment(.center) }
            }
            .frame(width: showForm ? 340 : 520).padding(36)
            .modifier(PanelSurface(classic: true))   // dark glass, as the player panels
        }
    }

    var serverList: some View {
        VStack(spacing: 14) {
            Text("Select Server").font(.cv(22, weight: .bold)).padding(.bottom, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(emby.servers) { s in serverCard(s) }
                Button { startAdd() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus").font(.cv(34, weight: .light))
                            .frame(width: 150, height: 100)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                        Text("Add Server").font(.cv(13, weight: .bold))
                        Text(" ").font(.cv(10, weight: .regular))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plainHand)
            }
            if busy { Spinner().controlSize(.small) }
        }
    }

    func serverCard(_ s: SavedServer) -> some View {
        Button { open(s) } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "server.rack").font(.cv(38))
                        .frame(width: 150, height: 100)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.3)))
                        .background(ClassicGlassBacking(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                    if s.token != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(6)
                            .helpLabel("Signed in")
                    }
                }
                HStack(spacing: 5) { ConnectionBadge(address: s.url).font(.cv(10, weight: .regular)); Text(s.name).font(.cv(13, weight: .bold)).lineLimit(1) }
                Text((s.user.isEmpty ? s.url : "\(s.user) · \(s.url)") + " · " + emby.kindLabel(s))
                    .font(.cv(10, weight: .regular)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 150).contentShape(Rectangle())
        }
        .buttonStyle(HoverButton()).disabled(busy)
        .contextMenu {
            Button("Edit / Sign In Again") { edit(s) }
            Button("Remove Server", role: .destructive) { emby.removeServer(s) }
        }
    }

    var form: some View {
        VStack(spacing: 14) {
            HStack {
                if !emby.servers.isEmpty {
                    Button { adding = false; error = "" } label: { Label("Back", systemImage: "chevron.left").classicGlassPill(size: 34) }
                        .buttonStyle(HoverButton()).helpLabel("Back to servers")
                }
                Spacer()
                Text(emby.servers.isEmpty ? "Sign In" : "Add Server").font(.cv(22, weight: .bold))
                Spacer()
                if !emby.servers.isEmpty { Color.clear.frame(width: 34, height: 34) }
            }.padding(.bottom, 6)
            TextField("Name (optional, e.g. Home Jellyfin)", text: $serverLabel).focused($focus, equals: .name)
                .onSubmit { focus = .server }.modifier(GlassField())
            TextField("Server (e.g. 192.168.1.10:8096)", text: $server).focused($focus, equals: .server)
                .onSubmit { focus = .user }.modifier(GlassField())
            TextField("Username", text: $user).focused($focus, equals: .user).onSubmit { focus = .pw }.modifier(GlassField())
            SecureField("Password", text: $pw).focused($focus, equals: .pw).onSubmit(go).modifier(GlassField())
            Button(action: go) {
                HStack {
                    if busy { Spinner().controlSize(.small) }
                    Text("Sign In").font(.cv(14, weight: .bold))
                }.frame(maxWidth: .infinity).frame(height: 40).classicGlassPill()
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
        content.textFieldStyle(.plain).font(.cv(13)).foregroundColor(.white)
            .padding(.horizontal, 16).frame(height: 38)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .background(ClassicGlassBacking(shape: Capsule()))
    }
}
