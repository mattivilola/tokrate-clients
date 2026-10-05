import SwiftUI

/// Efficiency-indicator model list: one row per model and effort across coding tools, providers
/// and versions, with the indicator, a bar on one shared scale and a thin tick at 100 ("typical").
/// A group under 20 eligible requests shows its progress instead of a value and no bar. Rows
/// expand to the statistics behind the value.
struct EfficiencyListView: View {
    let rows: [EfficiencyIndicator.Row]
    let reference: EfficiencyIndicator.Reference?
    let sort: EfficiencyComparisonSort
    @State private var expanded: Set<String>

    init(rows: [EfficiencyIndicator.Row], reference: EfficiencyIndicator.Reference?, sort: EfficiencyComparisonSort = .higher, expanded: Set<String> = []) {
        self.rows = rows
        self.reference = reference
        self.sort = sort
        _expanded = State(initialValue: expanded)
    }

    fileprivate static let barWidth: CGFloat = 72
    fileprivate static let tickWidth: CGFloat = 1.5
    fileprivate static let chevronWidth: CGFloat = 22
    /// Horizontal gap between the columns of a row; the header reuses it so "typical" lines up.
    fileprivate static let columnSpacing: CGFloat = 10

    /// The tick's leading edge inside the bar column, for the row bars and the header label alike.
    fileprivate static func tickOffset(scale: Double) -> CGFloat {
        min(barWidth - tickWidth, barWidth * 100 / scale)
    }

    var body: some View {
        let ordered = EfficiencyIndicator.ordered(rows, by: sort)
        let scale = Double(EfficiencyIndicator.scaleMaximum(rows))
        VStack(alignment: .leading, spacing: 2) {
            header(scale: scale)
            Text(EfficiencyCopy.definition)
                .font(DashboardStyle.Typography.caption)
                .foregroundStyle(DashboardStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            if rows.isEmpty || reference == nil {
                Text(EfficiencyCopy.insufficient)
                    .font(DashboardStyle.Typography.footnote)
                    .foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            ForEach(ordered) { row in
                EfficiencyRowView(
                    row: row,
                    scale: scale,
                    barWidth: Self.barWidth,
                    isExpanded: expanded.contains(row.id)
                ) {
                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                }
            }
        }
    }

    /// The title with its "Indicator" badge, and "typical" above the bar column's 100 tick.
    private func header(scale: Double) -> some View {
        HStack(spacing: 6) {
            Text(EfficiencyCopy.title)
                .font(DashboardStyle.Typography.captionEmphasis)
                .foregroundStyle(DashboardStyle.muted)
                .accessibilityAddTraits(.isHeader)
            ChipView(text: EfficiencyCopy.badge, tone: .accent).fixedSize()
            Spacer(minLength: 4)
            if reference != nil, !rows.isEmpty {
                // Same columns as a row (bar, then chevron), so the label centres on the bars' tick.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: Self.barWidth, height: 12)
                        .overlay(alignment: .leading) {
                            Text(EfficiencyCopy.tick)
                                .font(DashboardStyle.Typography.caption)
                                .foregroundStyle(DashboardStyle.muted)
                                .fixedSize()
                                .alignmentGuide(.leading) { $0.width / 2 }
                                .offset(x: Self.tickOffset(scale: scale) + Self.tickWidth / 2)
                        }
                        .accessibilityHidden(true)
                    Color.clear.frame(width: Self.columnSpacing + Self.chevronWidth, height: 1)
                }
            }
        }
        .padding(.leading, 8)
        .help(EfficiencyCopy.explanation)
    }
}

private struct EfficiencyRowView: View {
    let row: EfficiencyIndicator.Row
    let scale: Double
    let barWidth: CGFloat
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var isHovering = false

