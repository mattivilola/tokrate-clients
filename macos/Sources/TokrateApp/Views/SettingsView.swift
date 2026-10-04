import SwiftUI

/// A titled group of settings rows on a surface card.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(DashboardStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DashboardStyle.line, lineWidth: 1)
                }
            if let footer {
                Text(footer)
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A settings page: scrolling content on the window background.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(DashboardStyle.bg)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, sharing, sources, updates
    var id: String { rawValue }
}

/// The Settings window: General, Sharing, Sources and Updates.
struct SettingsView: View {
    @Bindable var store: HistoryStore
    @ObservedObject var updates: AppUpdates
    @State var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            SettingsGeneralPage(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SettingsSharingPage(store: store, updates: updates)
                .tabItem { Label("Sharing", systemImage: "person.2") }
                .tag(SettingsTab.sharing)
            SettingsSourcesPage(store: store)
                .tabItem { Label("Sources", systemImage: "folder") }
                .tag(SettingsTab.sources)
            SettingsUpdatesPage(updates: updates)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.updates)
        }
        .frame(width: 560, height: 480)
        .tint(DashboardStyle.accent)
    }
}

struct SettingsGeneralPage: View {
    @Bindable var store: HistoryStore
    @AppStorage("showMenuBarSpeed") private var showMenuBarSpeed = true

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Menu bar", footer: "Shows the latest turn speed of the selected model. The value updates after completed turns; it is not a live streaming speed. Paused monitoring shows a dash.") {
                Toggle("Show speed in menu bar", isOn: $showMenuBarSpeed)
                    .toggleStyle(.switch)
                    .help("Shows recent whole-turn speed for the selected model. All models shows Compare without a pooled speed.")
            }
            SettingsGroup(title: "Monitoring", footer: "Pausing stops reads of your session files. Already-queued sharing stays active; turn sharing off to stop all community requests.") {
                HStack(spacing: 10) {
                    Circle().fill(store.isMonitoring ? DashboardStyle.good : DashboardStyle.muted).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(store.isMonitoring ? "Monitoring" : "Paused")
                        .font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                    Spacer()
                    Button(store.isMonitoring ? "Pause monitoring" : "Resume monitoring") {
                        if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingsGroup(title: "Launch") {
                Text("Tokrate runs as a menu-bar utility without a Dock icon and starts monitoring every time it opens. Your local history keeps seven days of completed turns.")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup(title: "Privacy") {
                Text("Prompts and responses are never retained. Only performance statistics can be shared, and only if you choose to.")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Privacy details", destination: URL(string: "https://tokrate.dev/privacy")!)
                    .font(DashboardStyle.Typography.footnoteEmphasis)
                    .foregroundStyle(DashboardStyle.accent)
            }
        }
    }
}

struct SettingsSharingPage: View {
    @Bindable var store: HistoryStore
    @ObservedObject var updates: AppUpdates

    var body: some View {
        SettingsPage {
            SharingView(
                preferences: store.sharingPreferences,
                selection: store.dashboardSelection,
                latestCohort: store.latestCohort,
                compact: false,
                showToggle: true,
                framed: true,
                checkForUpdates: { updates.checkForUpdates() }
            )
        }
    }
}

struct SettingsSourcesPage: View {
    @Bindable var store: HistoryStore

    var body: some View {
        SettingsPage {
            SettingsGroup(
                title: "Coding tools",
                footer: "Tokrate reads these session folders on this Mac, automatically, whenever monitoring is on. Choose a different Codex folder while monitoring is paused."
            ) {
                SourceStatusList(statuses: store.sourceStatuses) { status in
                    if status.client == "codex" { CodexFolderButton(store: store).buttonStyle(SecondaryButtonStyle()) }
                }
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsUpdatesPage: View {
    @ObservedObject var updates: AppUpdates

    var body: some View {
        SettingsPage { UpdateSettingsView(updates: updates) }
    }
}
