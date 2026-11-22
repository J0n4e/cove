import SwiftUI
import AppKit

// Glass3D in-app notifications: the Activity → Notifications tab (glass cards grouped Today / Yesterday / Earlier,
// Play / Open / ✕, Mark all as read, Clear all) and Cove's own glass toast while Cove is in front. The list and
// the toast share one card. Model: NotificationCenterStore / NotificationInbox.

/// The card's picture: the first candidate the server has (backdrop first, as the banner), 16:9.
struct NotificationThumb: View {
    let n: StoredNotification
    let width: CGFloat
    @State private var index = 0
    init(n: StoredNotification, width: CGFloat) {
        self.n = n; self.width = width
        Self.prepareAuth(NotificationInbox.imageServer(stored: n.server, current: ImageCache.shared.currentServer))
    }
    /// The entry's own server (it may not be the current one); old entries → the current server
    var server: String { NotificationInbox.imageServer(stored: n.server, current: ImageCache.shared.currentServer) }

    /// A picture from another saved server gets that server's saved token (its own origin only).
    static func prepareAuth(_ server: String) {
        let cur = ImageCache.shared.currentServer
        guard !server.isEmpty, server.lowercased() != cur.lowercased() else { return }
        let h = NotificationInbox.otherServerHeaders(server: server, current: cur,
                                                     tokens: ServerStore.sealedTokens(.standard) ?? [:])
        if !h.isEmpty { ImageCache.shared.setOtherServerAuth(server: server, headers: h) }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.thumb, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.06))
            if index < n.images.count {
                CachedImage(url: NotificationInbox.imageURL(server: server, n.images[index])) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                    else if case .failure = phase { Color.clear.onAppear { index += 1 } }
                    else { Color.clear }
                }
                .id(index)
            } else {
                Image(systemName: n.target["kind"] == "server" ? (n.target["symbol"] ?? "server.rack") : (n.playId == nil ? "rectangle.stack" : "film")).cvFont(width * 0.18, weight: .light)
                    .foregroundColor(Glass3DTokens.Grey.tertiary)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.5))
    }
}

/// A small action pill inside a card (Play, Open, Show all).
struct NotificationActionButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).cvFont(11, weight: .bold) }
                Text(title).cvFont(12, weight: .semibold)
            }
            .padding(.horizontal, 12).frame(height: 26)
            .classicGlassPill()   // the Glass3D pill with the chosen hover effect
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHand)
    }
}

/// One notification: picture left, bold title, detail line, relative time, unread dot, Play / Open / ✕.
struct NotificationCard: View {
    let n: StoredNotification
    /// The toast: a bigger picture and a "Show all" link
    var toast = false
    var onClose: (() -> Void)? = nil
    @ObservedObject private var store = NotificationCenterStore.shared
    @AppStorage("accent") private var accentName = "red"
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass3DTokens.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: 14) {
            NotificationThumb(n: n, width: toast ? 176 : 120)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !n.read { Circle().fill(Theme.accent(accentName)).frame(width: 7, height: 7).helpLabel("Unread") }
                    Text(n.cardTitle).cvFont(Glass3DTokens.Text.cardTitle, weight: .bold).lineLimit(1)
                        .modifier(Glass3DReadableText())
                    Spacer(minLength: 4)
                    Button { if let onClose { onClose() } else { store.remove(n.id) } } label: {
                        Image(systemName: "xmark").cvFont(11, weight: .bold).foregroundColor(Glass3DTokens.Grey.secondary)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }.buttonStyle(.plainHand).helpLabel(toast ? "Close" : "Remove")
                }
                Text(n.cardDetail).cvFont(Glass3DTokens.Text.meta + 1).foregroundColor(Color.white.opacity(0.88))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    Text(NotificationInbox.relativeTime(n.date, now: ctx.date)).cvFont(Glass3DTokens.Text.meta - 1)
                        .foregroundColor(Glass3DTokens.Grey.secondary)
                }
                HStack(spacing: 8) {
                    if n.playId != nil {
                        NotificationActionButton(title: "Play", icon: "play.fill") { Task { await NewMediaService.shared.playStored(n) } }
                    }
                    NotificationActionButton(title: "Open") { Task { await NewMediaService.shared.openStored(n) } }
                    if toast {
                        Spacer(minLength: 4)
                        Button {
                            store.toast = nil
                            ClassicNavState.shared.query = ""; ClassicNavState.shared.searchOpen = false
                            ClassicNavState.shared.sel = "nowplaying"; ClassicNavState.shared.popToRoot()
                            store.requestShowList()
                        } label: {
                            Text("Show all").cvFont(12, weight: .semibold).underline(hover).foregroundColor(Glass3DTokens.Grey.primary)
                        }.buttonStyle(.plainHand)
                    }
                }.padding(.top, 4)
            }
        }
        .padding(12)
        .background(shape.fill(Color.white.opacity(hover && !toast ? Glass3DTokens.Fill.strong : Glass3DTokens.Fill.subtle)))
        .background(shape.fill(.ultraThinMaterial).opacity(toast ? 0.9 : 0.5))
        .overlay(shape.strokeBorder(Color.white.opacity(Glass3DTokens.Stroke.subtle), lineWidth: 0.75))
        .contentShape(shape)
        .onHover { h in withAnimation(Glass3DTokens.Motion.fast) { hover = h } }
        // A click on the card itself: opens it (marks it read), as the banner
        .onTapGesture { Task { await NewMediaService.shared.openStored(n) } }
    }
}

