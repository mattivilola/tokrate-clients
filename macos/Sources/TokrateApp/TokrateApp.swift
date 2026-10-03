import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyStore = HistoryStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Intentional menu-bar utility: the dashboard opens on demand.
        NSApp.setActivationPolicy(.accessory)
        historyStore.startAutomatically()
    }
}

@main
struct TokrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarSpeed") private var showMenuBarSpeed = true
    private var historyStore: HistoryStore { appDelegate.historyStore }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: historyStore)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                if showMenuBarSpeed {
                    Text(historyStore.menuBarTitle).monospacedDigit()
                }
            }
            .accessibilityLabel(showMenuBarSpeed ? "Tokrate, latest completed turn: \(historyStore.menuBarTitle)" : "Tokrate")
        }
        .menuBarExtraStyle(.window)

        Window("Tokrate", id: "history") {
            HistoryView(store: historyStore)
                .frame(minWidth: 820, minHeight: 680)
        }
        .defaultSize(width: 940, height: 780)
    }
}