    private var maker: ModelMaker { ModelMaker(model: row.model, provider: row.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) { summaryRow }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.model), \(EfficiencyCopy.effortText(row.effort))")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isExpanded ? "Hides the statistics" : "Shows the statistics")
                .help(rowHelp)
            if isExpanded { details.padding(.leading, 10).padding(.trailing, 26).padding(.bottom, 8) }
        }
        .padding(.leading, 2)
        .background(isHovering ? DashboardStyle.surface2 : .clear,
                    in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var summaryRow: some View {
        HStack(spacing: EfficiencyListView.columnSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProviderBadgeView(maker: maker, size: 14)
                    Text(row.model)
                        .font(DashboardStyle.Typography.bodyEmphasis)
                        .foregroundStyle(DashboardStyle.ink)
                        .lineLimit(1).truncationMode(.middle)
                    ChipView(text: EfficiencyCopy.effortChip(row.effort), tone: row.effort == "unknown" ? .neutral : .accent).fixedSize()
                }
                Text(subtitle)
                    .font(DashboardStyle.Typography.caption.monospacedDigit())
                    .foregroundStyle(DashboardStyle.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let indicator = row.indicator {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(indicator)")
                            .font(DashboardStyle.Typography.value(size: 15))
                            .monospacedDigit()
                            .foregroundStyle(DashboardStyle.ink)
                        Text("indicator").font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    }
                    .fixedSize()
                    bar(indicator: indicator)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardStyle.muted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: EfficiencyListView.chevronWidth, height: 36)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6).padding(.leading, 8)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        row.indicator == nil
            ? EfficiencyCopy.requestsOfFloor(row.turns)
            : "\(EfficiencyIndicator.compactTokens(row.medianTokens)) \(EfficiencyCopy.tokensPerRequest) · \(EfficiencyCopy.requestCount(row.turns))"
    }

    /// The bar is the indicator relative to the row maximum; the tick marks 100.
    private func bar(indicator: Int) -> some View {
        let fraction = min(1, max(0.04, Double(indicator) / scale))
        return Capsule()
            .fill(DashboardStyle.line)
            .frame(width: barWidth, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(DashboardStyle.gradient).frame(width: barWidth * fraction, height: 4)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(DashboardStyle.ink.opacity(0.55))
                    .frame(width: EfficiencyListView.tickWidth, height: 9)
                    .offset(x: EfficiencyListView.tickOffset(scale: scale))
            }
            .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            detail("Median tokens/request", "median \(EfficiencyIndicator.compactTokens(row.medianTokens)) · middle half \(EfficiencyIndicator.compactTokens(row.p25Tokens))–\(EfficiencyIndicator.compactTokens(row.p75Tokens))")
            detail("Reasoning share", "\(EfficiencyIndicator.percentText(row.reasoningShare)) · median of output tokens")
            detail("Delegated share", "\(EfficiencyIndicator.percentText(row.delegatedShare)) · of all tokens, subagent work")
            detail("Eligible requests", "n=\(row.turns) · last 7 d · 200 tokens or more")
            if let provider = row.provider {
                Text("\(ModelCohort.providerTitle(provider)) · merged across coding tools and versions")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            } else {
                Text("Several providers · merged across coding tools and versions")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            }
        }
        .padding(.top, 2)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
            Text(value)
                .font(DashboardStyle.Typography.footnote.monospacedDigit())
                .foregroundStyle(DashboardStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibilityValue: String {
        guard let indicator = row.indicator else { return "\(EfficiencyCopy.requestsOfFloor(row.turns)), no indicator yet" }
        return "Efficiency indicator \(indicator), 100 is a typical request, \(EfficiencyCopy.requestCount(row.turns))"
    }

    private var rowHelp: String {
        var lines = ["\(row.model) · \(EfficiencyCopy.effortText(row.effort))"]
        if let indicator = row.indicator {
            lines.append("\(EfficiencyCopy.title) \(indicator) · \(EfficiencyCopy.definition)")
            lines.append("Median \(EfficiencyIndicator.compactTokens(row.medianTokens)) \(EfficiencyCopy.tokensPerRequest) · \(EfficiencyCopy.requestCount(row.turns))")
        } else {
            lines.append("\(EfficiencyCopy.requestsOfFloor(row.turns)) · \(EfficiencyCopy.insufficient)")
        }
        return lines.joined(separator: "\n")
    }
}