/// Activity → Notifications.
struct NotificationsTabView: View {
    @ObservedObject private var store = NotificationCenterStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Spacer()
                if store.unread > 0 { NotificationActionButton(title: "Mark all as read", icon: "checkmark") { store.markAllRead() } }
                if !store.items.isEmpty {
                    Button { store.clearAll() } label: {
                        Text("Clear all").cvFont(11, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
                    }.buttonStyle(.plainHand)
                }
            }
            if store.items.isEmpty {
                StatsStateCard(symbol: "bell", title: "No notifications yet",
                               message: "New movies and episodes on your server show up here.")
            } else {
                let groups = NotificationInbox.grouped(store.items, now: Date())
                ForEach(groups, id: \.section.rawValue) { g in
                    StatsHeading(text: g.section.rawValue).padding(.top, 4)
                    LazyVStack(spacing: 10) {
                        ForEach(g.items) { NotificationCard(n: $0) }
                    }
                    .frame(maxWidth: 860)
                }
            }
        }
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
    }
}

/// Cove's own toast (top right, under the top bar) for ~6 s; a click outside or ✕ closes it.
struct NotificationToastLayer: View {
    @ObservedObject private var store = NotificationCenterStore.shared
    @ObservedObject private var playback = PlaybackFlag.shared
    @State private var hovering = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let t = store.toast, !playback.active {
                // Click outside: closes the toast (a clear layer only while it is shown)
                Color.black.opacity(0.001).ignoresSafeArea()
                    .onTapGesture { store.toast = nil }
                NotificationCard(n: t, toast: true, onClose: { store.toast = nil })
                    .frame(width: 440)
                    .shadow(color: .black.opacity(Glass3DTokens.shadowLarge.opacity), radius: Glass3DTokens.shadowLarge.radius,
                            y: Glass3DTokens.shadowLarge.y)
                    .padding(.top, 76).padding(.trailing, 24)
                    .onHover { hovering = $0 }
                    .transition(.coveGlassPopIn)
                    .id(t.id)
                    .task(id: t.id) {
                        try? await Task.sleep(for: .seconds(6))
                        while hovering && !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
                        if store.toast?.id == t.id { store.toast = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .coveGlassPopIn(value: store.toast?.id)
    }
}

/// The Activity tab's label: "Notifications 3" while some are unread.
enum NotificationTabLabel {
    /// The red badge on the Notifications tab, like the Dock's: nil when nothing is unread, "99+" above 99.
    static func badgeText(unread: Int) -> String? { unread <= 0 ? nil : unread > 99 ? "99+" : "\(unread)" }
    static func text(unread: Int) -> String { unread > 0 ? "Notifications \(unread)" : "Notifications" }
}

/// The small red dot on the Activity item (top bar and sidebar) while notifications are unread; separate from
/// the active-sessions number.
struct ActivityUnreadDot: ViewModifier {
    @ObservedObject private var store = NotificationCenterStore.shared
    var inset: CGFloat = 2
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if store.unread > 0 {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                    .padding(inset).allowsHitTesting(false)
                    .help(NotificationTabLabel.unreadHelp(store.unread))
            }
        }
    }
}

extension NotificationTabLabel {
    static func unreadHelp(_ n: Int) -> String { n == 1 ? "1 unread notification" : "\(n) unread notifications" }
}

/// Activity's tabs: Now Playing · Notifications (every user) · Overview · History, then Users · Graphs · Libraries
/// (admins with the Playback Reporting plugin).
enum ActivityTabs {
    static let notifications = 1
    static let insights = 7
    /// Cleanup (admins only, no plugin needed) sits after the stats tabs, right before Year in review.
    static func titles(unread: Int, stats: Bool, admin: Bool = false) -> [String] {
        ["Now Playing", "Notifications", "Overview", "History"]   // the unread count is a Dock-style badge (badgeText)
            + (stats ? ["Users", "Graphs", "Libraries", "Insights"] : []) + (admin ? ["Cleanup"] : []) + ["Year in review"]
    }
    /// The Cleanup tab's index, nil when it isn't shown.
    static func cleanup(stats: Bool, admin: Bool) -> Int? { admin ? (stats ? 8 : 4) : nil }
    /// Year in review is the last tab for everyone (after the admin tabs when they show).
    static func yearInReview(stats: Bool, admin: Bool = false) -> Int { (stats ? 8 : 4) + (admin ? 1 : 0) }
}

/// The toast's "Show all": Activity switches to its Notifications tab (also when the page is only now opening).
struct ActivityShowNotifications: ViewModifier {
    @Binding var tab: Int
    @ObservedObject private var store = NotificationCenterStore.shared
    func body(content: Content) -> some View {
        content
            .onAppear { take() }
            .onChange(of: store.showListTick) { take() }
    }
    private func take() {
        guard store.showListPending else { return }
        store.showListPending = false
        tab = ActivityTabs.notifications
    }
}
