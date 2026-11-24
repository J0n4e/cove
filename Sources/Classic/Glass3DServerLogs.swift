import AppKit
import SwiftUI

// MARK: - Logs tab: server log files (viewer) and the activity log

struct ServerLogsTab: View {
    @StateObject private var model: ServerLogsModel
    @AppStorage("accent") private var accentName = "red"
    @State private var section = 0          // 0 Activity, 1 Log files
    @State private var filter = AdminActivity.Filter.all.rawValue

    init(admin: ServerAdmin) { _model = StateObject(wrappedValue: ServerLogsModel(kind: admin.kind, api: admin.api)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            if model.open != nil {
                ServerLogViewer(model: model)
            } else {
                HStack {
                    GlassPicker(selection: $section, options: [(0, "Activity"), (1, "Log files")])
                    if section == 0 {
                        GlassPicker(selection: $filter, options: AdminActivity.Filter.allCases.map { ($0.rawValue, $0.title) })
                    }
                    Spacer()
                    Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(AboutButton(accentName: accentName))
                }
                if !model.loaded {
                    SkeletonShimmer(rows: 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if section == 0 { activityList } else { fileList }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
    }

    @ViewBuilder var activityList: some View {
        let items = AdminActivity.filter(model.activity, AdminActivity.Filter(rawValue: filter) ?? .all)
        if let e = model.activityError, model.activity.isEmpty {
            ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
        } else if items.isEmpty {
            ServerAdminNotice(icon: "list.bullet.rectangle", text: "Nothing here.")
        } else {
            ScrollView {
                LazyVStack(spacing: Glass3DTokens.Space.s) {
                    ForEach(items) { a in
                        HStack(alignment: .top, spacing: Glass3DTokens.Space.m) {
                            Image(systemName: a.icon).cvFont(14).foregroundColor(color(a.severity)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(2)
                                if let o = a.overview { Text(o).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(2) }
                            }
                            Spacer()
                            if let d = a.date { Text(ServerAdminDate.relative(d)).cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary).help(d.formatted()) }
                        }
                        .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.s)
                        .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous).fill(Color.white.opacity(0.06)))
                    }
                }.padding(.bottom, Glass3DTokens.Space.s)
            }.scrollIndicators(.never)
        }
    }

    func color(_ s: AdminActivity.Severity) -> Color {
        switch s { case .error: return .red; case .warning: return .orange; case .info: return Glass3DTokens.Grey.secondary }
    }

    @ViewBuilder var fileList: some View {
        if let e = model.error, model.files.isEmpty {
            ServerAdminNotice(icon: "exclamationmark.triangle", text: e)
        } else {
            ScrollView {
                LazyVStack(spacing: Glass3DTokens.Space.s) {
                    ForEach(model.files) { f in
                        Button { Task { await model.openFile(f) } } label: {
                            HStack(spacing: Glass3DTokens.Space.m) {
                                Image(systemName: "doc.text").cvFont(14).foregroundStyle(.tint).frame(width: 22)
                                Text(f.name).cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(f.sizeText).cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
                                if let d = f.modified { Text(ServerAdminDate.relative(d)).cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary) }
                                Image(systemName: "chevron.right").cvFont(11).foregroundColor(Glass3DTokens.Grey.tertiary)
                            }
                            .padding(.horizontal, Glass3DTokens.Space.m).padding(.vertical, Glass3DTokens.Space.m)
                            .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous).fill(Color.white.opacity(0.06)))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plainHand)
                    }
                }.padding(.bottom, Glass3DTokens.Space.s)
            }.scrollIndicators(.never)
        }
    }
}

/// One log file: the last 2000 lines, search with highlight, level chips, save to Downloads, copy.
struct ServerLogViewer: View {
    @ObservedObject var model: ServerLogsModel
    @AppStorage("accent") private var accentName = "red"
    @State private var query = ""
    @State private var levels: Set<LogLevel> = []
    @State private var note: String?

    var body: some View {
        let shown = LogAdminAPI.filter(model.lines, levels: levels, query: query)
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
            HStack(spacing: Glass3DTokens.Space.s) {
                Button { model.open = nil } label: { Label("Logs", systemImage: "chevron.left") }
                    .buttonStyle(AboutButton(accentName: accentName))
                Text(model.open?.name ?? "").cvFont(13, weight: .semibold).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { save() } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(AboutButton(accentName: accentName)).disabled(model.raw.isEmpty)
                    .help("Saves the log to Downloads and shows it in Finder")
                Button { copy(shown) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(AboutButton(accentName: accentName)).disabled(shown.isEmpty)
                    .help("Copies the lines shown (select text in the viewer to copy part of it)")
            }
            HStack(spacing: Glass3DTokens.Space.s) {
                ServerSearchField(placeholder: "Search the log", text: $query)
                if LogAdminAPI.hasLevels(model.lines) {
                    ForEach([LogLevel.error, .warn, .info], id: \.self) { l in
                        Button { if levels.contains(l) { levels.remove(l) } else { levels.insert(l) } } label: {
                            Text(l.rawValue).cvFont(11, weight: .semibold).foregroundColor(.white)
                                .padding(.horizontal, Glass3DTokens.Space.m).frame(height: 24)
                                .background(Capsule().fill(levels.contains(l) ? levelColor(l).opacity(0.5) : Color.white.opacity(0.08)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        }.buttonStyle(.plainHand)
                    }
                }
                Spacer()
                Text(note ?? "\(shown.count) of \(model.lines.count) lines").cvFont(11).foregroundColor(Glass3DTokens.Grey.secondary)
            }
            if model.loadingFile {
                SkeletonShimmer(rows: 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(attributed(shown))
                        .coveFont(size: 11, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(Glass3DTokens.Space.m)
                }
                .background(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.field, style: .continuous).fill(Color.black.opacity(0.35)))
            }
        }
    }

    func levelColor(_ l: LogLevel) -> Color {
        switch l { case .error: return .red; case .warn: return .orange; case .info: return .blue; case .debug: return .gray }
    }

    func attributed(_ lines: [LogLine]) -> AttributedString {
        var out = AttributedString()
        let q = query.trimmingCharacters(in: .whitespaces)
        for (i, l) in lines.enumerated() {
            var a = AttributedString(l.text + (i == lines.count - 1 ? "" : "\n"))
            a.foregroundColor = l.level == .error ? Glass3DTokens.Status.danger.opacity(0.95) : (l.level == .warn ? Glass3DTokens.Status.warning : Color.white.opacity(0.85))
            if !q.isEmpty {
                var from = a.startIndex
                while from < a.endIndex, let r = a[from...].range(of: q, options: .caseInsensitive) {
                    a[r].backgroundColor = Theme.accent(accentName).opacity(0.55)
                    a[r].foregroundColor = Color.white
                    from = r.upperBound
                }
            }
            out.append(a)
        }
        return out
    }

    func copy(_ lines: [LogLine]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
        note = "Copied \(lines.count) lines"
    }

    func save() {
        guard let f = model.open,
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent(LogAdminAPI.downloadName(f.name))
        do {
            try model.raw.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            note = "Saved to Downloads"
        } catch { note = "Couldn't save to Downloads" }
    }
}
