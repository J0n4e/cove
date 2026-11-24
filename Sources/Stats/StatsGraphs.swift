import SwiftUI
import Charts

/// Activity → Graphs (admins with Playback Reporting): every user's plays in the range as charts: plays per
/// day, watch time by weekday × hour, play types over time, top devices and Movies vs Episodes. Same glass cards,
/// headings and range pill as Overview / Users.
struct StatsGraphsView: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        StatsGate(model: model) {
            VStack(alignment: .leading, spacing: 20) {
                StatsRangePills(range: $model.range)
                if let g = model.graphs, model.graphsRange == model.range { StatsGraphsContent(data: g) }
                else if model.graphsLoading || model.graphs == nil { SkeletonShimmer().padding(.vertical, 30) }
                else {
                    StatsStateCard(symbol: "exclamationmark.triangle", title: "Graphs couldn't be loaded",
                                   message: "The server didn't answer. Open this tab again to retry.")
                }
            }
            .task(id: model.range) { await model.loadGraphs() }
        }
    }
}

private struct StatsGraphsContent: View {
    let data: StatsGraphsData
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if data.count < 3 {
                StatsStateCard(symbol: "chart.xyaxis.line", title: data.count == 0 ? "No playback recorded in this range" : "Only a few plays so far",
                               message: "Data is collected from now on: the Playback Reporting plugin records every play from when it was installed. Check back after some watching.")
            }
            if data.count > 0 {
                StatsPlaysChartCard(buckets: data.plays, unit: data.playsUnit)
                StatsHeatmapCard(cells: data.heat)
                StatsTypesChartCard(buckets: data.types, unit: data.typesUnit)
                HStack(alignment: .top, spacing: 20) {
                    StatsDevicesCard(rows: data.devices)
                    StatsKindsCard(split: data.kinds).frame(width: 300)
                }
            }
        }
    }
}

// MARK: - Shared chart styling

/// Dark-glass chart look: no plot background, secondary-white axis labels, faint grid lines.
enum StatsChartStyle {
    static let label = Color.white.opacity(0.75)
    static let grid = Color.white.opacity(0.08)
    static func axisFormat(_ unit: StatsBucketUnit, count: Int) -> Date.FormatStyle {
        switch unit {
        case .day: return count <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()
        case .week: return .dateTime.month(.abbreviated).day()
        case .month: return .dateTime.month(.abbreviated)
        }
    }
}

/// A card heading with the hovered value on the right ("Week of Nov 10 · 12 plays · 8.4 h").
struct StatsChartHeader: View {
    let title: String
    let readout: String?
    var hint: String = "Hover for exact values"
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            StatsHeading(text: title)
            Spacer(minLength: 12)
            Text(readout ?? hint).cvFont(Glass3DTokens.Text.meta, weight: readout == nil ? .regular : .semibold)
                .foregroundColor(readout == nil ? Glass3DTokens.Grey.tertiary : Glass3DTokens.Grey.primary)
                .lineLimit(1).monospacedDigit()
        }
    }
}

extension View {
    /// Time axis (dates) + value axis styled for the glass cards.
    func statsTimeAxes(unit: StatsBucketUnit, count: Int) -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(max(count, 2), 8))) { _ in
                AxisGridLine().foregroundStyle(StatsChartStyle.grid)
                AxisValueLabel(format: StatsChartStyle.axisFormat(unit, count: count)).foregroundStyle(StatsChartStyle.label)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StatsChartStyle.grid)
                AxisValueLabel().foregroundStyle(StatsChartStyle.label)
            }
        }
        .chartPlotStyle { $0.background(Color.clear) }
    }

    /// Hover over a date chart: the date under the pointer (nil when it leaves).
    func statsDateHover(_ onDate: @escaping (Date?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let frame = proxy.plotFrame.map({ g[$0] }) else { onDate(nil); return }
                            let x = p.x - frame.origin.x
                            guard x >= 0, x <= frame.width else { onDate(nil); return }
                            onDate(proxy.value(atX: x, as: Date.self))
                        case .ended: onDate(nil)
                        }
                    }
            }
        }
    }
}

// MARK: - 1. Plays per day / week / month

