import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdates
    @State private var automaticallyChecksForUpdates: Bool

    init(updates: AppUpdates) {
        self.updates = updates
        _automaticallyChecksForUpdates = State(initialValue: updates.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Section("Software updates") {
                if updates.isAvailable {
                    Toggle("Check automatically for Tokrate updates", isOn: $automaticallyChecksForUpdates)
                        .onChange(of: automaticallyChecksForUpdates) { _, enabled in
                            updates.setAutomaticallyChecksForUpdates(enabled)
                        }

                    Text("Tokrate checks its signed update feed about once a day. Updates are downloaded and installed only after you choose to install them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Check for Updates…") {
                        updates.checkForUpdates()
                    }
                    .disabled(!updates.canCheckForUpdates)
                } else {
                    Text("Software updates are available in the signed release build.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Community sharing") {
                Text("Software update checks are separate from community sharing. Turning community sharing off does not disable update checks or send community measurements.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 250)
        .padding(.vertical, 8)
    }
}
