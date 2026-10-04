import SwiftUI

/// The software-update settings, shown on the Settings > Updates page.
struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdates
    @State private var automaticallyChecksForUpdates: Bool

    init(updates: AppUpdates) {
        self.updates = updates
        _automaticallyChecksForUpdates = State(initialValue: updates.automaticallyChecksForUpdates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Software updates") {
                if updates.isAvailable {
                    Toggle("Check automatically for Tokrate updates", isOn: $automaticallyChecksForUpdates)
                        .toggleStyle(.switch)
                        .onChange(of: automaticallyChecksForUpdates) { _, enabled in
                            updates.setAutomaticallyChecksForUpdates(enabled)
                        }

                    Text("Tokrate checks its signed update feed about once a day. Updates are downloaded and installed only after you choose to install them.")
                        .font(DashboardStyle.Typography.footnote)
                        .foregroundStyle(DashboardStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Check for Updates…") {
                        updates.checkForUpdates()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!updates.canCheckForUpdates)
                } else {
                    Text("Software updates are available in the signed release build.")
                        .font(DashboardStyle.Typography.footnote)
                        .foregroundStyle(DashboardStyle.muted)
                }
            }

            SettingsGroup(title: "Community sharing") {
                Text("Software update checks are separate from community sharing. Turning community sharing off does not disable update checks or send community measurements.")
                    .font(DashboardStyle.Typography.footnote)
                    .foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
