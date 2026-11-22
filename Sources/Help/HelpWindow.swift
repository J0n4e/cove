import SwiftUI
import AppKit

/// Help → Cove Help (⌘?) and the profile menu's Cove Help row: one glass window like Settings and About, with a
/// searchable topic list on the left and the topic on the right. Topics: Help/HelpTopics.swift (offline).
@MainActor
enum HelpWindow {
    private static var window: NSWindow?
    static let size = NSSize(width: 900, height: 640)

    static func show() {
        if window == nil {
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            w.title = "Cove Help"
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.zoomButton)?.isHidden = true
            let host = NSHostingView(rootView: HelpView())
            host.sizingOptions = []
            // Glass + fixed dark fill, .fullScreenAuxiliary / .moveToActiveSpace: opens over a full-screen Cove
            CoveWindowLook.applyGlass(w, content: host, size: size)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @AppStorage("accent") private var accentName = "red"
    @ObservedObject private var profile = ProfileModel.shared
    @State private var query = ""
    @State private var selection: String = HelpTopics.all.first?.id ?? ""
    @FocusState private var searchFocused: Bool

    var accent: Color { Theme.accent(accentName) }
    var visible: [HelpTopic] { HelpSearch.visible(admin: profile.admin) }
    var results: [HelpTopic] { HelpSearch.filter(visible, query: query) }
    var current: HelpTopic? {
        visible.first { $0.id == selection } ?? results.first ?? visible.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: HelpWindow.size.width, height: HelpWindow.size.height)
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear { searchFocused = true }
        // Admin topics disappear when the role turns out to be "user" (or after switching user)
        .onChange(of: profile.admin) { _, _ in
            if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id ?? "" }
        }
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 14).padding(.top, 46).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(HelpGroup.allCases, id: \.self) { g in
                        let list = results.filter { $0.group == g }
                        if !list.isEmpty {
                            Text(g.rawValue.uppercased())
                                .coveFont(size: 10, weight: .semibold).kerning(0.6)
                                .foregroundColor(Color.white.opacity(0.55))
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                            ForEach(list) { t in topicRow(t) }
                        }
                    }
                    if results.isEmpty {
                        Text("No help topic matches \u{201C}\(query)\u{201D}.")
                            .coveFont(size: 12).foregroundColor(Color.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
    }

    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(Color.white.opacity(0.6))
            TextField("Search help", text: $query)
                .textFieldStyle(.plain)
                .coveFont(size: 13)
                .focused($searchFocused)
                .onSubmit { if let f = results.first { selection = f.id } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Color.white.opacity(0.5))
                }.buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    func topicRow(_ t: HelpTopic) -> some View {
        let on = current?.id == t.id
        return Button { selection = t.id } label: {
            HStack(spacing: 9) {
                Image(systemName: t.symbol)
                    .frame(width: 20)
                    .foregroundColor(on ? accent : Color.white.opacity(0.75))
                highlighted(t.title)
                    .coveFont(size: 13, weight: on ? .semibold : .regular)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Color.white.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(on ? Color.white.opacity(0.16) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder var content: some View {
        if let t = current {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: t.symbol).font(.system(size: 26)).foregroundColor(accent)
                        highlighted(t.title).coveFont(size: 26, weight: .bold).foregroundColor(.white)
                    }
                    highlighted(t.intro)
                        .coveFont(size: 14).foregroundColor(Color.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(t.sections.enumerated()), id: \.offset) { _, s in section(s) }
                }
                .glassReadable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34).padding(.top, 44).padding(.bottom, 30)
            }
            .id(t.id)   // a new topic starts at the top
            .scrollIndicators(.automatic)
        }
    }

    func section(_ s: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            highlighted(s.heading).coveFont(size: 16, weight: .semibold).foregroundColor(.white)
            ForEach(Array(s.blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
    }

    @ViewBuilder func block(_ b: HelpBlock) -> some View {
        switch b {
        case .text(let s):
            highlighted(s).coveFont(size: 13).foregroundColor(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}").coveFont(size: 13).foregroundColor(accent)
                        highlighted(item).coveFont(size: 13).foregroundColor(Color.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .keys(let keys):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 4) {
                            ForEach(Array(k.keys.enumerated()), id: \.offset) { _, key in HelpKeycap(key: key) }
                        }
                        .frame(width: 130, alignment: .trailing)
                        highlighted(k.what).coveFont(size: 13).foregroundColor(Color.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .place(let path):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "mappin.and.ellipse").foregroundColor(accent)
                Text("Where to find it:").coveFont(size: 12, weight: .semibold).foregroundColor(Color.white.opacity(0.7))
                highlighted(path).coveFont(size: 12).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    /// The text with every search word marked in the accent color.
    func highlighted(_ s: String) -> Text {
        var a = AttributedString(s)
        for r in HelpSearch.ranges(in: s, query: query) {
            if let ar = Range(r, in: a) {
                a[ar].swiftUI.backgroundColor = accent.opacity(0.45)
                a[ar].swiftUI.foregroundColor = .white
            }
        }
        return Text(a)
    }
}

/// A key drawn as a small glass capsule ("⌘", "F", "Esc").
struct HelpKeycap: View {
    let key: String
    var body: some View {
        Text(key)
            .coveFont(size: 12, weight: .semibold, design: .rounded)
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .frame(minWidth: 24)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}
