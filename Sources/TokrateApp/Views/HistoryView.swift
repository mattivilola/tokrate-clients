import Charts
import SwiftUI
import TokrateCore
import UniformTypeIdentifiers

struct HistoryView: View {
    let store: HistoryStore
    @State private var isChoosingFolder = false
    @State private var range: DashboardRange = .week

    private var sevenDayRecords: [TurnMetric] {
        let cutoff = Date.now.addingTimeInterval(-MetricHistory.retention)
        return store.records.filter { $0.completedAt >= cutoff }
    }

    var body: some View {
        let snapshot = DashboardSnapshot(records: store.records, range: range)
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 18) {
                ThroughputGaugeView(metric: snapshot.latest, compact: false).frame(width: 340)
                VStack(spacing: 18) {
                    TrendChartView(snapshot: snapshot, range: $range, compact: false)
                    SummaryView(snapshot: snapshot)
                }
            }
            SharingView(preferences: store.sharingPreferences, compact: false)
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
                HStack {
                    Text("Recent turns").font(.headline)
                    Spacer()
                    Text("Latest \(min(500, sevenDayRecords.count)) of \(sevenDayRecords.count.formatted()) · seven days").font(.caption).foregroundStyle(.secondary)
                }
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

    private var metricsTable: some View {
        Table(Array(sevenDayRecords.prefix(500))) {
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
