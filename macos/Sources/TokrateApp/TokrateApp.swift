import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyStore = HistoryStore()
    let updates = AppUpdates()
    private var initialConsentWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the menu-bar utility quiet except when consent needs a visible first-run surface.
        NSApp.setActivationPolicy(.accessory)
        historyStore.startAutomatically()
        presentConsentDashboardIfNeeded()
    }

    func showInitialConsentDashboard() -> Bool {
        guard let initialConsentWindow else { return false }
        initialConsentWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func presentConsentDashboardIfNeeded() {
        guard historyStore.sharingPreferences.isConsentDisclosureVisible else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tokrate"
        window.minSize = NSSize(width: 820, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: HistoryView(store: historyStore, updates: updates)
                .frame(minWidth: 820, minHeight: 680)
        )
        window.center()
        initialConsentWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TokrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarSpeed") private var showMenuBarSpeed = true
    private var historyStore: HistoryStore { appDelegate.historyStore }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                store: historyStore,
                updates: appDelegate.updates,
                showInitialConsentDashboard: { appDelegate.showInitialConsentDashboard() }
            )
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                if showMenuBarSpeed {
                    Text(historyStore.menuBarTitle).monospacedDigit()
                }
            }
            .accessibilityLabel(showMenuBarSpeed ? "Tokrate, selected model comparison: \(historyStore.menuBarTitle)" : "Tokrate")
        }
        .menuBarExtraStyle(.window)

        Window("Tokrate", id: "history") {
            HistoryView(store: historyStore, updates: appDelegate.updates)
                .frame(minWidth: 820, minHeight: 680)
        }
        .defaultSize(width: 940, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.updates.checkForUpdates()
                }
                .disabled(!appDelegate.updates.canCheckForUpdates)
            }
        }

        Settings {
            UpdateSettingsView(updates: appDelegate.updates)
        }
    }
}
