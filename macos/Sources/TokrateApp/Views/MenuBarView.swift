import SwiftUI
import TokrateCore

struct MenuBarView: View {
    let store: HistoryStore
    @State private var range: DashboardRange = .today
    @AppStorage("showMenuBarSpeed") private var showMenuBarSpeed = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snapshot = DashboardSnapshot(records: store.records, range: range)
        ScrollView {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "speedometer").font(.system(size: 21, weight: .medium)).foregroundStyle(DashboardStyle.gradient)
                Text("Tokrate").font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer()
                Label(store.isMonitoring ? "Monitoring" : "Paused", systemImage: store.isMonitoring ? "circle.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                WebsiteLinkView(compact: true)
                Menu {
                    Button("Full history…") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
                    Button(store.isMonitoring ? "Pause monitoring" : "Resume monitoring") {
                        if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
                    }
                    Toggle("Show speed in menu bar", isOn: $showMenuBarSpeed)
                        .help("Shows the latest completed turn’s throughput, updated after each turn.")
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
            ThroughputGaugeView(metric: snapshot.latest)
            TrendChartView(snapshot: snapshot, range: $range)
            SummaryView(snapshot: snapshot)
            SharingView(preferences: store.sharingPreferences)
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
