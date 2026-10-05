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

/// The speed the trend chart plots. Until the user picks one, the chart is automatic.
enum TrendMetric: String, CaseIterable, Identifiable {
    case responseSpeed, turnSpeed, firstToken
    var id: String { rawValue }
    var shortTitle: String {
        switch self {
        case .responseSpeed: "Response"
        case .turnSpeed: "Turn"
        case .firstToken: "First token"
        }
    }
}

/// One plotted series with its labels and statistics.
struct TrendSeries {
    let metric: TrendMetric
    let title: String
    let axisName: String
    let points: [DashboardSnapshot.Bucket]
    let stats: MetricStats
    let unit: String
    let digits: Int
    let emptyText: String
    let definition: String
    let help: String
    let accessibilitySubject: String

    func value(_ number: Double?) -> String { number.map { String(format: "%.*f", digits, $0) } ?? "—" }
}

extension DashboardSnapshot {
    /// Series available for the selected model; first token only when the source reports it.
    var availableTrendMetrics: [TrendMetric] {
        TrendMetric.allCases.filter { $0 != .firstToken || ttft.count > 0 }
    }

    /// The selected model has turns but none with response timing (for example Grok Build history recorded before 0.1.15).
    var responseSpeedUnavailable: Bool {
        responseHero == nil && responsePoints.isEmpty && (turnHero != nil || !points.isEmpty)
    }

    /// Why there is no response speed: names the coding tool when its source records only whole turns.
    var responseSpeedUnavailableText: String {
        switch selectedCohort?.client {
        case ResponseSpeedCopy.grokBuildClient?:
            "No response speed for these \(ModelCohort.clientTitle(ResponseSpeedCopy.grokBuildClient)) turns: they were recorded before Tokrate 0.1.15."
        default:
            "No response speed for this model yet."
        }
    }

    /// The metric the chart plots: an explicit choice wins, even when it has no data. Automatic
    /// (nil, or a choice this source cannot offer) is Response, or Turn when the model has no response data.
    func effectiveTrendMetric(_ choice: TrendMetric?) -> TrendMetric {
        if let choice, availableTrendMetrics.contains(choice) { return choice }
        return responseSpeedUnavailable ? .turnSpeed : .responseSpeed
    }

    func trendSeries(for metric: TrendMetric) -> TrendSeries {
        switch metric {
        case .responseSpeed:
            let isGrokBuild = selectedCohort?.client == ResponseSpeedCopy.grokBuildClient
            return TrendSeries(
                metric: metric, title: "Your response speed", axisName: "Response speed",
                points: responsePoints, stats: response, unit: "tok/s", digits: 1,
                emptyText: responseSpeedUnavailable ? responseSpeedUnavailableText : "Your next completed response starts the chart.",
                definition: isGrokBuild ? ResponseSpeedCopy.grokBuildNote : ResponseSpeedCopy.definition,
                help: "Median per-turn response speed in each time interval, for turns with at least one response of 200+ output tokens. Only the time the model spent responding counts; tool runs and waiting are excluded. Effort is shown per model entry; speed tier and workload are uncontrolled."
                    + (isGrokBuild ? " " + ResponseSpeedCopy.grokBuildExplanation : ""),
                accessibilitySubject: "response speed, in output tokens per responding second"
            )
        case .turnSpeed:
            let help: String
            switch throughputLabel {
            case "Work-turn speed":
                help = "Median whole-work-turn output per second in each time interval. Grok's reported output can include nested subagent work."
            case "Subagent turn speed":
                help = "Median subagent output per second in each time interval, from the task prompt to the final answer. Each turn includes tool work and waiting."
            default:
                help = "Median whole-turn speed in each time interval, for turns with at least 20 output tokens. Each turn includes tool work, waiting, and reasoning."
            }
            return TrendSeries(
                metric: metric, title: "Your \(throughputLabel.lowercased())", axisName: throughputLabel,
                points: points, stats: throughput, unit: "tok/s", digits: 1,
                emptyText: "Your next completed turn starts the chart.",
                definition: "Whole turn, including tools and waiting.",
                help: help + " Whole turn, 20+ output tokens. Effort is shown per model entry; speed tier and workload are uncontrolled.",
                accessibilitySubject: "turn speed, in output tokens per whole-turn second"
            )
        case .firstToken:
            return TrendSeries(
                metric: metric, title: "Your first token", axisName: "First token",
                points: ttftPoints, stats: ttft, unit: "s", digits: 2,
                emptyText: "Your next completed turn starts the chart.",
                definition: "Source-reported wait for the first token.",
                help: "Median Codex-reported first-token wait in each time interval. First-visible-text semantics are unverified.",
                accessibilitySubject: "first-token wait, in seconds"
            )
        }
    }
}