private struct StatsPlaysChartCard: View {
    let buckets: [StatsCountBucket]
    let unit: StatsBucketUnit
    @AppStorage("accent") private var accentName = "red"
    @State private var hovered: StatsCountBucket?

    var body: some View {
        let accent = Theme.accent(accentName)
        VStack(alignment: .leading, spacing: 12) {
            StatsChartHeader(title: title, readout: hovered.map {
                "\(StatsGraphsAggregate.periodText($0.start, unit)) · \($0.plays) \($0.plays == 1 ? "play" : "plays") · \(StatsAggregate.hoursText($0.seconds))"
            })
            Chart(buckets) { b in
                BarMark(x: .value("Period", b.start, unit: unit.component), y: .value("Plays", b.plays))
                    .foregroundStyle(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .opacity(hovered == nil || hovered?.start == b.start ? 1 : 0.45)
                    .cornerRadius(Glass3DTokens.Radius.tag)
            }
            .statsTimeAxes(unit: unit, count: buckets.count)
            .statsDateHover { d in hovered = d.flatMap { StatsGraphsAggregate.bucket(at: $0, in: buckets, start: \.start) } }
            .frame(height: 180)
        }
        .statsCard()
    }

    private var title: String {
        switch unit { case .day: return "Plays per day"; case .week: return "Plays per week"; case .month: return "Plays per month" }
    }
}

// MARK: - 3. Play types over time

/// Softened play type colours (as the Users card's bar).
enum StatsTypeKind: String, CaseIterable, Identifiable {
    case directPlay = "Direct play", directStream = "Direct stream", transcode = "Transcode"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .directPlay: return StatsUsersStyle.directPlay
        case .directStream: return StatsUsersStyle.directStream
        case .transcode: return StatsUsersStyle.transcode
        }
    }
    func count(_ b: StatsTypeBucket) -> Int {
        switch self { case .directPlay: return b.directPlay; case .directStream: return b.directStream; case .transcode: return b.transcode }
    }
}

private struct StatsTypesChartCard: View {
    let buckets: [StatsTypeBucket]
    let unit: StatsBucketUnit
    @State private var hovered: StatsTypeBucket?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsChartHeader(title: "Play types over time", readout: hovered.map { b in
                StatsGraphsAggregate.periodText(b.start, unit) + " · "
                    + "\(b.directPlay) DP · \(b.directStream) DS · \(b.transcode) TC"
            })
            Chart {
                ForEach(buckets) { b in
                    ForEach(StatsTypeKind.allCases) { k in
                        BarMark(x: .value("Period", b.start, unit: unit.component), y: .value("Plays", k.count(b)))
                            .foregroundStyle(by: .value("Type", k.rawValue))
                            .opacity(hovered == nil || hovered?.start == b.start ? 0.85 : 0.4)
                    }
                }
            }
            .chartForegroundStyleScale(domain: StatsTypeKind.allCases.map(\.rawValue), range: StatsTypeKind.allCases.map(\.color))
            .chartLegend(.hidden)
            .statsTimeAxes(unit: unit, count: buckets.count)
            .statsDateHover { d in hovered = d.flatMap { StatsGraphsAggregate.bucket(at: $0, in: buckets, start: \.start) } }
            .frame(height: 180)
            HStack(spacing: 16) {
                ForEach(StatsTypeKind.allCases) { k in StatsLegendChip(color: k.color, text: k.rawValue) }
                Spacer(minLength: 0)
                let t = buckets.reduce(into: StatsTypeBucket(start: .distantPast)) {
                    $0.directPlay += $1.directPlay; $0.directStream += $1.directStream; $0.transcode += $1.transcode
                }
                if t.total > 0 {
                    let p = StatsUsersAggregate.percents([Double(t.directPlay), Double(t.directStream), Double(t.transcode)])
                    Text("\(p[0])% DP / \(p[1])% DS / \(p[2])% TC").cvFont(Glass3DTokens.Text.meta - 1)
                        .foregroundColor(Glass3DTokens.Grey.secondary)
                }
            }
        }
        .statsCard()
    }
}

struct StatsLegendChip: View {
    let color: Color, text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color.opacity(0.85)).frame(width: 8, height: 8)
            Text(text).cvFont(Glass3DTokens.Text.meta - 1, weight: .medium).foregroundColor(Glass3DTokens.Grey.secondary)
        }
    }
}
