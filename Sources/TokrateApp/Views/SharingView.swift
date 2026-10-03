import SwiftUI
import TokrateCore

struct SharingView: View {
    let preferences: SharingPreferences
    private var sharing: SharingSession { preferences.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(preferences.isSharingRequested ? (sharing.isEnabled ? "Community sharing" : "Sharing needs attention") : "Local only", systemImage: sharing.isEnabled ? "network" : "lock.shield")
                    .font(.headline)
                Spacer()
                Toggle("Share new turns", isOn: Binding(
                    get: { preferences.isSharingRequested },
                    set: { preferences.setSharingEnabled($0) }
                ))
                .toggleStyle(.switch)
            }
            Text("Shares new turn measurements with tokrate.dev. No prompts, responses, code, paths, or session/account IDs. Switching off keeps measurements local and is remembered next time.")
                .font(.caption).foregroundStyle(.secondary)
            if preferences.isSharingRequested {
                Text(sharing.status + (sharing.pendingCount > 0 ? " · \(sharing.pendingCount) pending" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if !sharing.isEnabled {
                    Button("Retry sharing") { preferences.retry() }
                        .buttonStyle(.link)
                }
                if let board = sharing.board {
                    if !board.collectionEnabled {
                        Label("Community collection is paused", systemImage: "pause.circle")
                    } else if board.state == "insufficient_data" {
                        Text("Waiting for enough contributors to show a private community comparison.")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Community · \(board.window == "15m" ? "last 15 minutes" : "last 24 hours")")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if board.state == "stale" { Label("Older data", systemImage: "clock").foregroundStyle(.orange) }
                        }
                        ForEach(board.cohorts.prefix(5)) { cohort in
                            HStack {
                                Text(cohort.model).lineLimit(1)
                                Spacer()
                                Text(cohort.medianThroughput.map { String(format: "%.1f t/s", $0) } ?? "—")
                                    .monospacedDigit()
                                Text("\(cohort.contributors) contributors").foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                        ForEach(board.alerts.prefix(3)) { alert in
                            Label(alert.message ?? "\(alert.model ?? "Community") · \(alert.metric == "ttft" ? "Codex TTFT" : "turn throughput"): \((alert.state ?? "change detected").replacingOccurrences(of: "_", with: " "))", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("Community data will appear when available.").foregroundStyle(.secondary)
                }
            } else {
                Text("Sharing is off. No community requests are made; your seven-day history stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Link("Privacy details", destination: URL(string: "https://tokrate.dev/privacy")!)
                .font(.caption)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
