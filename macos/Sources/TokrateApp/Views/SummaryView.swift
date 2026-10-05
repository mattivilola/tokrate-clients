import SwiftUI

/// Median/min/max cards, local period comparison and the personal speed signal.
struct SummaryView: View {
    let snapshot: DashboardSnapshot
    /// Compact content sits on insets inside another surface (popover details).
    var compact = false

    private var speedTitle: String { snapshot.selectedCohort?.measurement.title ?? "Turn speed" }
    private var responseTitle: String { ResponseSpeedCopy.title }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metric(
                    title: "\(snapshot.range.title) · \(responseTitle) median",
                    stats: snapshot.response,
                    unit: "tok/s",
                    digits: 1,
                    countLabel: "turns",
                    help: "Median and observed range of per-turn response speed (\(snapshot.responseCount) responses of 200+ output tokens, merged across coding tools for this model). Tool runs and waiting are excluded."
                )
                metric(
                    title: "\(snapshot.range.title) · \(speedTitle) median",
                    stats: snapshot.throughput,
                    unit: "tok/s",
                    digits: 1,
                    countLabel: "turns",
                    help: "Median and observed range for completed turns with at least 20 output tokens. Whole-turn time includes tool work, waiting, and reasoning."
                )
            }
            HStack(spacing: 8) {
                metric(
                    title: "\(snapshot.range.title) · First token median",
                    stats: snapshot.ttft,
                    unit: "s",
                    digits: 2,
                    countLabel: "values",
                    help: "Median and observed range of source-reported first-token wait; first-visible-text semantics are unverified."
                )
            }
            efficiency
            if let comparison = snapshot.localPeriodComparison {
                localComparison(comparison)
            }
        }
    }

    /// The selected model and effort's efficiency indicator over the whole 7-day history, whatever
    /// the range: the value, or how far it is from the 20-request floor.
    private var efficiency: some View {
        let selected = snapshot.efficiencySelected
        return container {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("7 d · \(EfficiencyCopy.title)")
                        .font(DashboardStyle.Typography.captionEmphasis).foregroundStyle(DashboardStyle.muted)
                    ChipView(text: EfficiencyCopy.badge, tone: .accent).fixedSize()
                    Spacer(minLength: 0)
                }
                if let indicator = selected?.indicator {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(indicator)")
                            .font(DashboardStyle.Typography.value(size: 22)).monospacedDigit().foregroundStyle(DashboardStyle.ink)
                        Text("indicator").font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    }
                } else {
                    Text(EfficiencyCopy.requestsOfFloor(selected?.turns ?? 0))
                        .font(DashboardStyle.Typography.value(size: 15)).monospacedDigit().foregroundStyle(DashboardStyle.ink)
                }
                if let selected {
                    Text("median \(EfficiencyIndicator.compactTokens(selected.medianTokens)) \(EfficiencyCopy.tokensPerRequest) · middle half \(EfficiencyIndicator.compactTokens(selected.p25Tokens))–\(EfficiencyIndicator.compactTokens(selected.p75Tokens)) · n=\(selected.turns) requests")
                        .font(DashboardStyle.Typography.caption.monospacedDigit()).foregroundStyle(DashboardStyle.muted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Text(selected?.indicator == nil ? EfficiencyCopy.insufficient : EfficiencyCopy.definition)
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .help(EfficiencyCopy.explanation)
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if compact {
            content().dashboardInset(padding: 10)
        } else {
            content().dashboardCard(padding: 14)
        }
    }

    private func metric(title: String, stats: MetricStats, unit: String, digits: Int, countLabel: String, help: String) -> some View {
        container {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DashboardStyle.Typography.captionEmphasis).foregroundStyle(DashboardStyle.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(format(stats.median, digits: digits))
                        .font(DashboardStyle.Typography.value(size: 22)).monospacedDigit().foregroundStyle(DashboardStyle.ink)
                    Text(unit).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                }
                Text("min \(format(stats.minimum, digits: digits)) · max \(format(stats.maximum, digits: digits)) · n=\(stats.count) \(countLabel)")
                    .font(DashboardStyle.Typography.caption.monospacedDigit()).foregroundStyle(DashboardStyle.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .help(help)
    }

    private func format(_ value: Double?, digits: Int) -> String {
        value.map { String(format: "%.*f", digits, $0) } ?? "—"
    }

    private func localComparison(_ comparison: LocalPeriodComparison) -> some View {
        container {
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected model · local medians (tok/s)")
                    .font(DashboardStyle.Typography.footnoteEmphasis).foregroundStyle(DashboardStyle.ink)
                HStack(spacing: 4) {
                    Text("Period").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Response").lineLimit(1).minimumScaleFactor(0.7).frame(width: 80, alignment: .trailing)
                    Text("Turn").lineLimit(1).minimumScaleFactor(0.7).frame(width: 80, alignment: .trailing)
                    Text("First token").frame(width: 72, alignment: .trailing)
                }
                .font(DashboardStyle.Typography.captionEmphasis).foregroundStyle(DashboardStyle.muted)
                comparisonRow("15 min", stats: comparison.recent15Minutes)
                comparisonRow("24 h", stats: comparison.last24Hours)
                comparisonRow("Prev. 24 h", stats: comparison.previous24Hours)
                Text("24 h change vs previous 24 h: response speed \(change(comparison.responseChangePercent)) · turn speed \(change(comparison.throughputChangePercent)) · first token \(change(comparison.ttftChangePercent))")
                    .font(DashboardStyle.Typography.footnoteEmphasis.monospacedDigit()).foregroundStyle(DashboardStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Each metric has its own turn count. Change needs at least 5 values per period and a non-zero previous median.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
                if !compact, let trend = snapshot.personalTrend {
                    Label(personalSignalTitle(trend.status), systemImage: trend.status == .slower ? "exclamationmark.circle.fill" : "chart.line.uptrend.xyaxis")
                        .font(DashboardStyle.Typography.footnoteEmphasis)
                        .foregroundStyle(trend.status == .slower ? DashboardStyle.warn : DashboardStyle.muted)
                        .help("A personal speed trend only; it does not measure answer quality or confirm provider health.")
                }
                if comparison.previousRange == nil {
                    Text("Previous 7 days unavailable · local history retains 7 days.")
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func comparisonRow(_ title: String, stats: PeriodMetricStats) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(DashboardStyle.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(format(stats.response.median, digits: 1)) · n=\(stats.response.count)")
                .frame(width: 80, alignment: .trailing)
            Text("\(format(stats.throughput.median, digits: 1)) · n=\(stats.throughput.count)")
                .frame(width: 80, alignment: .trailing)
            Text("\(format(stats.ttft.median, digits: 2)) s · n=\(stats.ttft.count)")
                .frame(width: 72, alignment: .trailing)
        }
        .font(DashboardStyle.Typography.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        .foregroundStyle(DashboardStyle.muted)
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
        case .slower: "Personal speed signal · recent speed slower"
        }
    }
}
