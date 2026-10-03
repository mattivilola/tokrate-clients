import SwiftUI
import TokrateCore

struct SummaryView: View {
    let records: [TurnMetric]
    var body: some View {
        HStack(spacing: 16) {
            metric("Latest turn", value: records.first.map { String(format: "%.1f", $0.turnThroughputTPS) } ?? "—", detail: "output tokens / whole-turn second")
            metric("Seven-day median", value: median.map { String(format: "%.1f", $0) } ?? "—", detail: "includes tools, waits, and reasoning")
            metric("Completed turns", value: records.count.formatted(), detail: "stored only on this Mac")
        }
    }
    private var median: Double? {
        let values = records.map(\.turnThroughputTPS).sorted()
        guard !values.isEmpty else { return nil }
        return values.count.isMultiple(of: 2) ? (values[values.count / 2 - 1] + values[values.count / 2]) / 2 : values[values.count / 2]
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
