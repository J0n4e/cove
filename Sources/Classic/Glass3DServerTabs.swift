import AppKit
import SwiftUI

// MARK: - Overview

struct ServerOverviewTab: View {
    @ObservedObject var model: ServerAdmin
    @AppStorage("accent") private var accentName = "red"
    @State private var confirm: Confirm?

    enum Confirm: Equatable { case restart, shutdown }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let i = model.info { infoCard(i) }
                    else if let e = model.infoError { ServerAdminCard { Text(e).cvFont(13).foregroundColor(.red) } }
                    else { ServerAdminCard { ProgressView().controlSize(.small) } }
                    streamsCard
                    powerCard
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            if let c = confirm { confirmSheet(c) }
        }
        .task { await model.loadOverview() }
    }

    func infoCard(_ i: ServerAdminInfo) -> some View {
        ServerAdminCard(title: "Server") {
            Text(i.name.isEmpty ? "Server" : i.name).cvFont(Glass3DTokens.Text.cardTitle + 2, weight: .bold).foregroundColor(.white)
            Text([i.product + (i.version.isEmpty ? "" : " " + i.version), i.os].filter { !$0.isEmpty }.joined(separator: " · "))
                .cvFont(13).foregroundColor(Glass3DTokens.Grey.primary)
            HStack(spacing: 8) {
                if let u = i.updateLine { tag(u, icon: "arrow.down.circle.fill", color: .green) }
                if i.restartPending { tag("Restart pending", icon: "arrow.clockwise.circle.fill", color: .orange) }
                if let s = i.startTime { tag("Up since " + ServerAdminDate.relative(s), icon: "clock", color: .gray) }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let a = i.localAddress { ServerMetaLine(label: "Local address", value: a) }
                if let a = i.wanAddress { ServerMetaLine(label: "Remote address", value: a) }
                if let p = i.cachePath { ServerMetaLine(label: "Cache", value: p) }
                if let p = i.transcodePath { ServerMetaLine(label: "Transcoding", value: p) }
                if let p = i.logPath { ServerMetaLine(label: "Logs", value: p) }
            }.padding(.top, 4)
        }
    }

    func tag(_ t: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).cvFont(11).foregroundColor(color)
            Text(t).cvFont(12, weight: .semibold).foregroundColor(.white)
        }
        .padding(.horizontal, 9).frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
    }

    var streamsCard: some View {
        ServerAdminCard(title: "Activity") {
            HStack {
                Image(systemName: "play.tv").cvFont(14).foregroundStyle(.tint)
                Text(model.streams.map { $0 == 1 ? "1 active stream" : "\($0) active streams" } ?? "Active streams unknown")
                    .cvFont(13).foregroundColor(.white)
                Spacer()
                Button("Open Activity") { openActivity() }.buttonStyle(AboutButton(accentName: accentName))
            }
        }
    }

    var powerCard: some View {
        ServerAdminCard(title: "Actions") {
            HStack(spacing: 10) {
                Button { Task { await model.scanAll() } } label: { Label("Scan all libraries", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(AboutButton(accentName: accentName))
                Spacer()
                Button { confirm = .restart } label: { Label("Restart server", systemImage: "arrow.clockwise") }
                    .buttonStyle(AboutButton(accentName: accentName)).disabled(busy)
                Button { confirm = .shutdown } label: { Label("Shut down server", systemImage: "power") }
                    .buttonStyle(ServerDangerButton()).disabled(busy)
            }
            powerStatus
        }
    }

    var busy: Bool { model.power == .restarting || model.power == .shuttingDown }

    @ViewBuilder var powerStatus: some View {
        switch model.power {
        case .none: EmptyView()
        case .restarting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Restarting… waiting for the server to come back.").cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary) }
        case .shuttingDown: Text("Shutting down…").cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary)
        case .back: Text("The server is back.").cvFont(12).foregroundColor(.green)
        case .timedOut: Text("The server hasn't come back after 3 minutes. Check it on the machine it runs on.").cvFont(12).foregroundColor(.orange)
        case .shutDown: Text("The server is shutting down. Start it again on the machine it runs on.").cvFont(12).foregroundColor(.orange)
        case .failed(let m): Text(m).cvFont(12).foregroundColor(.red)
        }
    }

    func confirmSheet(_ c: Confirm) -> some View {
        let restart = c == .restart
        let n = model.streams ?? 0
        return ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { confirm = nil }
            VStack(alignment: .leading, spacing: 12) {
                Text(restart ? "Restart the server?" : "Shut down the server?").cvFont(17, weight: .bold).foregroundColor(.white)
                Text(restart
                     ? "Everyone watching will be interrupted while the server restarts."
                     : "Everyone watching will be interrupted, and the server stays off until it's started again on its machine.")
                    .cvFont(13).foregroundColor(Glass3DTokens.Grey.primary).fixedSize(horizontal: false, vertical: true)
                Text(n == 0 ? "No one is watching right now." : (n == 1 ? "1 stream is playing right now." : "\(n) streams are playing right now."))
                    .cvFont(13, weight: .semibold).foregroundColor(n == 0 ? Glass3DTokens.Grey.secondary : .orange)
                HStack {
                    Spacer()
                    Button("Cancel") { confirm = nil }.buttonStyle(AboutButton(accentName: accentName)).keyboardShortcut(.cancelAction)
                    Button(restart ? "Restart" : "Shut Down") {
                        confirm = nil
                        Task { if restart { await model.restart() } else { await model.shutdown() } }
                    }.buttonStyle(ServerDangerButton())
                }
            }
            .padding(20).frame(width: 420)
            .modifier(PanelSurface(classic: true))
        }
    }

    func openActivity() {
        ProfileActions.open("nowplaying")
        if let w = NSApp.windows.first(where: { !($0 is PanelWindow) && $0.isVisible && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Tasks

struct ServerTasksTab: View {
    @ObservedObject var model: ServerAdmin
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").cvFont(12).foregroundColor(Glass3DTokens.Grey.secondary)
                TextField("Filter tasks", text: $query).textFieldStyle(.plain).cvFont(13).foregroundColor(.white)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Glass3DTokens.Grey.secondary) }
                        .buttonStyle(.plainHand)
                }
            }
            .padding(.horizontal, 12).frame(height: 30).frame(maxWidth: 320)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))

            if let e = model.tasksError, model.tasks.isEmpty {
                ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
            } else if !model.tasksLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let sections = ServerTaskGrouping.sections(model.tasks, query: query)
                if sections.isEmpty {
                    ServerAdminNotice(icon: "magnifyingglass", text: "No tasks match \u{201C}\(query)\u{201D}.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(sections, id: \.title) { s in
                                ServerAdminCard(title: s.title) {
                                    ForEach(Array(s.tasks.enumerated()), id: \.element.id) { i, t in
                                        if i > 0 { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5) }
                                        ServerTaskRow(task: t, model: model)
                                    }
                                }
                            }
                        }.padding(.bottom, 8)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.pollTasks() }   // cancelled when the tab goes away
    }
}

