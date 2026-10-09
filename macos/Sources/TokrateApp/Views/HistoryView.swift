import Charts
import SwiftUI
import TokrateCore

/// Root of the history window. The window stays alive after it is closed, so the history only
/// renders while the window is on screen; the selected range survives closing.
struct HistoryWindowView: View {
    let store: HistoryStore
    let updates: AppUpdates
    @State private var range: DashboardRange = .week

    var body: some View {
        WindowVisibilityGate {
            HistoryView(store: store, updates: updates, range: $range)
        }
        .frame(minWidth: 820, minHeight: 680)
    }
}

/// The full history window: filters, a large gauge, the trend chart, summaries and the latest 500 turns.
struct HistoryView: View {
    @Bindable var store: HistoryStore
    @ObservedObject var updates: AppUpdates
    @Binding var range: DashboardRange

    var body: some View {
        let now = Date.now
        let snapshot = DashboardSnapshot(
            records: store.records,
            range: range,
            selection: store.dashboardSelection,
            activeModel: store.activeModel,
            now: now,
            clientFilter: store.clientFilter,
            providerFilter: store.providerFilter
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.sharingPreferences.isConsentDisclosureVisible {
                    SharingView(preferences: store.sharingPreferences, selection: store.dashboardSelection, resolvedCohort: store.resolvedCohort, compact: false, showToggle: false, checkForUpdates: { updates.checkForUpdates() })
                }
                HStack(alignment: .center, spacing: 10) {
                    CohortSelectionView(selection: $store.dashboardSelection, cohorts: store.availableCohorts, clients: store.availableClients, records: store.filteredRecords, resolved: store.resolvedCohort)
                    ClientProviderFilterView(client: $store.clientFilter, provider: $store.providerFilter, clients: store.availableClients, providers: store.availableProviders)
                        .fixedSize()
                }
                if snapshot.selection.isAllModels {
                    CohortComparisonView(snapshot: snapshot, range: $range, compact: false) { cohort in
                        store.dashboardSelection = .cohort(cohort)
                    }
                } else {
                    let reading = snapshot.heroReading(live: store.liveSpeed, liveGroup: store.liveSpeed == nil ? nil : store.menuBarReadout.group)
                    HStack(alignment: .top, spacing: 18) {
                        ThroughputGaugeView(
                            reading: reading,
                            compact: false,
                            delta: snapshot.speedDelta(for: reading),
                            slowerThanUsual: snapshot.personalTrend?.status == .slower,
                            groupMedian: reading.usesResponseSpeed ? snapshot.responseGaugeMedian : snapshot.turnGaugeMedian,
                            now: now
                        )
                        .frame(width: 360)
                        VStack(spacing: 14) {
                            TrendChartView(snapshot: snapshot, range: $range, compact: false)
                            SummaryView(snapshot: snapshot)
                            PersonalTrendView(trend: snapshot.personalTrend, reasoningEffort: snapshot.selectedCohort?.reasoningEffort)
                        }
                    }
                }
                SharingView(
                    preferences: store.sharingPreferences,
                    selection: store.dashboardSelection,
                    resolvedCohort: store.resolvedCohort,
                    compact: false,
                    showToggle: !store.sharingPreferences.isConsentDisclosureVisible,
                    showConsentDisclosure: false,
                    checkForUpdates: { updates.checkForUpdates() }
                )
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(DashboardStyle.Typography.body)
                        .foregroundStyle(DashboardStyle.danger)
                }
                if snapshot.records.isEmpty {
                    ContentUnavailableView {
                        Label(store.records.isEmpty ? "No turn history yet" : "No turns in this range", systemImage: "chart.xyaxis.line")
                            .foregroundStyle(DashboardStyle.ink)
                    } description: {
                        Text(store.records.isEmpty ? (store.isMonitoring ? "Reading completed turns from Codex, Claude Code, Grok Build, Antigravity, OpenCode, and Kimi Code. Large histories may take a moment." : "Choose Start monitoring to read local session files. Prompts and responses are never retained.") : "Choose 7 days or select another client, provider, or model cohort to view its local turns.")
                            .foregroundStyle(DashboardStyle.muted)
                    } actions: {
                        Button("Start monitoring") { store.startMonitoring() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(store.isMonitoring)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    HStack {
                        Text("Recent turns").font(DashboardStyle.Typography.title).foregroundStyle(DashboardStyle.ink)
                        Spacer()
                        Text("Latest \(min(500, snapshot.records.count)) of \(snapshot.records.count.formatted()) · \(range.title.lowercased())")
                            .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
                    }
                    metricsTable(records: snapshot.records)
                }
                footer
            }
            .padding(24)
        }
        .background(DashboardStyle.bg)
        .tint(DashboardStyle.accent)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            BrandMarkView(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Tokrate")
                    .font(DashboardStyle.Typography.largeTitle).tracking(-0.4)
                    .foregroundStyle(DashboardStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Response speed · output tokens per second while the model is responding")
                    .font(DashboardStyle.Typography.footnote)
                    .foregroundStyle(DashboardStyle.muted)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!updates.canCheckForUpdates)
                WebsiteLinkView()
                Button(store.isMonitoring ? "Pause" : "Start monitoring") {
                    if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
                }
                .buttonStyle(PrimaryButtonStyle())
                SourceFolderButton(store: store)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func metricsTable(records: [TurnMetric]) -> some View {
        Table(Array(records.prefix(500))) {
            TableColumn("Completed") { record in
                Text(record.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(DashboardStyle.Typography.footnote)
            }
            .width(min: 130)
            TableColumn("Model") { record in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.model ?? "Unknown")
                            .foregroundStyle(record.model == nil ? DashboardStyle.muted : DashboardStyle.ink)
                        if record.isSubagentTurn { ChipView(text: "Subagent", tone: .accent).fixedSize() }
                    }
                    Text(ModelCohort(record).detailLabel)
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted).lineLimit(1)
                }
            }
            .width(min: 190)
            TableColumn("Output tokens") { record in
                Text(record.outputTokens.formatted())
                    .monospacedDigit()
            }
            .width(min: 110)
            TableColumn("Tokens/request") { record in
                requestTokens(record)
            }
            .width(min: 110)
            TableColumn("Turn time") { record in
                Text("\(record.durationSeconds, specifier: "%.1f") s")
                    .monospacedDigit()
            }
            .width(min: 90)
            TableColumn("First token") { record in
                Text(record.ttftSeconds.map { String(format: "%.2f s", $0) } ?? "—")
                    .monospacedDigit()
                    .help("Source-reported first-token wait when available; first-visible-text semantics are unverified.")
            }
            .width(min: 100)
            TableColumn("Response speed") { record in
                if let speed = record.responseSpeedTPS, let count = record.responseCount {
                    Text("\(speed, specifier: "%.1f") tok/s · \(count)")
                        .monospacedDigit()
                        .help("\(count) \(count == 1 ? "response" : "responses"): \(record.client == ResponseSpeedCopy.grokBuildClient ? ResponseSpeedCopy.grokBuildExplanation : ResponseSpeedCopy.definition)")
                } else {
                    Text("—").foregroundStyle(DashboardStyle.muted)
                        .help("No response of at least 200 output tokens, or no response timing was recorded for this turn.")
                }
            }
            .width(min: 140)
            TableColumn("Turn speed") { record in
                Text("\(record.turnThroughputTPS, specifier: "%.1f") tok/s")
                    .monospacedDigit()
                    .help(ModelCohort(record).measurement.title)
            }
            .width(min: 110)
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous).strokeBorder(DashboardStyle.line, lineWidth: 1)
        }
    }

    /// Output plus delegated subagent tokens of a request. While delegated work is not final the plain
    /// output count shows muted; a subagent turn is counted in the request that started it.
    @ViewBuilder
    private func requestTokens(_ record: TurnMetric) -> some View {
        if let total = EfficiencyIndicator.totalTokens(record) {
            Text(total.formatted()).monospacedDigit()
                .help("Output tokens plus delegated subagent work")
        } else if record.isSubagentTurn {
            Text("—").foregroundStyle(DashboardStyle.muted)
                .help("Counted in the request that started it")
        } else {
            Text(record.outputTokens.formatted()).monospacedDigit().foregroundStyle(DashboardStyle.muted)
                .help("Delegated work not yet counted")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isMonitoring ? DashboardStyle.good : DashboardStyle.muted).frame(width: 8, height: 8)
            Text(store.isMonitoring ? "Monitoring" : "Paused")
                .font(DashboardStyle.Typography.footnoteEmphasis)
                .foregroundStyle(DashboardStyle.ink)
            Text("· \(store.folderDescription)")
                .foregroundStyle(DashboardStyle.muted)
                .lineLimit(1)
                .help(store.folderDescription)
            Spacer()
            Text("Response speed excludes tools and waiting · streaming speed unavailable · first-token semantics unverified")
                .foregroundStyle(DashboardStyle.muted)
        }
        .font(DashboardStyle.Typography.footnote)
    }
}
