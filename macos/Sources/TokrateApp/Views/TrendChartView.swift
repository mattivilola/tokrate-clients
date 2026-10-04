import Charts
import SwiftUI

/// Consecutive chart buckets with at most one empty bucket between them form one drawn line;
/// longer silences leave a gap, and a lone bucket is drawn as a dot.
struct TrendRun: Identifiable, Equatable {
    let id: Int
    let points: [DashboardSnapshot.Bucket]

    static func runs(from points: [DashboardSnapshot.Bucket], range: DashboardRange) -> [TrendRun] {
        let width = range.duration / Double(range.bucketCount)
        var runs: [[DashboardSnapshot.Bucket]] = []
        for point in points.sorted(by: { $0.date < $1.date }) {
            if let last = runs.last?.last, point.date.timeIntervalSince(last.date) <= width * 2.5 {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs.enumerated().map { TrendRun(id: $0.offset, points: $0.element) }
    }
}

extension DashboardSnapshot.Bucket: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.date == rhs.date && lhs.median == rhs.median && lhs.turns == rhs.turns }
}

struct TrendChartView: View {
    let snapshot: DashboardSnapshot
    @Binding var range: DashboardRange
    var compact = true

    var body: some View {
        if compact {
            content
        } else {
            content.dashboardCard(padding: 18)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Text("Your turn speed").font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                Spacer()
                RangePicker(range: $range)
            }
            chart
            Text(statsLine)
                .font(DashboardStyle.Typography.caption.monospacedDigit())
                .foregroundStyle(DashboardStyle.muted)
                .lineLimit(1).minimumScaleFactor(0.85)
                .help(trendHelp)
                .accessibilityLabel(statsAccessibility)
        }
    }

    @ViewBuilder
    private var chart: some View {
        let height: CGFloat = compact ? 76 : 170
        if snapshot.points.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "waveform.path").font(.system(size: 18)).foregroundStyle(DashboardStyle.accent)
                Text("Your next completed turn starts the chart.")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 64 : 170)
        } else {
            let runs = TrendRun.runs(from: snapshot.points, range: range)
            Chart {
                ForEach(runs) { run in
                    if run.points.count > 1 {
                        ForEach(run.points) { point in
                            AreaMark(
                                x: .value("Time", point.date),
                                yStart: .value("Zero", 0),
                                yEnd: .value("Turn speed", point.median),
                                series: .value("Run", "area\(run.id)")
                            )
                            .foregroundStyle(LinearGradient(colors: [DashboardStyle.arcEnd.opacity(0.22), DashboardStyle.arcStart.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        }
                        ForEach(run.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Turn speed", point.median),
                                series: .value("Run", "line\(run.id)")
                            )
                            .foregroundStyle(DashboardStyle.gradient)
                            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                        }
                    } else if let point = run.points.first {
                        PointMark(x: .value("Time", point.date), y: .value("Turn speed", point.median))
                            .foregroundStyle(DashboardStyle.arcEnd)
                            .symbolSize(40)
                    }
                }
            }
            .chartXScale(domain: snapshot.dates)
            .chartYScale(domain: 0...max(1, (snapshot.points.map(\.median).max() ?? 1) * 1.15))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { axis in
                    AxisValueLabel {
                        if let date = axis.as(Date.self) {
                            Text(date, format: range == .day ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated))
                                .font(DashboardStyle.Typography.caption)
                                .foregroundStyle(DashboardStyle.muted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(DashboardStyle.line)
                    AxisValueLabel().font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                }
            }
            .frame(height: height)
            .accessibilityLabel("Local turn speed over \(range == .day ? "24 hours" : "seven days"), in output tokens per whole-turn second")
            .accessibilityValue(statsAccessibility)
        }
    }

    private var statsLine: String {
        guard snapshot.throughput.count > 0 else { return "Whole turn, including tools and waiting." }
        func value(_ number: Double?) -> String { number.map { String(format: "%.1f", $0) } ?? "—" }
        return "\(range.shortTitle) median \(value(snapshot.throughput.median)) tok/s · min \(value(snapshot.throughput.minimum)) · max \(value(snapshot.throughput.maximum)) · n=\(snapshot.throughput.count)"
    }

    private var statsAccessibility: String {
        guard snapshot.throughput.count > 0 else { return "No completed turns in this range" }
        func value(_ number: Double?) -> String { number.map { String(format: "%.1f", $0) } ?? "unavailable" }
        return "\(range.title) median \(value(snapshot.throughput.median)) tokens per second, minimum \(value(snapshot.throughput.minimum)), maximum \(value(snapshot.throughput.maximum)), \(snapshot.throughput.count) turns"
    }

    private var trendHelp: String {
        let common = " Whole turn, 20+ output tokens. Effort is shown per model entry; speed tier and workload are uncontrolled."
        switch snapshot.throughputLabel {
        case "Work-turn speed":
            return "Median whole-work-turn output per second in each time interval. Grok's reported output can include nested subagent work." + common
        case "Subagent turn speed":
            return "Median subagent output per second in each time interval, from the task prompt to the final answer. Each turn includes tool work and waiting." + common
        default:
            return "Median whole-turn speed in each time interval, for turns with at least 20 output tokens. Each turn includes tool work, waiting, and reasoning." + common
        }
    }
}

/// The 24 h / 7 d segmented control shared by the trend chart and the model list.
struct RangePicker: View {
    @Binding var range: DashboardRange

    var body: some View {
        Picker("History range", selection: $range) {
            ForEach(DashboardRange.allCases) { range in Text(range.shortTitle).tag(range) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .accessibilityLabel("History range")
        .help("Show the last 24 hours or the last 7 days")
    }
}