struct TrendChartView: View {
    let snapshot: DashboardSnapshot
    @Binding var range: DashboardRange
    var compact = true
    /// nil until the user picks a metric: the chart then follows what the model has data for.
    @State private var selectedMetric: TrendMetric?

    var body: some View {
        if compact {
            content
        } else {
            content.dashboardCard(padding: 18)
        }
    }

    private var series: TrendSeries { snapshot.trendSeries(for: snapshot.effectiveTrendMetric(selectedMetric)) }

    private var content: some View {
        let series = series
        return VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Text(series.title).font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                Spacer()
                RangePicker(range: $range)
            }
            metricPicker(series)
            chart(series)
            Text(statsLine(series))
                .font(DashboardStyle.Typography.caption.monospacedDigit())
                .foregroundStyle(DashboardStyle.muted)
                .lineLimit(1).minimumScaleFactor(0.85)
                .help(series.help)
                .accessibilityLabel(statsAccessibility(series))
        }
    }

    private func metricPicker(_ series: TrendSeries) -> some View {
        Picker("Speed shown in the chart", selection: Binding(get: { series.metric }, set: { selectedMetric = $0 })) {
            ForEach(snapshot.availableTrendMetrics) { metric in Text(metric.shortTitle).tag(metric) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Speed shown in the chart")
        .help("Response speed excludes tools and your time; turn speed covers the whole turn.")
    }

    @ViewBuilder
    private func chart(_ series: TrendSeries) -> some View {
        let height: CGFloat = compact ? 76 : 170
        if series.points.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "waveform.path").font(.system(size: 18)).foregroundStyle(DashboardStyle.accent)
                Text(series.emptyText)
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 64 : 170)
        } else {
            let runs = TrendRun.runs(from: series.points, range: range)
            Chart {
                ForEach(runs) { run in
                    if run.points.count > 1 {
                        ForEach(run.points) { point in
                            AreaMark(
                                x: .value("Time", point.date),
                                yStart: .value("Zero", 0),
                                yEnd: .value(series.axisName, point.median),
                                series: .value("Run", "area\(run.id)")
                            )
                            .foregroundStyle(LinearGradient(colors: [DashboardStyle.arcEnd.opacity(0.22), DashboardStyle.arcStart.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        }
                        ForEach(run.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value(series.axisName, point.median),
                                series: .value("Run", "line\(run.id)")
                            )
                            .foregroundStyle(DashboardStyle.gradient)
                            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                        }
                    } else if let point = run.points.first {
                        PointMark(x: .value("Time", point.date), y: .value(series.axisName, point.median))
                            .foregroundStyle(DashboardStyle.arcEnd)
                            .symbolSize(40)
                    }
                }
            }
            .chartXScale(domain: snapshot.dates)
            .chartYScale(domain: 0...max(1, (series.points.map(\.median).max() ?? 1) * 1.15))
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
            .accessibilityLabel("Local \(series.accessibilitySubject) over \(range == .day ? "24 hours" : "seven days")")
            .accessibilityValue(statsAccessibility(series))
        }
    }

    private func statsLine(_ series: TrendSeries) -> String {
        guard series.stats.count > 0 else { return series.definition }
        return "\(range.shortTitle) median \(series.value(series.stats.median)) \(series.unit) · min \(series.value(series.stats.minimum)) · max \(series.value(series.stats.maximum)) · n=\(series.stats.count)"
    }

    private func statsAccessibility(_ series: TrendSeries) -> String {
        guard series.stats.count > 0 else { return "No completed measurements in this range" }
        let unit = series.metric == .firstToken ? "seconds" : "tokens per second"
        func value(_ number: Double?) -> String { number.map { String(format: "%.*f", series.digits, $0) } ?? "unavailable" }
        return "\(range.title) median \(value(series.stats.median)) \(unit), minimum \(value(series.stats.minimum)), maximum \(value(series.stats.maximum)), \(series.stats.count) turns"
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
