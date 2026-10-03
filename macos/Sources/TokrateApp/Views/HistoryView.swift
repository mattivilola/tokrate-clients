import Charts
import SwiftUI
import TokrateCore
import UniformTypeIdentifiers

struct HistoryView: View {
    @Bindable var store: HistoryStore
    @State private var isChoosingFolder = false
    @State private var range: DashboardRange = .week

    var body: some View {
        let snapshot = DashboardSnapshot(records: store.records, range: range, selection: store.dashboardSelection)
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            CohortSelectionView(selection: $store.dashboardSelection, cohorts: store.availableCohorts, latest: store.latestCohort)
            if snapshot.selection.isAllModels {
                CohortComparisonView(snapshot: snapshot, range: $range, compact: false)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ThroughputGaugeView(metric: snapshot.latest, compact: false).frame(width: 340)
                    VStack(spacing: 12) {
                        TrendChartView(snapshot: snapshot, range: $range, compact: false)
                        SummaryView(snapshot: snapshot)
                        PersonalTrendView(trend: snapshot.personalTrend)
                    }
                }
            }
            SharingView(preferences: store.sharingPreferences, selection: store.dashboardSelection, latestCohort: store.latestCohort, compact: false)
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if snapshot.records.isEmpty {
                ContentUnavailableView {
                    Label(store.records.isEmpty ? "No turn history yet" : "No turns in this range", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(store.records.isEmpty ? (store.isMonitoring ? "Reading completed Codex turns. Large histories may take a moment." : "Choose Start monitoring to read local Codex session files. Prompts and responses are never retained.") : "Choose 7 days or select another model cohort to view its local turns.")
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
                    Text("Latest \(min(500, snapshot.records.count)) of \(snapshot.records.count.formatted()) · \(range.title.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                metricsTable(records: snapshot.records)
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
            WebsiteLinkView()
            Button(store.isMonitoring ? "Pause" : "Start monitoring") {
                if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
            }
            .buttonStyle(.borderedProminent)
            Button("Choose folder…") { isChoosingFolder = true }
                .disabled(store.isMonitoring)
        }
    }

    private func metricsTable(records: [TurnMetric]) -> some View {
        Table(Array(records.prefix(500))) {
            TableColumn("Completed") { record in
                Text(record.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            }
            .width(min: 130)
            TableColumn("Model") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.model ?? "Unknown")
                        .foregroundStyle(record.model == nil ? .secondary : .primary)
                    Text([record.provider, record.clientVersion.map { "client \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 190)
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
