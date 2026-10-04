import SwiftUI

/// The single model control in the popover header. Sections: Latest, one per coding tool with its
/// model entries, Compare all models, then the Coding tool and Provider filters.
struct ModelPickerMenu: View {
    @Bindable var store: HistoryStore

    var body: some View {
        let cohorts = store.availableCohorts
        Menu {
            Picker("Model", selection: $store.dashboardSelection) {
                Text("Latest completed model").tag(DashboardSelection.latest)
            }
            .pickerStyle(.inline).labelsHidden()
            ForEach(ModelPickerGrouping.sections(cohorts: cohorts)) { section in
                Section(section.title) {
                    Picker(section.title, selection: $store.dashboardSelection) {
                        ForEach(section.entries) { entry in
                            Text(entry.menuTitle).tag(DashboardSelection.cohort(entry.cohort))
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            Divider()
            Picker("Comparison", selection: $store.dashboardSelection) {
                Text("Compare all models").tag(DashboardSelection.all)
            }
            .pickerStyle(.inline).labelsHidden()
            Divider()
            Menu("Coding tool") {
                CodingToolFilterPicker(client: $store.clientFilter, clients: store.availableClients)
            }
            Menu("Provider") {
                ProviderFilterPicker(provider: $store.providerFilter, providers: store.availableProviders)
            }
        } label: {
            MenuFieldLabel(text: ModelPickerGrouping.label(selection: store.dashboardSelection, latest: store.latestCohort, cohorts: cohorts))
                .frame(maxWidth: 200)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model")
        .accessibilityValue(store.dashboardSelection.displayLabel(latest: store.latestCohort))
        .accessibilityHint("Choose the model, coding tool or provider to show")
        .help(store.dashboardSelection.displayLabel(latest: store.latestCohort))
    }
}
