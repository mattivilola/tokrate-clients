import SwiftUI

struct SummaryView: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        HStack(spacing: 8) {
            metric(
                title: "Turn throughput",
                stats: snapshot.throughput,
                unit: "t/s",
                digits: 1,
                countLabel: "eligible turns"
            )
            metric(
                title: "Codex TTFT",
                stats: snapshot.ttft,
                unit: "s",
                digits: 2,
                countLabel: "available values"
            )
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
        .help(title == "Codex TTFT" ? "Median and observed range of Codex-reported TTFT values; first-visible-text semantics are unverified." : "Median and observed range for completed turns with at least 20 output tokens. Whole-turn time includes tool work, waiting, and reasoning.")
    }

    private func format(_ value: Double?, digits: Int) -> String {
        value.map { String(format: "%.*f", digits, $0) } ?? "—"
    }
}
