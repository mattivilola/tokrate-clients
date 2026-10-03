import SwiftUI

struct CohortSelectionView: View {
    @Binding var selection: DashboardSelection
    let cohorts: [ModelCohort]
    let latest: ModelCohort?

    var body: some View {
        Menu {
            Button {
                selection = .latest
            } label: {
                selectionRow("Latest completed model", selected: selection == .latest)
            }
            Divider()
            ForEach(cohorts) { cohort in
                Button {
                    selection = .cohort(cohort)
                } label: {
                    selectionRow(cohort.selectionLabel, selected: selection == .cohort(cohort))
                }
            }
            Divider()
            Button {
                selection = .all
            } label: {
                selectionRow("All models comparison", selected: selection.isAllModels)
            }
        } label: {
            HStack(spacing: 5) {
                Text(selection.displayLabel(latest: latest))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel("Model comparison selector")
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func selectionRow(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected { Image(systemName: "checkmark") }
        }
    }
}

struct CohortComparisonView: View {
    let snapshot: DashboardSnapshot
    @Binding var range: DashboardRange
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Text("Model comparison").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("History range", selection: $range) {
                    ForEach(DashboardRange.allCases) { range in Text(range.title).tag(range) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("History range")
                .frame(width: 150)
            }
            if snapshot.cohortSummaries.isEmpty {
                Text("Completed turns from each model will appear here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 72 : 130)
            } else {
                ForEach(snapshot.cohortSummaries) { summary in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(summary.cohort.displayModel)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(summary.throughput.count) eligible")
                                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(summary.cohort.detailLabel)
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        comparisonLine(
                            title: "Turn throughput",
                            median: summary.throughput.median,
                            minimum: summary.throughput.minimum,
                            maximum: summary.throughput.maximum,
                            count: summary.throughput.count,
                            unit: "t/s",
                            digits: 1
                        )
                        comparisonLine(
                            title: "Codex TTFT",
                            median: summary.ttft.median,
                            minimum: summary.ttft.minimum,
                            maximum: summary.ttft.maximum,
                            count: summary.ttft.count,
                            unit: "s",
                            digits: 2
                        )
                    }
                    .padding(.vertical, 5)
                    if summary.id != snapshot.cohortSummaries.last?.id {
                        Divider().opacity(0.55)
                    }
                }
            }
            Text("Whole-turn measurements · no pooled comparison · effort shown when reported; speed tier/workload uncontrolled")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .dashboardCard(padding: 12)
    }

    private func comparisonLine(title: String, median: Double?, minimum: Double?, maximum: Double?, count: Int, unit: String, digits: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("median \(format(median, digits: digits)) \(unit)")
                .fontWeight(.medium)
            Text("· min \(format(minimum, digits: digits)) · max \(format(maximum, digits: digits)) · n=\(count)")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.82)
        .accessibilityElement(children: .combine)
    }

    private func format(_ value: Double?, digits: Int) -> String {
        value.map { String(format: "%.*f", digits, $0) } ?? "—"
    }
}

struct PersonalTrendView: View {
    let trend: PersonalTrend?
    var reasoningEffort: String? = nil

    var body: some View {
        if let trend {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: trend.status == .slower ? "exclamationmark.circle.fill" : "chart.line.uptrend.xyaxis")
                        .foregroundStyle(trend.status == .slower ? .orange : .secondary)
                    Text(title(for: trend.status)).font(.system(size: 11, weight: .semibold))
                }
                if trend.status == .slower {
                    if trend.comparesThroughput {
                        metricLine("Turn throughput", current: trend.currentThroughput, baseline: trend.baselineThroughput, unit: "t/s", digits: 1, sampleLabel: "eligible turns")
                    }
                    if trend.comparesTTFT {
                        metricLine("Codex TTFT", current: trend.currentTTFT, baseline: trend.baselineTTFT, unit: "s", digits: 2, sampleLabel: "values")
                    }
                    Text("Workload/tools may have changed; not a provider diagnosis. Reasoning effort: \(reasoningEffort ?? "unknown"); speed tier/workload are uncontrolled.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text("Same model, provider, client version, and reasoning effort: \(reasoningEffort ?? "unknown"); speed tier/workload are uncontrolled.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard(padding: 11)
        }
    }

    private func title(for status: PersonalTrend.Status) -> String {
        switch status {
        case .noRecentObservations: "No recent observations"
        case .buildingBaseline: "Building baseline"
        case .noLargeChange: "No large change"
        case .slower: "Your recent turns are slower"
        }
    }

    private func metricLine(_ title: String, current: MetricStats, baseline: MetricStats, unit: String, digits: Int, sampleLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text("Now median \(format(current.median, digits: digits)) \(unit) (n=\(current.count) \(sampleLabel)); prior six days \(format(baseline.median, digits: digits)) \(unit) (n=\(baseline.count) \(sampleLabel))")
                .fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 9)).monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func format(_ value: Double?, digits: Int) -> String {
        value.map { String(format: "%.*f", digits, $0) } ?? "—"
    }
}
