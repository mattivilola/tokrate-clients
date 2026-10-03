import SwiftUI
import TokrateCore

struct MenuBarView: View {
    let store: HistoryStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let latest = store.records.first {
            Text("Latest turn throughput")
            Text(latest.completedAt, style: .relative)
            Text("\(latest.outputTokens) output tokens · \(latest.durationSeconds, specifier: "%.1f") s")
            Text("\(latest.turnThroughputTPS, specifier: "%.1f") tokens/s")
        } else {
            Text("No completed turns yet")
        }

        Divider()
        Button("Open dashboard") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
        if store.isMonitoring {
            Button("Pause monitoring") { store.stopMonitoring() }
        } else {
            Button("Start monitoring") { store.startMonitoring() }
        }
        Text(store.sharing.isEnabled ? "Community sharing on" : "Local only")
        Text("Streaming TPS unavailable")
            .foregroundStyle(.secondary)
        Divider()
        Button("Quit Tokrate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
