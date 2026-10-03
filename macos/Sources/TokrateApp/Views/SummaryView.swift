import SwiftUI

struct SummaryView: View {
    let snapshot: DashboardSnapshot
    var body: some View {
        HStack(spacing: 0) {
            metric("Median", value: DashboardSnapshot.rate(snapshot.medianRate), unit: "t/s")
            Divider().frame(height: 32)
            metric("Completed", value: snapshot.turnCount.formatted(), unit: "turns")
            Divider().frame(height: 32)
            metric("Codex TTFT", value: snapshot.medianTTFT.map { String(format: "%.2f", $0) } ?? "—", unit: "s")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .help(title == "Codex TTFT" ? "Median Codex-reported time to first token; first-visible-text semantics are unverified." : "\(title) for the selected history range.")
    }
}
