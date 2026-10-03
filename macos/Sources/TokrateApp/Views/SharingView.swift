import SwiftUI
import TokrateCore

struct SharingView: View {
    let preferences: SharingPreferences
    let selection: DashboardSelection
    let latestCohort: ModelCohort?
    var compact = true
    var showToggle = true
    private var sharing: SharingSession { preferences.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: preferences.isSharingRequested ? "globe.americas.fill" : "lock.shield")
                    .font(.system(size: 20)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share with community").font(.system(size: 12, weight: .semibold))
                    Text(preferences.isSharingRequested ? (sharing.isEnabled ? "On · new turn measurements only" : "On · sharing needs attention") : "Off · your measurements stay local")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if showToggle {
                    Toggle("Share with community", isOn: Binding(
                        get: { preferences.isSharingRequested },
                        set: { preferences.setSharingEnabled($0) }
                    ))
                    .toggleStyle(.switch).labelsHidden().tint(.teal)
                    .accessibilityHint("Remembers your choice. Turning off cancels community requests.")
                }
            }
            if preferences.isSharingRequested {
                VStack(alignment: .leading, spacing: 7) {
                    Text(sharing.status + (sharing.pendingCount > 0 ? " · \(sharing.pendingCount) pending" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !sharing.isEnabled {
                        Button("Retry sharing") { preferences.retry() }.buttonStyle(.link).font(.caption)
                    } else if let board = sharing.board {
                        boardContent(board)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("No prompts or code. Your choice is remembered.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Link("Privacy", destination: URL(string: "https://tokrate.dev/privacy")!).font(.system(size: 9))
            }
        }
        .dashboardCard(padding: 12)
    }

    @ViewBuilder
    private func boardContent(_ board: GlobalBoard) -> some View {
        if !board.collectionEnabled {
            Label("Community collection is paused", systemImage: "pause.circle").font(.caption)
        } else {
            HStack(spacing: 6) {
                Text("Community · \(windowLabel(board.window))")
                if board.state == "stale" {
                    statusTag("Older data", color: .orange)
                }
                if board.state == "insufficient_data" || board.publicationMode == "early_data" {
                    statusTag("Early data", color: .secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)

            if selection.isAllModels {
                if board.cohorts.isEmpty {
                    Text("Community comparison is gathering data.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(board.cohorts) { cohort in communityRow(cohort) }
                    ForEach(matchingAlerts(in: board, cohorts: board.cohorts)) { alert in alertRow(alert) }
                }
            } else if let target = selectedCohort {
                let matches = board.cohorts.filter { exactlyMatches($0, target: target) }
                if matches.isEmpty {
                Text("Community data for this exact model, provider, client version, and reasoning effort is not available yet.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(matches) { cohort in communityRow(cohort) }
                    ForEach(matchingAlerts(in: board, cohorts: matches)) { alert in alertRow(alert) }
                }
            } else {
                Text("Choose a reported model and client version to see its community comparison.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if let methodology = board.methodology?.statistics ?? board.methodology?.source {
                Text("Method: \(methodology)")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Community rows use reported primary-client samples. Effort is shown when reported; speed tier and workload are uncontrolled.")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedCohort: ModelCohort? {
        switch selection {
        case .latest: latestCohort
        case .cohort(let cohort): cohort
        case .all: nil
        }
    }

    private func exactlyMatches(_ cohort: GlobalBoard.Cohort, target: ModelCohort) -> Bool {
        guard let expectedID = target.communityBoardID else { return false }
        return cohort.id == expectedID
    }

    private func communityRow(_ cohort: GlobalBoard.Cohort) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(cohort.model).lineLimit(1)
                Text("· \(cohort.provider)").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(cohort.medianThroughput.map { String(format: "%.1f t/s", $0) } ?? "—")
                    .monospacedDigit().fontWeight(.medium)
            }
            Text("\(cohort.client ?? "client unknown") · client \(cohort.clientVersion ?? "version unknown") · reasoning effort \(cohort.reasoningEffort.flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil } ?? "unknown")")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Spacer(minLength: 4)
                if let minimum = cohort.minThroughput, let maximum = cohort.maxThroughput {
                    Text("min \(String(format: "%.1f", minimum)) · max \(String(format: "%.1f", maximum))")
                        .monospacedDigit()
                }
                Text("· \(throughputCountLabel(cohort))")
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .font(.system(size: 9))
            if let median = cohort.medianTtftMs {
                HStack(spacing: 4) {
                    Text("Codex TTFT median \(String(format: "%.0f", median)) ms")
                    if let minimum = cohort.minTtftMs, let maximum = cohort.maxTtftMs {
                        Text("· min \(String(format: "%.0f", minimum)) · max \(String(format: "%.0f", maximum)) ms")
                    }
                    Text("· \(ttftCountLabel(cohort))")
                }
                .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .padding(.vertical, 3)
    }

    private func matchingAlerts(in board: GlobalBoard, cohorts: [GlobalBoard.Cohort]) -> [GlobalBoard.Alert] {
        let ids = Set(cohorts.map(\.id))
        return board.alerts.filter { alert in
            if let cohortId = alert.cohortId { return ids.contains(cohortId) }
            guard let model = alert.model, let provider = alert.provider, let version = alert.clientVersion else { return false }
            let matchingRows = board.cohorts.filter { $0.model == model && $0.provider == provider && $0.clientVersion == version }
            guard matchingRows.count == 1, let match = matchingRows.first else { return false }
            return cohorts.contains { $0.id == match.id }
        }
    }

    private func alertRow(_ alert: GlobalBoard.Alert) -> some View {
        Label(alert.message ?? "\(alert.model ?? "Community") · \(alert.metric == "ttft" ? "Codex TTFT" : "turn throughput"): \((alert.state ?? "change detected").replacingOccurrences(of: "_", with: " "))", systemImage: "exclamationmark.circle")
            .font(.system(size: 10)).foregroundStyle(.orange)
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
        Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

}