struct ServerTaskRow: View {
    let task: ServerTask
    @ObservedObject var model: ServerAdmin
    @AppStorage("accent") private var accentName = "red"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(1)
                if task.running {
                    HStack(spacing: 8) {
                        ServerProgressBar(percent: task.progress ?? 0).frame(maxWidth: 260)
                        Text(task.state == .cancelling ? "Stopping…" : "Running · \(Int(task.progress ?? 0)) %")
                            .cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                    }
                } else {
                    Text(lastLine).cvFont(11).foregroundColor(task.last?.failed == true ? .red : Glass3DTokens.Grey.secondary).lineLimit(1)
                        .help(task.last?.error ?? "")
                }
                if !task.triggers.isEmpty {
                    Text(task.triggers.joined(separator: " · ")).cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if task.running {
                Button { Task { await model.stop(task) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(AboutButton(accentName: accentName)).disabled(task.state == .cancelling)
            } else {
                Button { Task { await model.run(task) } } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(AboutButton(accentName: accentName))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(task.description)
    }

    var lastLine: String {
        guard let r = task.last, !r.status.isEmpty else { return "Never run" }
        var parts = [r.failed ? "Failed" : r.status]
        if let e = r.end { parts.append(ServerAdminDate.relative(e)) }
        if let d = r.duration { parts.append("took " + ServerAdminDate.duration(d)) }
        return parts.joined(separator: " · ")
    }
}
