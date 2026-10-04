import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyStore = HistoryStore()
    let updates = AppUpdates()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the menu-bar utility quiet except when consent needs a visible first-run surface.
        NSApp.setActivationPolicy(.accessory)
        historyStore.startAutomatically()
        presentOnboardingIfNeeded()
    }

    /// Reopens onboarding while the sharing choice is still pending. Returns false when it is not,
    /// so callers fall through to their normal destination.
    func showInitialConsentDashboard() -> Bool {
        guard historyStore.sharingPreferences.isConsentDisclosureVisible else { return false }
        presentOnboarding()
        return true
    }

    private func presentOnboardingIfNeeded() {
        guard historyStore.sharingPreferences.isConsentDisclosureVisible else { return }
        presentOnboarding()
    }

    private func presentOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Tokrate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OnboardingView(store: historyStore, onFinish: { [weak window] in window?.close() })
        )
        window.center()
        onboardingWindow = window
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
                Image(nsImage: MenuBarIcon.image)
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
            SettingsView(store: historyStore, updates: appDelegate.updates)
        }
    }
}
