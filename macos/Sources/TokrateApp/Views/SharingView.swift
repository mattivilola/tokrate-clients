import SwiftUI
import TokrateCore

struct SharingView: View {
    let preferences: SharingPreferences
    let selection: DashboardSelection
    let resolvedCohort: ModelCohort?
    var compact = true
    var showToggle = true
    var showConsentDisclosure = true
    /// Draw the card chrome; turn off when placed inside another card or form.
    var framed = true
    var checkForUpdates: (() -> Void)?
    private var sharing: SharingSession { preferences.session }

    var body: some View {
        if framed {
            content.dashboardCard(padding: 14)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if showConsentDisclosure && preferences.isConsentDisclosureVisible {
            ConsentDisclosureView(preferences: preferences, spacious: !compact)
        } else {
            sharingStatus.foregroundStyle(DashboardStyle.ink)
        }
    }

    private var sharingStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: preferences.isSharingRequested ? "globe.americas.fill" : "lock.shield")
                    .font(.system(size: 20)).foregroundStyle(DashboardStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share with community").font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                    Text(preferences.isSharingRequested ? (sharing.isEnabled ? "On · new turn measurements only" : "On · sharing needs attention") : "Off · your measurements stay local")
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                }
                Spacer(minLength: 4)
                if showToggle && !preferences.isConsentDisclosureVisible {
                    Toggle("Share with community", isOn: Binding(
                        get: { preferences.isSharingRequested },
                        set: { preferences.setSharingEnabled($0) }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(DashboardStyle.accent)
                    .accessibilityHint("Turning on opens the sharing notice. Turning off stops future contributions and cancels unsent samples; local monitoring continues.")
                }
            }
            if preferences.isSharingRequested {
                VStack(alignment: .leading, spacing: 7) {
                    Text(sharing.status + (sharing.pendingCount > 0 ? " · \(sharing.pendingCount) pending" : ""))
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    if sharing.requiresUpdate {
                        Button("Check for Updates…") { checkForUpdates?() }
                            .buttonStyle(.link).font(DashboardStyle.Typography.footnote).tint(DashboardStyle.accent)
                            .disabled(checkForUpdates == nil)
                    } else if !sharing.isEnabled {
                        Button("Retry sharing") { preferences.retry() }.buttonStyle(.link).font(DashboardStyle.Typography.footnote).tint(DashboardStyle.accent)
                    } else if let board = sharing.board {
                        boardContent(board)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(preferences.isSharingRequested ? "New eligible measurements only. Turn off any time." : "Off · local monitoring continues.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                Spacer(minLength: 4)
                ConsentLinks()
            }
        }
    }

    @ViewBuilder
    private func boardContent(_ board: GlobalBoard) -> some View {
        if !board.collectionEnabled {
            Label("Community collection is paused", systemImage: "pause.circle").font(DashboardStyle.Typography.footnote)
        } else {
            HStack(spacing: 6) {
                Text("Community publication · \(windowLabel(board.window))")
                if board.state == "stale" {
                    statusTag("Older data · signals may be outdated", color: DashboardStyle.warn)
                } else {
                    statusTag("State: \(publicationStateLabel(board.state))", color: DashboardStyle.muted)
                }
                if board.state == "insufficient_data" || board.publicationMode == "early_data" {
                    statusTag("Early data", color: DashboardStyle.muted)
                }
                Spacer(minLength: 0)
            }
            .font(DashboardStyle.Typography.captionEmphasis).foregroundStyle(DashboardStyle.muted)
            if let dataTime = timeLabel(board.dataAsOf ?? board.generatedAt) {
                Text("Data as of \(dataTime)")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            }

            if selection.isAllModels {
                if board.cohorts.isEmpty {
                    Text("Community comparison is gathering data.")
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                } else {
                    ForEach(board.cohorts) { cohort in communityRow(cohort, isStale: board.state == "stale") }
                    alertStatusAndRows(in: board, cohorts: board.cohorts)
                }
            } else if let target = selectedCohort {
                let matches = board.cohorts.filter { exactlyMatches($0, target: target) }
                if matches.isEmpty {
                Text("Community data for this exact client, parser, metric, model, provider, version, and reasoning effort is not available yet.")
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(matches) { cohort in communityRow(cohort, isStale: board.state == "stale") }
                    alertStatusAndRows(in: board, cohorts: matches)
                }
            } else {
                Text("Choose a reported model and client version to see its community comparison.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            }

            if let methodology = board.methodology?.statistics ?? board.methodology?.source {
                Text("Method: \(methodology)")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).lineLimit(2)
            }
            Text("Geographic coverage unknown · answer quality not measured · streaming speed unavailable. No alert is not a health status.")
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
            Text("Community rows use reported primary-client samples. Effort is shown when reported; speed tier and workload are uncontrolled.")
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedCohort: ModelCohort? {
        switch selection {
        case .auto, .autoTool: resolvedCohort
        case .cohort(let cohort): cohort
        case .all: nil
        }
    }

    private func exactlyMatches(_ cohort: GlobalBoard.Cohort, target: ModelCohort) -> Bool {
        guard let expectedID = target.communityBoardID else { return false }
        return cohort.id == expectedID
    }

    private func communityRow(_ cohort: GlobalBoard.Cohort, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(cohort.model).lineLimit(1)
                Text("· \(ModelCohort.providerTitle(cohort.provider))").foregroundStyle(DashboardStyle.muted).lineLimit(1)
                Spacer(minLength: 4)
                Text(cohort.medianThroughput.map { String(format: "%.1f t/s", $0) } ?? "—")
                    .monospacedDigit().fontWeight(.medium)
            }
            Text("\(cohort.client ?? "client unknown") · client \(cohort.clientVersion ?? "version unknown") · reasoning effort \(cohort.reasoningEffort.flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil } ?? "unknown")")
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Spacer(minLength: 4)
                if let minimum = cohort.minThroughput, let maximum = cohort.maxThroughput {
                    Text("min \(String(format: "%.1f", minimum)) · max \(String(format: "%.1f", maximum))")
                        .monospacedDigit()
                }
                Text("· \(throughputCountLabel(cohort))")
                    .monospacedDigit()
            }
            .foregroundStyle(DashboardStyle.muted)
            .font(DashboardStyle.Typography.caption)
            if let median = cohort.medianTtftMs {
                HStack(spacing: 4) {
                    Text("TTFT median \(String(format: "%.0f", median)) ms")
                    if let minimum = cohort.minTtftMs, let maximum = cohort.maxTtftMs {
                        Text("· min \(String(format: "%.0f", minimum)) · max \(String(format: "%.0f", maximum)) ms")
                    }
                    Text("· \(ttftCountLabel(cohort))")
                }
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).monospacedDigit()
            }
            if let comparison = cohort.comparison {
                communityComparison(comparison, isStale: isStale)
            }
            if let signals = cohort.signals {
                if let signal = signals.throughput { signalRow("Throughput trend", signal: signal, unit: "t/s", isStale: isStale) }
                if let signal = signals.ttft { signalRow("TTFT trend", signal: signal, unit: "ms", isStale: isStale) }
            }
        }
        .font(DashboardStyle.Typography.caption)
        .padding(.vertical, 3)
    }

    private func matchingAlerts(in board: GlobalBoard, cohorts: [GlobalBoard.Cohort]) -> [GlobalBoard.Alert] {
        let ids = Set(cohorts.map(\.id))
        return board.alerts.filter { alert in alert.cohortId.map(ids.contains) == true }
    }

    @ViewBuilder
    private func alertStatusAndRows(in board: GlobalBoard, cohorts: [GlobalBoard.Cohort]) -> some View {
        let alerts = matchingAlerts(in: board, cohorts: cohorts)
        if alerts.isEmpty {
            Text(board.state == "stale" ? "No active alert in this older snapshot. This does not confirm provider health." : "No active published alert. This does not confirm provider health.")
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
        } else {
            ForEach(alerts) { alert in alertRow(alert) }
        }
    }

    private func communityComparison(_ comparison: GlobalBoard.Comparison, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isStale ? "Community · older snapshot · current vs previous period" : "Community · current vs previous period")
                .font(DashboardStyle.Typography.captionEmphasis).foregroundStyle(DashboardStyle.muted)
            if let throughput = comparison.throughput {
                comparisonLine("Throughput", metric: throughput, unit: "t/s", digits: 1)
            }
            if let ttft = comparison.ttft {
                comparisonLine("TTFT", metric: ttft, unit: "ms", digits: 0)
            }
        }
        .padding(.top, 4)
    }

    private func comparisonLine(_ title: String, metric: GlobalBoard.ComparisonMetric, unit: String, digits: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(title): \(periodValue(metric.current, unit: unit, digits: digits)) vs \(periodValue(metric.previous, unit: unit, digits: digits)) · \(percent(metric.changePercent))")
                .font(DashboardStyle.Typography.captionEmphasis).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Text("Current \(coverage(metric.current)) · previous \(coverage(metric.previous)) · \(availability(metric.availability))")
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signalRow(_ title: String, signal: GlobalBoard.Signal, unit: String, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(title): \(isStale ? "older snapshot · " : "")\(signalStateLabel(signal.state))")
                .font(DashboardStyle.Typography.captionEmphasis)
            Text("\(isStale ? "Latest 5-min bucket in this older snapshot" : "Latest 5-min bucket") · \(countLabel(signal.recentTurns, noun: "turns")) · \(countLabel(signal.recentContributors, noun: "contributors") )")
                .font(DashboardStyle.Typography.caption).monospacedDigit().foregroundStyle(DashboardStyle.muted)
            Text("Baseline · \(countLabel(signal.baselineBuckets, noun: "buckets")) · \(countLabel(signal.baselineDays, noun: "days")) · \(signal.baselineHours.map { String(format: "%.0f hours", $0) } ?? "hours unavailable")")
                .font(DashboardStyle.Typography.caption).monospacedDigit().foregroundStyle(DashboardStyle.muted)
            HStack(spacing: 3) {
                if let change = signal.changePercent { Text("\(String(format: "%+.1f%%", change)) vs baseline") }
                if let median = signal.baselineMedian { Text("· baseline median \(String(format: "%.1f", median)) \(unit)") }
            }
            .font(DashboardStyle.Typography.caption).monospacedDigit().foregroundStyle(DashboardStyle.muted)
            if let reason = signal.reason {
                Text(signalReasonLabel(reason)).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    private func countLabel(_ value: Int?, noun: String) -> String {
        value.map { "\($0) \(noun)" } ?? "\(noun) unavailable"
    }

    private func timeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value)
        }()
        return date?.formatted(date: .omitted, time: .shortened)
    }

    private func publicationStateLabel(_ state: String) -> String {
        switch state {
        case "stale": "older data"
        case "insufficient_data": "gathering data"
        case "early_data": "early data"
        case "ready", "available": "current snapshot"
        default: state.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func signalStateLabel(_ state: String?) -> String {
        switch state {
        case "insufficient_baseline", "building_baseline": "building baseline"
        case "no_large_change": "no large change detected"
        case "slower", "slowdown": "possible slowdown"
        case "alert", "change_detected": "change detected"
        case let state?: state.replacingOccurrences(of: "_", with: " ")
        case nil: "unavailable"
        }
    }

    private func signalReasonLabel(_ reason: String) -> String {
        switch reason {
        case "insufficient_baseline": "More baseline data is needed."
        case "no_large_change": "No large change was detected."
        case "slowdown": "A possible slowdown was detected."
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func periodValue(_ period: GlobalBoard.ComparisonPeriod?, unit: String, digits: Int) -> String {
        guard let median = period?.median else { return "— \(unit)" }
        return "\(String(format: "%.*f", digits, median)) \(unit)"
    }

    private func coverage(_ period: GlobalBoard.ComparisonPeriod?) -> String {
        guard let period else { return "unavailable" }
        let turns = period.turns.map(String.init) ?? "turn count unavailable"
        let contributors = period.contributors.map { "\($0) people" } ?? "contributor count unavailable"
        return "\(turns) turns, \(contributors)"
    }

    private func availability(_ value: String?) -> String {
        switch value {
        case "available": "comparison available"
        case "insufficient_current": "insufficient current data"
        case "insufficient_previous": "insufficient previous data"
        case "outside_retention": "previous period outside retention"
        case let value?: value.replacingOccurrences(of: "_", with: " ")
        case nil: "comparison status unavailable"
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%+.1f%%", $0) } ?? "change unavailable"
    }

    private func alertRow(_ alert: GlobalBoard.Alert) -> some View {
        Label(alert.message ?? "\(alert.model ?? "Community") · \(alert.metric == "ttft" ? "TTFT" : "turn throughput"): \((alert.state ?? "change detected").replacingOccurrences(of: "_", with: " "))", systemImage: "exclamationmark.circle")
            .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.warn)
    }

    private func windowLabel(_ window: String) -> String {
        switch window {
        case "15m": "15 min"
        case "24h", "24hr": "24 hours"
        case "7d": "7 days"
        case "30d": "30 days"
        default: window
        }
    }

    private func throughputCountLabel(_ cohort: GlobalBoard.Cohort) -> String {
        if let count = cohort.throughputTurns ?? cohort.throughputCount { return "n=\(count)" }
        return cohort.medianThroughput == nil ? "count unavailable" : "\(cohort.turns) turns"
    }

    private func ttftCountLabel(_ cohort: GlobalBoard.Cohort) -> String {
        if let count = cohort.ttftTurns ?? cohort.ttftCount { return "n=\(count)" }
        return "count unavailable"
    }

    private func statusTag(_ title: String, color: Color) -> some View {
        Text(title).font(DashboardStyle.Typography.captionEmphasis).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

}
