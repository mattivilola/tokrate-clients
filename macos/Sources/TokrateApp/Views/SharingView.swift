import SwiftUI
import TokrateCore

struct SharingView: View {
    let preferences: SharingPreferences
    var compact = true
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
                Toggle("Share with community", isOn: Binding(
                    get: { preferences.isSharingRequested },
                    set: { preferences.setSharingEnabled($0) }
                ))
                .toggleStyle(.switch).labelsHidden().tint(.teal)
                .accessibilityHint("Remembers your choice. Turning off cancels community requests.")
            }
            if preferences.isSharingRequested {
                VStack(alignment: .leading, spacing: 7) {
                    Text(sharing.status + (sharing.pendingCount > 0 ? " · \(sharing.pendingCount) pending" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !sharing.isEnabled {
                        Button("Retry sharing") { preferences.retry() }.buttonStyle(.link).font(.caption)
                    } else if let board = sharing.board {
                        if !board.collectionEnabled {
                            Label("Community collection is paused", systemImage: "pause.circle").font(.caption)
                        } else if board.state == "insufficient_data" {
                            Label("Community comparison is gathering data", systemImage: "chart.xyaxis.line")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("Community · \(board.window == "15m" ? "15 min" : "24 hours")")
                                Spacer()
                                if board.state == "stale" { Text("Older data").foregroundStyle(.orange) }
                            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            ForEach(board.cohorts.prefix(compact ? 2 : 5)) { cohort in
                                HStack {
                                    Text(cohort.model).lineLimit(1)
                                    Spacer()
                                    Text(cohort.medianThroughput.map { String(format: "%.1f t/s", $0) } ?? "—").monospacedDigit()
                                    Text("\(cohort.contributors) contributors").foregroundStyle(.secondary)
                                }.font(.system(size: 10))
                            }
                            ForEach(board.alerts.prefix(compact ? 1 : 3)) { alert in
                                Label(alert.message ?? "\(alert.model ?? "Community") · \(alert.metric == "ttft" ? "Codex TTFT" : "turn throughput"): \((alert.state ?? "change detected").replacingOccurrences(of: "_", with: " "))", systemImage: "exclamationmark.circle")
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
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
}
