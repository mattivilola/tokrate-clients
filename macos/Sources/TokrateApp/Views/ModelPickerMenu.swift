import SwiftUI

/// The single model control in the popover header. Items: Auto, Auto within a coding tool, one
/// section per coding tool with its model entries, Compare all models, then the Coding tool and
/// Provider filters. In Auto mode the label follows the active model: "Auto · claude-opus-5-5".
struct ModelPickerMenu: View {
    @Bindable var store: HistoryStore

    var body: some View {
        let cohorts = store.availableCohorts
        let resolved = store.resolvedCohort
        Menu {
            ModelSelectionItems(selection: $store.dashboardSelection, cohorts: cohorts, clients: store.availableClients)
            Divider()
            Menu("Coding tool") {
                CodingToolFilterPicker(client: $store.clientFilter, clients: store.availableClients)
            }
            Menu("Provider") {
                ProviderFilterPicker(provider: $store.providerFilter, providers: store.availableProviders)
            }
        } label: {
            HStack(spacing: 5) {
                if let resolved, !store.dashboardSelection.isAllModels {
                    ProviderBadgeView(maker: ModelMaker(model: resolved.model, provider: resolved.provider), size: 14)
                }
                MenuFieldLabel(text: ModelPickerGrouping.label(selection: store.dashboardSelection, resolved: resolved, cohorts: cohorts))
                    .frame(maxWidth: 190)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model")
        .accessibilityValue(store.dashboardSelection.displayLabel(resolved: resolved))
        .accessibilityHint("Choose the model, coding tool or provider to show")
        .help(store.dashboardSelection.displayLabel(resolved: resolved))
    }
}
