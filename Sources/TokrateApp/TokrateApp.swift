import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Intentional menu-bar utility: the dashboard opens on demand.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var historyStore = HistoryStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: historyStore)
        } label: {
            Label(historyStore.menuBarTitle, systemImage: "speedometer")
        }
        .menuBarExtraStyle(.menu)

        Window("Tokrate", id: "history") {
            HistoryView(store: historyStore)
                .frame(minWidth: 820, minHeight: 680)
        }
        .defaultSize(width: 940, height: 780)
    }
}
