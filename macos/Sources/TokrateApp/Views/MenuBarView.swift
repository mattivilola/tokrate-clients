import SwiftUI
import TokrateCore

struct MenuBarView: View {
    @Bindable var store: HistoryStore
    @State private var range: DashboardRange = .day
    @AppStorage("showMenuBarSpeed") private var showMenuBarSpeed = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snapshot = DashboardSnapshot(records: store.records, range: range, selection: store.dashboardSelection)
        ScrollView {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "speedometer").font(.system(size: 21, weight: .medium)).foregroundStyle(DashboardStyle.gradient)
                Text("Tokrate").font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer()
                Label(store.isMonitoring ? "Monitoring" : "Paused", systemImage: store.isMonitoring ? "circle.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text("Share").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Toggle("Share with community", isOn: Binding(
                        get: { store.sharingPreferences.isSharingRequested },
                        set: { store.sharingPreferences.setSharingEnabled($0) }
                    ))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini).frame(width: 31)
                    .accessibilityLabel("Share with community")
                    .accessibilityHint("Remembers your choice. Turning off cancels community requests.")
                    .help("Share new turn measurements with the community")
                }
                WebsiteLinkView(compact: true)
                Menu {
                    Button("Full history…") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
                    Button(store.isMonitoring ? "Pause monitoring" : "Resume monitoring") {
                        if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
                    }
                    Toggle("Show speed in menu bar", isOn: $showMenuBarSpeed)
                        .help("Shows recent whole-turn throughput for the selected model cohort. All models shows Compare without a pooled speed.")
                    Divider()
                    Link("Privacy details", destination: URL(string: "https://tokrate.dev/privacy")!)
                    Button("Quit Tokrate") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Tokrate settings and full history")
            }
            .padding(.horizontal, 4).padding(.bottom, 2)
            CohortSelectionView(selection: $store.dashboardSelection, cohorts: store.availableCohorts, latest: store.latestCohort)
            if snapshot.selection.isAllModels {
                CohortComparisonView(snapshot: snapshot, range: $range)
            } else {
                SummaryView(snapshot: snapshot)
                ThroughputGaugeView(metric: snapshot.latest)
                TrendChartView(snapshot: snapshot, range: $range)
                PersonalTrendView(trend: snapshot.personalTrend, reasoningEffort: snapshot.selectedCohort?.reasoningEffort)
            }
            SharingView(preferences: store.sharingPreferences, selection: store.dashboardSelection, latestCohort: store.latestCohort, showToggle: false)
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2).help(error)
            }
        }
        .padding(16)
        }
        .frame(width: 460, height: 680)
        .background(.regularMaterial)
    }
}
