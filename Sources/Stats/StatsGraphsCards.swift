import SwiftUI
import Charts

// Graphs tab cards 2, 4 and 5: the weekday × hour heatmap, the top devices and Movies vs Episodes.

// MARK: - 2. Watch time by weekday × hour

struct StatsHeatmapCard: View {
    let cells: [StatsHeatCell]
    @AppStorage("accent") private var accentName = "red"
    @State private var hovered: StatsHeatCell?

    var body: some View {
        let top = max(1, cells.map(\.seconds).max() ?? 1)
        let accent = Theme.accent(accentName)
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            StatsChartHeader(title: "When people watch", readout: hovered.map {
                "\(StatsGraphsAggregate.weekdayNames[$0.weekday]) \(String(format: "%02d:00–%02d:00", $0.hour, ($0.hour + 1) % 24)) · \(StatsAggregate.hoursText($0.seconds))"
            }, hint: "Watch time by weekday and hour (local time)")
            VStack(spacing: Glass3DTokens.Space.xs) {
                ForEach(0..<7, id: \.self) { w in
                    HStack(spacing: Glass3DTokens.Space.xs) {
                        Text(StatsGraphsAggregate.weekdayNames[w]).cvFont(10, weight: .medium)
                            .foregroundColor(StatsChartStyle.label).frame(width: 30, alignment: .leading)
                        ForEach(0..<24, id: \.self) { h in
                            let c = cells.first { $0.weekday == w && $0.hour == h } ?? StatsHeatCell(weekday: w, hour: h, seconds: 0)
                            StatsHeatSquare(color: accent, intensity: Double(c.seconds) / Double(top),
                                            selected: hovered?.id == c.id)
                                .onHover { inside in
                                    if inside { hovered = c } else if hovered?.id == c.id { hovered = nil }
                                }
                        }
                    }
                }
                HStack(spacing: Glass3DTokens.Space.xs) {
                    Color.clear.frame(width: 30, height: 1)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 3 == 0 ? "\(h)" : "").cvFont(9).foregroundColor(StatsChartStyle.label)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .statsCard()
    }
}

private struct StatsHeatSquare: View {
    let color: Color
    let intensity: Double
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: Glass3DTokens.Radius.tag, style: .continuous)
            .fill(intensity > 0 ? color.opacity(0.15 + 0.85 * min(1, intensity)) : Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: Glass3DTokens.Radius.tag, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.8 : 0), lineWidth: 1))
            .frame(maxWidth: .infinity).frame(height: 18)
            .contentShape(Rectangle())
    }
}

// MARK: - 4. Devices / clients

struct StatsDevicesCard: View {
    let rows: [StatsDeviceRow]
    @AppStorage("accent") private var accentName = "red"
    @State private var hovered: String?

    var body: some View {
        let accent = Theme.accent(accentName)
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            StatsChartHeader(title: "Top devices", readout: rows.first { $0.name == hovered }.map {
                "\($0.name) · \(StatsAggregate.hoursText($0.seconds)) · \($0.plays) \($0.plays == 1 ? "play" : "plays")"
            }, hint: "By watch time")
            if rows.isEmpty {
                Text("No device recorded").cvFont(Glass3DTokens.Text.meta).foregroundColor(Glass3DTokens.Grey.tertiary)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Hours", Double(r.seconds) / 3600), y: .value("Device", r.name))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.55), accent], startPoint: .leading, endPoint: .trailing))
                        .opacity(hovered == nil || hovered == r.name ? 1 : 0.45)
                        .cornerRadius(Glass3DTokens.Radius.tag)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine().foregroundStyle(StatsChartStyle.grid)
                        AxisValueLabel { if let h = v.as(Double.self) { Text("\(h, specifier: "%g") h") } }
                            .foregroundStyle(StatsChartStyle.label)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().foregroundStyle(StatsChartStyle.label) }
                }
                .chartPlotStyle { $0.background(Color.clear) }
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let p):
                                    guard let f = proxy.plotFrame.map({ g[$0] }) else { hovered = nil; return }
                                    hovered = proxy.value(atY: p.y - f.origin.y, as: String.self)
                                case .ended: hovered = nil
                                }
                            }
                    }
                }
                .frame(height: CGFloat(max(rows.count, 2)) * 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCard()
    }
}

// MARK: - 5. Movies vs Episodes

struct StatsKindsCard: View {
    let split: StatsKindSplit
    @AppStorage("accent") private var accentName = "red"
    @State private var angle: Double?

    private struct Slice: Identifiable { let name: String; let seconds: Int; let plays: Int; let color: Color; var id: String { name } }

    var body: some View {
        let slices = self.slices
        let hovered = angle.flatMap { a in Self.slice(at: a, in: slices) }
        VStack(alignment: .leading, spacing: Glass3DTokens.Space.m) {
            StatsHeading(text: "Movies vs Episodes")
            ZStack {
                Chart(slices) { s in
                    SectorMark(angle: .value("Watch time", Double(s.seconds)), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(Glass3DTokens.Radius.tag)
                        .foregroundStyle(s.color.opacity(hovered == nil || hovered?.id == s.id ? 0.85 : 0.35))
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $angle)
                VStack(spacing: 2) {
                    Text(hovered.map { StatsAggregate.hoursText($0.seconds) } ?? StatsAggregate.hoursText(split.totalSeconds))
                        .cvFont(17, weight: .heavy).modifier(Glass3DReadableText())
                    Text(hovered.map { "\($0.name) · \($0.plays) \($0.plays == 1 ? "play" : "plays")" } ?? "Total")
                        .cvFont(10, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary).lineLimit(1)
                }
                .allowsHitTesting(false)
            }
            .frame(height: 170)
            VStack(alignment: .leading, spacing: Glass3DTokens.Space.s) {
                ForEach(slices) { s in
                    HStack {
                        StatsLegendChip(color: s.color, text: s.name)
                        Spacer(minLength: 8)
                        Text("\(StatsAggregate.hoursText(s.seconds)) · \(percent(s.seconds))%")
                            .cvFont(Glass3DTokens.Text.meta - 1).foregroundColor(Glass3DTokens.Grey.secondary).monospacedDigit()
                    }
                }
            }
        }
        .statsCard()
    }

    private var slices: [Slice] {
        var out = [Slice(name: "Movies", seconds: split.movieSeconds, plays: split.movies, color: Theme.accent(accentName)),
                   Slice(name: "Episodes", seconds: split.episodeSeconds, plays: split.episodes, color: StatsUsersStyle.episodes)]
        if split.otherSeconds > 0 {
            out.append(Slice(name: "Other", seconds: split.otherSeconds, plays: split.others, color: Color.white.opacity(0.5)))
        }
        return out.filter { $0.seconds > 0 }
    }

    private func percent(_ s: Int) -> Int {
        split.totalSeconds > 0 ? Int((Double(s) / Double(split.totalSeconds) * 100).rounded()) : 0
    }

    /// The slice a selected angle value (cumulative seconds) falls in.
    private static func slice(at value: Double, in slices: [Slice]) -> Slice? {
        var acc = 0.0
        for s in slices {
            acc += Double(s.seconds)
            if value <= acc { return s }
        }
        return slices.last
    }
}
