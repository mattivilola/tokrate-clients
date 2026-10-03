import SwiftUI
import TokrateCore

struct SharingView: View {
    let sharing: SharingSession
    @State private var showingConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(sharing.isEnabled ? "Community sharing" : "Local only", systemImage: sharing.isEnabled ? "network" : "lock.shield")
                    .font(.headline)
                Spacer()
                Toggle("Share new turns", isOn: Binding(
                    get: { sharing.isEnabled },
                    set: { enabled in if enabled { showingConsent = true } else { sharing.disable() } }
                ))
                .toggleStyle(.switch)
            }
            if sharing.isEnabled {
                Text(sharing.status + (sharing.pendingCount > 0 ? " · \(sharing.pendingCount) pending" : ""))
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Your seven-day history stays on this Mac. Sharing is optional; community statistics appear only while sharing is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .alert("Share future turn measurements?", isPresented: $showingConsent) {
            Button("Cancel", role: .cancel) { }
            Button("Enable sharing") { sharing.enable() }
        } message: {
            Text("Send model, software versions, token counts, whole-turn timing, Codex-reported TTFT, and five-minute time buckets to tokrate.dev. No prompts, responses, paths, or session/account IDs are sent. A random signing identity is saved in Keychain so the service can recognize this installation; your IP is visible during requests. Only new turns are shared. Turning sharing off stops requests, clears pending uploads, and hides community data; it cannot retract samples already received.")
        }
    }
}
