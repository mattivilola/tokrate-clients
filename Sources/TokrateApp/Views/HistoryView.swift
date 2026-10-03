import Charts
import SwiftUI
import TokrateCore
import UniformTypeIdentifiers

struct HistoryView: View {
    let store: HistoryStore
    @State private var isChoosingFolder = false

    private var sevenDayRecords: [TurnMetric] {
        let cutoff = Date.now.addingTimeInterval(-MetricHistory.retention)
        return store.records.filter { $0.completedAt >= cutoff }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            SummaryView(records: sevenDayRecords)
            SharingView(preferences: store.sharingPreferences)
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if sevenDayRecords.isEmpty {
                ContentUnavailableView {
                    Label("No turn history yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(store.isMonitoring ? "Reading completed Codex turns. Large histories may take a moment." : "Choose Start monitoring to read local Codex session files. Prompts and responses are never retained.")
                } actions: {
                    Button("Start monitoring") { store.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isMonitoring)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                throughputChart
                metricsTable
            }
            footer
        }
        .padding(22)
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.selectFolder(url) }
            case .failure:
                break
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tokrate")
                    .font(.largeTitle.weight(.semibold))
                Text("Completed-turn throughput · output tokens per whole-turn second")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.isMonitoring ? "Pause" : "Start monitoring") {
                if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
            }
            .buttonStyle(.borderedProminent)
            Button("Choose folder…") { isChoosingFolder = true }
                .disabled(store.isMonitoring)
        }
    }

    private var throughputChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last seven days")
                .font(.headline)
            Chart(sevenDayRecords) { record in
                PointMark(
                    x: .value("Completed", record.completedAt),
                    y: .value("Turn throughput", record.turnThroughputTPS)
                )
                .foregroundStyle(.blue)
                .symbolSize(42)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
                }
            }
            .chartYAxisLabel("Output tokens / whole-turn second")
            .frame(height: 145)
            .padding(.horizontal, 4)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var metricsTable: some View {
        Table(sevenDayRecords) {
            TableColumn("Completed") { record in
                Text(record.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            }
            .width(min: 130)
            TableColumn("Model") { record in
                Text(record.model ?? "Unknown")
                    .foregroundStyle(record.model == nil ? .secondary : .primary)
            }
            .width(min: 110)
            TableColumn("Output tokens") { record in
                Text(record.outputTokens.formatted())
                    .monospacedDigit()
            }
            .width(min: 110)
            TableColumn("Turn time") { record in
                Text("\(record.durationSeconds, specifier: "%.1f") s")
                    .monospacedDigit()
            }
            .width(min: 90)
            TableColumn("Codex TTFT") { record in
                Text(record.codexTTFTSeconds.map { String(format: "%.2f s", $0) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 100)
            TableColumn("Turn throughput") { record in
                Text("\(record.turnThroughputTPS, specifier: "%.1f") t/s")
                    .monospacedDigit()
            }
            .width(min: 120)
        }
        .frame(height: 210)
    }

    private var footer: some View {
        HStack {
            Label(store.isMonitoring ? "Monitoring" : "Paused", systemImage: store.isMonitoring ? "record.circle" : "pause.circle")
                .foregroundStyle(store.isMonitoring ? .green : .secondary)
            Text("· \(store.folderDescription)")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Streaming speed unavailable · Codex TTFT semantics unverified")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
