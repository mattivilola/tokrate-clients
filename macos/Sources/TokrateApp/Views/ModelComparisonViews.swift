import SwiftUI

// MARK: - Shared filter pickers (used by the popover menu and the history window)

/// Radio-style coding tool filter for use inside a `Menu`.
struct CodingToolFilterPicker: View {
    @Binding var client: String?
    let clients: [String]

    var body: some View {
        Picker("Coding tool", selection: $client) {
            Text("All coding tools").tag(String?.none)
            ForEach(clients, id: \.self) { value in
                Text(ModelCohort.clientTitle(value)).tag(Optional(value))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityLabel("Filter by coding tool")
    }
}

/// Radio-style inference provider filter for use inside a `Menu`.
struct ProviderFilterPicker: View {
    @Binding var provider: String?
    let providers: [String]

    var body: some View {
        Picker("Inference provider", selection: $provider) {
            Text("All inference providers").tag(String?.none)
            ForEach(providers, id: \.self) { value in
                Text(value == "unknown" ? "Inference provider unknown" : ModelCohort.providerTitle(value)).tag(Optional(value))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityLabel("Filter by inference provider")
    }
}

/// A bordered control-style label for menus on window backgrounds.
struct MenuFieldLabel: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(DashboardStyle.accent) }
            Text(text).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardStyle.muted)
        }
        .font(DashboardStyle.Typography.footnoteEmphasis)
        .foregroundStyle(DashboardStyle.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(DashboardStyle.surface2, in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous)
                .strokeBorder(DashboardStyle.line, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

struct ClientProviderFilterView: View {
    @Binding var client: String?
    @Binding var provider: String?
    let clients: [String]
    let providers: [String]

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                CodingToolFilterPicker(client: $client, clients: clients)
            } label: {
                MenuFieldLabel(text: "Coding tool: \(client.map(ModelCohort.clientTitle) ?? "All")")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Filter by coding tool")
            .help("Filter comparisons by coding tool")

            Menu {
                ProviderFilterPicker(provider: $provider, providers: providers)
            } label: {
                MenuFieldLabel(text: "Provider: \(provider.map(ModelCohort.providerTitle) ?? "All")")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Filter by inference provider")
            .help("Filter comparisons by inference provider")
            Spacer(minLength: 0)
        }
    }
}

/// The model choices shared by the popover picker and the history window: Auto, Auto within a
/// coding tool, one section per coding tool with its model entries, and the comparison.
struct ModelSelectionItems: View {
    @Binding var selection: DashboardSelection
    let cohorts: [ModelCohort]
    let clients: [String]
    var comparisonTitle = "Compare all models"

    var body: some View {
        Picker("Model", selection: $selection) {
            Text("Auto (most active)").tag(DashboardSelection.auto)
        }
        .pickerStyle(.inline).labelsHidden()
        if !clients.isEmpty {
            Menu("Auto within a coding tool") {
                Picker("Coding tool", selection: $selection) {
                    ForEach(clients, id: \.self) { client in
                        Text(ModelCohort.clientTitle(client)).tag(DashboardSelection.autoTool(client))
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        }
        Divider()
        ForEach(ModelPickerGrouping.sections(cohorts: cohorts)) { section in
            Section(section.title) {
                Picker(section.title, selection: $selection) {
                    ForEach(section.entries) { entry in
                        Text(entry.menuTitle).tag(DashboardSelection.cohort(entry.cohort))
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        }
        Divider()
        Picker("Comparison", selection: $selection) {
            Text(comparisonTitle).tag(DashboardSelection.all)
        }
        .pickerStyle(.inline).labelsHidden()
    }
}

/// The full model/cohort selector used on the history window (the popover uses `ModelPickerMenu`).
struct CohortSelectionView: View {
    @Binding var selection: DashboardSelection
    let cohorts: [ModelCohort]
    let clients: [String]
    let resolved: ModelCohort?

    var body: some View {
        Menu {
            ModelSelectionItems(selection: $selection, cohorts: cohorts, clients: clients, comparisonTitle: "All models comparison")
        } label: {
            MenuFieldLabel(text: ModelPickerGrouping.label(selection: selection, resolved: resolved, cohorts: cohorts), systemImage: "cpu")
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Exact coding tool, inference provider, version, and metric cohort selector")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(selection.displayLabel(resolved: resolved))
    }
}

// MARK: - Model list

/// One row per model entry: model, effort, measurement label when not the default, median speed
/// and a relative bar. Selecting a row selects the cohort; the chevron expands min/max/n.
struct CohortListView: View {
    let summaries: [DashboardSnapshot.CohortSummary]
    var sort: CohortComparisonSort = .recent
    var selected: ModelCohort?
    var rowLimit: Int?
    var onSelect: ((ModelCohort) -> Void)?
    @State private var expanded: Set<String> = []
    @State private var showsAll = false

    /// Groups by measurement definition, truncated to `rowLimit` rows overall.
    private var visibleGroups: [MeasurementGroup] {
        let groups = MeasurementGrouping.groups(summaries, sort: sort)
        guard let rowLimit, !showsAll else { return groups }
        var remaining = rowLimit
        return groups.compactMap { group in
            guard remaining > 0 else { return nil }
            let rows = Array(group.summaries.prefix(remaining))
            remaining -= rows.count
            return MeasurementGroup(client: group.client, metricVersion: group.metricVersion, measurement: group.measurement, summaries: rows, latestAt: group.latestAt)
        }
    }

    private var displays: [String: CohortDisplay] {
        Dictionary(uniqueKeysWithValues: CohortLabeler.displays(for: summaries.map(\.cohort)).map { ($0.id, $0) })
    }

    var body: some View {
        let groups = MeasurementGrouping.groups(summaries, sort: sort)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visibleGroups) { group in
                // The scale comes from the full group, so truncating rows never rescales bars.
                let ceiling = groups.first { $0.id == group.id }?.barCeiling ?? group.barCeiling
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(DashboardStyle.Typography.captionEmphasis)
                        .foregroundStyle(DashboardStyle.muted)
                        .padding(.horizontal, 8)
                        .accessibilityAddTraits(.isHeader)
                        .help(group.measurement.definition)
                    ForEach(group.summaries) { summary in
                        CohortRow(
                            summary: summary,
                            display: displays[summary.id] ?? CohortDisplay(cohort: summary.cohort, qualifier: nil),
                            barCeiling: ceiling,
                            isSelected: selected == summary.cohort,
                            isExpanded: expanded.contains(summary.id),
                            onSelect: onSelect.map { handler in { handler(summary.cohort) } },
                            onToggleDetails: {
                                if expanded.contains(summary.id) { expanded.remove(summary.id) } else { expanded.insert(summary.id) }
                            }
                        )
                    }
                }
            }
            if let rowLimit, summaries.count > rowLimit {
                Button(showsAll ? "Show fewer" : "Show \(summaries.count - rowLimit) more") { showsAll.toggle() }
                    .buttonStyle(.plain)
                    .font(DashboardStyle.Typography.footnoteEmphasis)
                    .foregroundStyle(DashboardStyle.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
    }
}

/// Response-speed model list: one row per model and provider across coding tools and source
/// kinds, ranked and scaled by per-turn response speed, with turn speed as secondary text.
struct ResponseListView: View {
    let summaries: [DashboardSnapshot.ResponseSummary]
    var sort: ResponseComparisonSort = .recent
    var selected: ModelCohort?
    var rowLimit: Int?
    var onSelect: ((ModelCohort) -> Void)?
    @State private var expanded: Set<String> = []
    @State private var showsAll = false

    private var ordered: [DashboardSnapshot.ResponseSummary] { DashboardSnapshot.ordered(summaries, by: sort) }
    /// One scale for every row: response speed is a single definition.
    private var barCeiling: Double { GaugeScale.niceCeiling(forMaximum: summaries.compactMap(\.response.median).max() ?? 0) }

    var body: some View {
        let rows = ordered
        let visible = showsAll || rowLimit == nil ? rows : Array(rows.prefix(rowLimit ?? rows.count))
        VStack(alignment: .leading, spacing: 2) {
            Text(ResponseSpeedCopy.title)
                .font(DashboardStyle.Typography.captionEmphasis)
                .foregroundStyle(DashboardStyle.muted)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(.isHeader)
                .help(ResponseSpeedCopy.definition)
            ForEach(visible) { summary in
                ResponseRow(
                    summary: summary,
                    barCeiling: barCeiling,
                    isSelected: selected.map { ResponseGroupKey($0) == summary.group } ?? false,
                    isExpanded: expanded.contains(summary.id),
                    onSelect: onSelect.map { handler in { handler(summary.latestCohort) } },
                    onToggleDetails: {
                        if expanded.contains(summary.id) { expanded.remove(summary.id) } else { expanded.insert(summary.id) }
                    }
                )
            }
            if let rowLimit, summaries.count > rowLimit {
                Button(showsAll ? "Show fewer" : "Show \(summaries.count - rowLimit) more") { showsAll.toggle() }
                    .buttonStyle(.plain)
                    .font(DashboardStyle.Typography.footnoteEmphasis)
                    .foregroundStyle(DashboardStyle.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
        }
    }
}

private struct ResponseRow: View {
    let summary: DashboardSnapshot.ResponseSummary
    let barCeiling: Double
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: (() -> Void)?
    let onToggleDetails: () -> Void
    @State private var isHovering = false

    private var median: Double? { summary.response.median }
    private var maker: ModelMaker { ModelMaker(summary.group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { onSelect?() } label: { summaryRow }
                    .buttonStyle(.plain)
                    .disabled(onSelect == nil)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityHint(onSelect == nil ? "" : "Shows this model's speed")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .help(rowHelp)
                Button(action: onToggleDetails) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DashboardStyle.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 22, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide details for \(summary.group.displayModel)" : "Show details for \(summary.group.displayModel)")
                .help("Minimum, maximum and turn counts")
            }
            if isExpanded { details.padding(.leading, 10).padding(.trailing, 26).padding(.bottom, 8) }
        }
        .padding(.leading, 2)
        .background(isSelected ? DashboardStyle.accent.opacity(0.12) : isHovering ? DashboardStyle.surface2 : .clear,
                    in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProviderBadgeView(maker: maker, size: 14)
                    Text(summary.group.displayModel)
                        .font(DashboardStyle.Typography.bodyEmphasis)
                        .foregroundStyle(DashboardStyle.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    ForEach(summary.clients, id: \.self) { client in
                        ChipView(text: ModelCohort.clientTitle(client)).fixedSize()
                    }
                    if summary.includesSubagent { ChipView(text: "Subagent", tone: .accent).fixedSize() }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(DashboardSnapshot.rate(median))
                        .font(DashboardStyle.Typography.value(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(median == nil ? DashboardStyle.muted : DashboardStyle.ink)
                    Text("tok/s").font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                }
                miniBar
                Text(turnSpeedText)
                    .font(DashboardStyle.Typography.caption.monospacedDigit())
                    .foregroundStyle(DashboardStyle.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6).padding(.leading, 8)
        .contentShape(Rectangle())
    }

    private var turnSpeedText: String {
        summary.throughput.median.map { "turn \(String(format: "%.1f", $0)) tok/s" } ?? "turn —"
    }

    private var miniBar: some View {
        let fraction = min(1, max(0, (median ?? 0) / barCeiling))
        return Capsule()
            .fill(DashboardStyle.line)
            .frame(width: 72, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(DashboardStyle.gradient).frame(width: 72 * fraction, height: 4)
            }
            .accessibilityHidden(true)
    }

    private var details: some View {
        func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        return VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ResponseSpeedCopy.title).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                Text("median \(format(summary.response.median)) tok/s · min \(format(summary.response.minimum)) · max \(format(summary.response.maximum)) · n=\(summary.response.count) turns · \(summary.responseCount) responses")
                    .font(DashboardStyle.Typography.footnote.monospacedDigit())
                    .foregroundStyle(DashboardStyle.ink)
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 1) {
                Text("Turn speed").font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                Text("median \(format(summary.throughput.median)) tok/s · min \(format(summary.throughput.minimum)) · max \(format(summary.throughput.maximum)) · n=\(summary.throughput.count)")
                    .font(DashboardStyle.Typography.footnote.monospacedDigit())
                    .foregroundStyle(DashboardStyle.ink)
            }
            .accessibilityElement(children: .combine)
            Text("\(ModelCohort.providerTitle(summary.group.provider)) · merged across coding tools and source kinds")
                .font(DashboardStyle.Typography.caption)
                .foregroundStyle(DashboardStyle.muted)
            if includesGrokBuild {
                Text(ResponseSpeedCopy.grokBuildNote)
                    .font(DashboardStyle.Typography.caption)
                    .foregroundStyle(DashboardStyle.muted)
                    .help(ResponseSpeedCopy.grokBuildExplanation)
            }
        }
        .padding(.top, 2)
    }

    private var accessibilityLabel: String {
        var parts = [summary.group.displayModel] + summary.clients.map(ModelCohort.clientTitle)
        if summary.includesSubagent { parts.append("Subagent") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        guard let median else { return "No response speed measured" }
        return String(format: "Response speed median %.1f tokens per second, %d turns", median, summary.response.count)
    }

    private var rowHelp: String {
        func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        let note = includesGrokBuild ? "\n" + ResponseSpeedCopy.grokBuildNote : ""
        return "\(summary.group.displayModel) · \(ModelCohort.providerTitle(summary.group.provider))\nResponse speed median \(format(summary.response.median)) tok/s · n=\(summary.response.count) turns\nTurn speed median \(format(summary.throughput.median)) tok/s" + note
    }

    private var includesGrokBuild: Bool { summary.clients.contains(ResponseSpeedCopy.grokBuildClient) }
}

private struct CohortRow: View {
    let summary: DashboardSnapshot.CohortSummary
    let display: CohortDisplay
    /// Bar scale of this row's measurement group; never shared across measurement definitions.
    let barCeiling: Double
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: (() -> Void)?
    let onToggleDetails: () -> Void
    @State private var isHovering = false

    private var median: Double? { summary.throughput.median }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { onSelect?() } label: { summaryRow }
                    .buttonStyle(.plain)
                    .disabled(onSelect == nil)
                    .accessibilityLabel(display.accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityHint(onSelect == nil ? "" : "Shows this model's speed")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .help(rowHelp)
                Button(action: onToggleDetails) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DashboardStyle.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 22, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide details for \(display.title)" : "Show details for \(display.title)")
                .help("Minimum, maximum and turn counts")
            }
            if isExpanded { details.padding(.leading, 10).padding(.trailing, 26).padding(.bottom, 8) }
        }
        .padding(.leading, 2)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        isSelected ? DashboardStyle.accent.opacity(0.12) : isHovering ? DashboardStyle.surface2 : .clear
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.title)
                        .font(DashboardStyle.Typography.bodyEmphasis)
                        .foregroundStyle(DashboardStyle.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if let effort = display.effort { ChipView(text: effort).fixedSize() }
                    if let chip = display.measurementChip { ChipView(text: chip, tone: .accent).fixedSize() }
                }
                Text(display.subtitle)
                    .font(DashboardStyle.Typography.caption)
                    .foregroundStyle(DashboardStyle.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(DashboardSnapshot.rate(median))
                        .font(DashboardStyle.Typography.value(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(DashboardStyle.ink)
                    Text("tok/s").font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                }
                miniBar
            }
        }
        .padding(.vertical, 6).padding(.leading, 8)
        .contentShape(Rectangle())
    }

    private var miniBar: some View {
        let fraction = min(1, max(0, (median ?? 0) / barCeiling))
        return Capsule()
            .fill(DashboardStyle.line)
            .frame(width: 72, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(DashboardStyle.gradient).frame(width: 72 * fraction, height: 4)
            }
            .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailLine(title: summary.cohort.measurement.title, stats: summary.throughput, unit: "tok/s", digits: 1)
            detailLine(title: "First token", stats: summary.ttft, unit: "s", digits: 2)
            Text(summary.cohort.detailLabel)
                .font(DashboardStyle.Typography.caption)
                .foregroundStyle(DashboardStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func detailLine(title: String, stats: MetricStats, unit: String, digits: Int) -> some View {
        func format(_ value: Double?) -> String { value.map { String(format: "%.*f", digits, $0) } ?? "—" }
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            Text("median \(format(stats.median)) \(unit) · min \(format(stats.minimum)) · max \(format(stats.maximum)) · n=\(stats.count)")
                .font(DashboardStyle.Typography.footnote.monospacedDigit())
                .foregroundStyle(DashboardStyle.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var rowHelp: String {
        func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        return "\(summary.cohort.selectionLabel)\nMedian \(format(summary.throughput.median)) tok/s · min \(format(summary.throughput.minimum)) · max \(format(summary.throughput.maximum)) · n=\(summary.throughput.count)"
    }

    private var accessibilityValue: String {
        guard let median else { return "No eligible turns" }
        return String(format: "Median %.1f tokens per second, %d turns", median, summary.throughput.count)
    }
}

/// Model comparison: the list is the content, with the metric, range and sort controls. Response
/// speed (default) merges a model across coding tools; Turn speed keeps the measurement groups.
struct CohortComparisonView: View {
    let snapshot: DashboardSnapshot
    @Binding var range: DashboardRange
    @State private var metric: ComparisonMetric = .responseSpeed
    @State private var sort: CohortComparisonSort = .recent
    @State private var responseSort: ResponseComparisonSort = .faster
    var compact = true
    /// When present, selecting a row switches the dashboard to that model.
    var onSelect: ((ModelCohort) -> Void)?

    var body: some View {
        if compact {
            content
        } else {
            content.dashboardCard(padding: 18)
        }
    }

    private var sortMenu: some View {
        Menu {
            if metric == .responseSpeed {
                Picker("Sort model comparisons", selection: $responseSort) {
                    ForEach(ResponseComparisonSort.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.inline).labelsHidden()
            } else {
                Picker("Sort model comparisons", selection: $sort) {
                    ForEach(CohortComparisonSort.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        } label: {
            MenuFieldLabel(text: "Sort: \(metric == .responseSpeed ? responseSort.title : sort.title)")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Sort model comparisons by speed metric")
        .help("Sort model comparisons")
    }

    private var metricPicker: some View {
        Picker("Speed ranked", selection: $metric) {
            ForEach(ComparisonMetric.allCases) { option in Text(option.title).tag(option) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Speed ranked")
        .help("Response speed excludes tools and your time and merges a model across coding tools. Turn speed covers the whole turn, per coding tool.")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(spacing: 8) {
                Text("Model comparison").font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                Spacer(minLength: 4)
                if !compact { sortMenu }
                RangePicker(range: $range)
            }
            metricPicker
            if compact { HStack { sortMenu; Spacer(minLength: 0) } }
            if snapshot.cohortSummaries.isEmpty {
                Text("Completed turns from each model will appear here.")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: compact ? 72 : 130)
            } else if metric == .responseSpeed {
                ResponseListView(summaries: snapshot.responseSummaries, sort: responseSort, selected: nil, onSelect: onSelect)
            } else {
                CohortListView(summaries: snapshot.cohortSummaries, sort: sort, selected: nil, onSelect: onSelect)
            }
            if range == .week {
                Text("Previous 7 days unavailable · local history retains 7 days.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            }
            Text(footnote)
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                .help("Speed ordering is not a quality ranking · effort shown when reported; speed tier and workload are uncontrolled.")
        }
    }

    private var footnote: String {
        switch (metric, compact) {
        case (.responseSpeed, true): "Speed ordering is not a quality ranking."
        case (.responseSpeed, false): ResponseSpeedCopy.definition + " Merged across coding tools · speed ordering is not a quality ranking · speed tier/workload uncontrolled"
        case (.turnSpeed, true): "Speed ordering is not a quality ranking."
        case (.turnSpeed, false): "Each group has its own definition and scale · speed ordering is not a quality ranking · effort shown when reported; speed tier/workload uncontrolled"
        }
    }
}

// MARK: - Personal trend

struct PersonalTrendView: View {
    let trend: PersonalTrend?
    var reasoningEffort: String? = nil
    /// Compact places the content on an inset instead of a card (popover details).
    var compact = false

    var body: some View {
        if let trend {
            Group {
                if compact { content(trend).dashboardInset(padding: 10) }
                else { content(trend).dashboardCard(padding: 14) }
            }
        }
    }

    private func content(_ trend: PersonalTrend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: trend.status == .slower ? "exclamationmark.circle.fill" : "chart.line.uptrend.xyaxis")
                    .foregroundStyle(trend.status == .slower ? DashboardStyle.warn : DashboardStyle.muted)
                Text(title(for: trend)).font(DashboardStyle.Typography.footnoteEmphasis).foregroundStyle(DashboardStyle.ink)
            }
            if trend.status == .slower {
                if trend.comparesSpeed {
                    metricLine(trend.speedTitle, current: trend.currentSpeed, baseline: trend.baselineSpeed, unit: "tok/s", digits: 1, sampleLabel: "eligible turns")
                }
                if trend.comparesTTFT {
                    metricLine("First token", current: trend.currentTTFT, baseline: trend.baselineTTFT, unit: "s", digits: 2, sampleLabel: "values")
                }
                Text("Workload/tools may have changed; not a provider diagnosis. Reasoning effort: \(reasoningEffort ?? "unknown"); speed tier/workload are uncontrolled.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Same client, parser, metric, model, provider, version, and reasoning effort: \(reasoningEffort ?? "unknown"); speed tier/workload are uncontrolled.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(for trend: PersonalTrend) -> String {
        switch trend.status {
        case .noRecentObservations: "No recent observations"
        case .buildingBaseline: "Building baseline"
        case .noLargeChange: "No large change"
        case .slower: trend.basis == .response ? "Your recent responses are slower" : "Your recent turns are slower"
        }
    }

    private func metricLine(_ title: String, current: MetricStats, baseline: MetricStats, unit: String, digits: Int, sampleLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            Text("Now median \(format(current.median, digits: digits)) \(unit) (n=\(current.count) \(sampleLabel)); prior six days \(format(baseline.median, digits: digits)) \(unit) (n=\(baseline.count) \(sampleLabel))")
                .font(DashboardStyle.Typography.footnote.monospacedDigit())
                .foregroundStyle(DashboardStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func format(_ value: Double?, digits: Int) -> String {
        value.map { String(format: "%.*f", digits, $0) } ?? "—"
    }
}
