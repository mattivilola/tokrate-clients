import Charts
import SwiftUI

struct TrendChartView: View {
    let snapshot: DashboardSnapshot
    @Binding var range: DashboardRange
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your pace").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("History range", selection: $range) {
                    ForEach(DashboardRange.allCases) { range in Text(range.title).tag(range) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("History range")
                .frame(width: 138)
            }
            if snapshot.points.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "waveform.path").font(.title3).foregroundStyle(.teal)
                    Text("Your next completed turn starts the chart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 76 : 170)
            } else {
                Chart(snapshot.points) { point in
                    AreaMark(x: .value("Time", point.date), yStart: .value("Zero", 0), yEnd: .value("Median turn throughput", point.median))
                        .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.2), .blue.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.date), y: .value("Median turn throughput", point.median))
                        .foregroundStyle(DashboardStyle.gradient)
                        .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                    if snapshot.points.count == 1 {
                        PointMark(x: .value("Time", point.date), y: .value("Median turn throughput", point.median))
                            .foregroundStyle(.teal).symbolSize(30)
                    }
                }
                .chartXScale(domain: snapshot.dates)
                .chartYScale(domain: 0...max(1, (snapshot.points.map(\.median).max() ?? 1) * 1.15))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { axis in
                        AxisValueLabel {
                            if let date = axis.as(Date.self) {
                                Text(date, format: range == .today ? .dateTime.hour() : .dateTime.weekday(.abbreviated))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .frame(height: compact ? 76 : 170)
                .accessibilityLabel("Local turn throughput over \(range == .today ? "today" : "seven days"), in tokens per whole-turn second")
            }
            Text("Typical completed-turn rate · tokens/s")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .help("Median throughput in each time interval. Each turn includes tool work, waiting, and reasoning.")
        }
        .dashboardCard(padding: 12)
    }
}
