import SwiftUI

struct SummaryView: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        VStack(spacing: 8) {
            if snapshot.range == .week {
                HStack(spacing: 8) {
                    metric(
                        title: "7 days throughput median",
                        stats: snapshot.throughput,
                        unit: "t/s",
                        digits: 1,
                        countLabel: "eligible turns"
                    )
                    metric(
                        title: "7 days Codex TTFT median",
                        stats: snapshot.ttft,
                        unit: "s",
                        digits: 2,
                        countLabel: "available values"
                    )
                }
            }
            if let comparison = snapshot.localPeriodComparison {
                localComparison(comparison)
            }
        }
    }

    private func metric(title: String, stats: MetricStats, unit: String, digits: Int, countLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(format(stats.median, digits: digits))
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text("min \(format(stats.minimum, digits: digits)) · max \(format(stats.maximum, digits: digits)) · n=\(stats.count)")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(countLabel).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .help(title.localizedCaseInsensitiveContains("TTFT") ? "Median and observed range of Codex-reported TTFT values; first-visible-text semantics are unverified." : "Median and observed range for completed turns with at least 20 output tokens. Whole-turn time includes tool work, waiting, and reasoning.")
    }

    private func format(_ value: Double?, digits: Int) -> String {
        value.map { String(format: "%.*f", digits, $0) } ?? "—"
    }

    private func localComparison(_ comparison: LocalPeriodComparison) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Selected model · local medians")
                .font(.system(size: 10, weight: .semibold))
            HStack(spacing: 4) {
                Text("Period").frame(maxWidth: .infinity, alignment: .leading)
                Text("Turn throughput").frame(width: 112, alignment: .trailing)
                Text("Codex TTFT").frame(width: 94, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary)
            comparisonRow("Recent 15 min", stats: comparison.recent15Minutes)
            comparisonRow("Last 24 hours", stats: comparison.last24Hours)
            comparisonRow("Previous 24 hours", stats: comparison.previous24Hours)
            Text("24 h change vs previous 24 h: throughput \(change(comparison.throughputChangePercent)) · TTFT \(change(comparison.ttftChangePercent))")
                .font(.system(size: 9, weight: .medium)).monospacedDigit()
            Text("Each metric has its own turn count. Change needs at least 5 values per period and a non-zero previous median.")
                .font(.system(size: 8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let trend = snapshot.personalTrend {
                Label(personalSignalTitle(trend.status), systemImage: trend.status == .slower ? "exclamationmark.circle.fill" : "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(trend.status == .slower ? .orange : .secondary)
                    .help("A personal whole-turn speed trend only; it does not measure answer quality or confirm provider health.")
            }
            if comparison.previousRange == nil {
                Text("Previous 7 days unavailable · local history retains 7 days.")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func comparisonRow(_ title: String, stats: PeriodMetricStats) -> some View {
        HStack(spacing: 4) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(format(stats.throughput.median, digits: 1)) t/s · n=\(stats.throughput.count)")
                .frame(width: 112, alignment: .trailing)
            Text("\(format(stats.ttft.median, digits: 2)) s · n=\(stats.ttft.count)")
                .frame(width: 94, alignment: .trailing)
        }
        .font(.system(size: 8)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    private func change(_ value: Double?) -> String {
        value.map { String(format: "%+.1f%%", $0) } ?? "unavailable"
    }

    private func personalSignalTitle(_ status: PersonalTrend.Status) -> String {
        switch status {
        case .noRecentObservations: "Personal speed signal · no recent observations"
        case .buildingBaseline: "Personal speed signal · building baseline"
        case .noLargeChange: "Personal speed signal · no large change"
        case .slower: "Personal speed signal · recent turns slower"
        }
    }
}
