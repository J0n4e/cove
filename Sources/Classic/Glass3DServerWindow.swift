import AppKit
import SwiftUI

/// "Manage server…" (profile menu, admins only): a glass window like Settings, titled with the server's name,
/// with the tabs Overview · Tasks. One at a time; opening again brings it to the front (a new server → new model).
@MainActor
final class ServerAdminWindow: NSObject, NSWindowDelegate {
    static let shared = ServerAdminWindow()
    static let size = NSSize(width: 860, height: 620)
    private var window: NSWindow?
    private var server = ""

    static func show(emby: Emby, tab: Int? = nil) {
        if let tab { ServerAdminNav.shared.tab = tab }
        shared.show(emby: emby)
    }
    static func close() { shared.window?.close() }

    private func show(emby: Emby) {
        if window != nil && server != emby.server { window?.close(); window = nil }
        if window == nil {
            server = emby.server
            let title = emby.currentServerName
            let root = ServerAdminRoot(model: ServerAdmin.live(emby), title: title).environmentObject(emby)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []   // fixed size; never let SwiftUI layout drive the window frame
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            CoveWindowLook.applyGlass(w, content: host, size: Self.size)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.delegate = self
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ServerAdminNav.shared.tab = 0
        // Drop the model so its polling stops and the next open starts fresh
        window = nil
    }
}

/// The selected tab (a server alert's click opens the window on its tab).
@MainActor
final class ServerAdminNav: ObservableObject {
    static let shared = ServerAdminNav()
    @Published var tab = 0
}

struct ServerAdminRoot: View {
    @StateObject var model: ServerAdmin
    let title: String
    @AppStorage("bg") private var bgName = "black"
    @AppStorage("accent") private var accentName = "red"
    @ObservedObject private var nav = ServerAdminNav.shared

    init(model: ServerAdmin, title: String) {
        _model = StateObject(wrappedValue: model)
        self.title = title
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).cvFont(Glass3DTokens.Text.section, weight: .bold).foregroundColor(.white).lineLimit(1)
                        Text("Manage server").cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                    Spacer()
                    if !model.forbidden {
                        Glass3DSegmentTabs(titles: ServerAdmin.Tab.allCases.map(\.title), selection: $nav.tab)
                    }
                }
                if model.forbidden {
                    ServerAdminNotice(icon: "lock", text: "You need to be an administrator to manage this server.")
                } else {
                    switch ServerAdmin.Tab(rawValue: nav.tab) ?? .overview {
                    case .overview: ServerOverviewTab(model: model)
                    case .tasks: ServerTasksTab(model: model)
                    case .users: ServerUsersTab(admin: model)
                    case .libraries: ServerLibrariesTab(admin: model)
                    case .devices: ServerDevicesTabHost(admin: model)
                    case .plugins: ServerPluginsTab(admin: model)
                    case .logs: ServerLogsTab(admin: model)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let m = model.message { ServerAdminToast(text: m) { model.message = nil } }
        }
        .task { await model.checkAdmin() }
        .environment(\.appBG, Theme.bg(bgName))
        .tint(Theme.accent(accentName))
        .frame(width: ServerAdminWindow.size.width, height: ServerAdminWindow.size.height)
        .dropdownLayer()
        .preferredColorScheme(.dark).focusEffectDisabled()
    }
}

// MARK: - Building blocks

/// A glass card on the window's glass (the Settings card look).
struct ServerAdminCard<C: View>: View {
    var title: String? = nil
    @ViewBuilder var content: C
    var body: some View {
        let r = Glass3DTokens.Radius.panel
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).cvFont(11, weight: .semibold).kerning(0.6).foregroundColor(Glass3DTokens.Grey.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
    }
}

/// The red pill for restart / shut down.
struct ServerDangerButton: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.cvFont(13, weight: .semibold).lineLimit(1).fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(c.isPressed ? 0.6 : 0.8)))
            .contentShape(Rectangle())
    }
}

struct ServerAdminNotice: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).cvFont(28).foregroundColor(Glass3DTokens.Grey.secondary)
            Text(text).cvFont(14).foregroundColor(Glass3DTokens.Grey.primary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServerAdminToast: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        VStack {
            Spacer()
            Text(text).cvFont(13, weight: .semibold).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .modifier(PanelSurface(classic: true))
                .padding(.bottom, 22)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            dismiss()
        }
    }
}

struct ServerMetaLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).cvFont(12).foregroundColor(Glass3DTokens.Grey.tertiary).frame(width: 110, alignment: .leading)
            Text(value).cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// A thin accent progress bar (0…100).
struct ServerProgressBar: View {
    let percent: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(.tint).frame(width: max(4, g.size.width * CGFloat(percent / 100)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.4), value: percent)
    }
}
