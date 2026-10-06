import Foundation
import TokrateCore

// Pure presentation logic. Nothing here touches stores, files, Keychain or the network.

// MARK: - Measurement kinds

/// How a cohort's speed is measured. Different measurements keep separate histories.
enum SpeedMeasurement: Equatable, Sendable {
    /// Completed turn: Codex and Claude Code primary turns.
    case turn
    /// Claude Code subagent task prompt to final answer.
    case subagent
    /// Grok Build work turn, including nested agent output.
    case workTurn

    /// Chip text shown next to a model; nil for the default turn measurement.
    var chipTitle: String? {
        switch self {
        case .turn: nil
        case .subagent: "Subagent"
        case .workTurn: "Work turn"
        }
    }

    /// Short name for the measurement ("Turn speed", never "streaming speed").
    var title: String {
        switch self {
        case .turn: "Turn speed"
        case .subagent: "Subagent turn speed"
        case .workTurn: "Work-turn speed"
        }
    }

    /// Very short qualifier shown beside the unit under a readout.
    var shortDefinition: String {
        switch self {
        case .turn: "whole turn, incl. tools & waiting"
        case .subagent: "task to answer, incl. tools & waiting"
        case .workTurn: "work turn, incl. subagents & waiting"
        }
    }

    /// One-line definition shown next to a speed readout.
    var definition: String {
        switch self {
        case .turn: "Whole turn, including tools and waiting."
        case .subagent: "Subagent task prompt to final answer, including tools and waiting."
        case .workTurn: "Whole work turn, including nested subagent output, tools and waiting."
        }
    }
}

extension ModelCohort {
    var measurement: SpeedMeasurement {
        guard TurnMetric.isSupportedSourceTuple(client: client, parserVersion: parserVersion, metricVersion: metricVersion) else { return .turn }
        return switch metricVersion {
        case "claude-observed-subagent-turn-v1": .subagent
        case "grok-observed-work-turn-v1": .workTurn
        default: .turn
        }
    }
}

extension TurnMetric {
    /// A Claude Code subagent turn, by source kind or by its dedicated metric version.
    var isSubagentTurn: Bool {
        sourceKind == "subagent" || metricVersion == "claude-observed-subagent-turn-v1"
    }
}

// MARK: - Speed versus the personal median

/// "+12% vs your 24 h median": the latest turn compared with the selected cohort's own 24 h median.
struct SpeedDelta: Equatable, Sendable {
    /// Fewer turns than this make a median too noisy to compare against.
    static let minimumTurns = 3

    let percent: Double
    let medianTPS: Double
    let turns: Int

    init?(latest: Double?, median: MetricStats) {
        guard let latest, latest.isFinite, latest >= 0,
              median.count >= Self.minimumTurns,
              let reference = median.median, reference > 0 else { return nil }
        percent = (latest - reference) / reference * 100
        medianTPS = reference
        turns = median.count
    }

    var roundedPercent: Int { Int(percent.rounded()) }
    var isFaster: Bool { roundedPercent > 0 }
    var isSlower: Bool { roundedPercent < 0 }

    /// Signed percentage such as "+12%" or "−8%".
    var percentText: String {
        let value = roundedPercent
        return value > 0 ? "+\(value)%" : value < 0 ? "−\(abs(value))%" : "0%"
    }

    var summary: String { summary(medianName: "median") }

    /// "+12% vs your 24 h response-speed median" for `medianName` "response-speed median".
    func summary(medianName: String) -> String {
        roundedPercent == 0 ? "On par with your 24 h \(medianName)" : "\(percentText) vs your 24 h \(medianName)"
    }

    var accessibilitySummary: String {
        let magnitude = abs(roundedPercent)
        if magnitude == 0 { return "On par with your 24 hour median" }
        return "\(magnitude) percent \(isFaster ? "faster" : "slower") than your 24 hour median"
    }
}

// MARK: - Relative time

enum RelativeTime {
    /// "just now", "2 min ago", "3 h ago", "yesterday", "4 d ago". Static: no ticking clocks.
    static func string(from date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min ago" }
        let hours = Int(seconds / 3_600)
        if hours < 24 { return "\(hours) h ago" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "yesterday" : "\(days) d ago"
    }

    /// The exact time for a tooltip.
    static func exact(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - Cohort labels

/// A cohort prepared for a row or menu item: model first, then effort and measurement, then only
/// the qualifiers that are needed to tell two entries apart.
struct CohortDisplay: Identifiable, Equatable {
    let cohort: ModelCohort
    /// Added only when two entries would otherwise look identical (client version, then provider).
    let qualifier: String?

    var id: String { cohort.id }
    var title: String { cohort.displayModel }
    var effort: String? { cohort.reasoningEffort }
    var measurementChip: String? { cohort.measurement.chipTitle }

    /// "Claude Code" or "Claude Code · v2.1.0" for a secondary line.
    var subtitle: String {
        [cohort.clientLabel, qualifier].compactMap { $0 }.joined(separator: " · ")
    }

    /// Single-line title for a menu item.
    var menuTitle: String {
        [cohort.displayModel, effort, measurementChip, qualifier].compactMap { $0 }.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        var parts = [cohort.displayModel, cohort.clientLabel]
        if let effort { parts.append("\(effort) effort") }
        if let measurementChip { parts.append(measurementChip) }
        if let qualifier { parts.append(qualifier) }
        return parts.joined(separator: ", ")
    }
}

enum CohortLabeler {
    static func displays(for cohorts: [ModelCohort]) -> [CohortDisplay] {
        func base(_ cohort: ModelCohort) -> String {
            [cohort.client, cohort.model ?? "", cohort.reasoningEffort ?? "", cohort.measurement.chipTitle ?? ""].joined(separator: "\u{1F}")
        }
        let groups = Dictionary(grouping: cohorts, by: base)
        return cohorts.map { cohort in
            let siblings = groups[base(cohort)] ?? [cohort]
            guard siblings.count > 1 else { return CohortDisplay(cohort: cohort, qualifier: nil) }
            let versions = Set(siblings.map { $0.clientVersion ?? "" })
            let providers = Set(siblings.map { $0.provider ?? "" })
            var parts: [String] = []
            if versions.count > 1 { parts.append(cohort.clientVersion.map { "v\($0)" } ?? "version unknown") }
            if providers.count > 1 { parts.append(cohort.provider.map(ModelCohort.providerTitle) ?? "Provider unknown") }
            if Set(siblings.map { $0.providerRegion ?? "" }).count > 1 {
                parts.append(cohort.providerRegion.map { "Bedrock \(ModelCohort.regionTitle($0))" } ?? "No region")
            }
            if parts.isEmpty {
                // Siblings differ only by parser or metric internals; keep entries distinguishable.
                parts.append("parser \(cohort.parserVersion)")
            }
            return CohortDisplay(cohort: cohort, qualifier: parts.joined(separator: " · "))
        }
    }
}

// MARK: - Model picker structure

struct ModelPickerSection: Identifiable, Equatable {
    let client: String
    let title: String
    let entries: [CohortDisplay]
    var id: String { client }
}

enum ModelPickerGrouping {
    /// One section per coding tool, in alphabetical tool order. Cohorts keep their incoming order
    /// (most recently active first) inside each section.
    static func sections(cohorts: [ModelCohort]) -> [ModelPickerSection] {
        let displays = CohortLabeler.displays(for: cohorts)
        return Dictionary(grouping: displays, by: { $0.cohort.client })
            .map { client, entries in ModelPickerSection(client: client, title: ModelCohort.clientTitle(client), entries: entries) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Models shown directly in the picker; older ones live under "More models".
    static let recentLimit = 5

    /// The newest `limit` models, each merged across client, parser and metric versions. Cohorts
    /// arrive most recently active first and the newest of each group is kept. Unknown models are
    /// left out. A title qualifier appears only when two rows differ by provider or region.
    static func recentEntries(cohorts: [ModelCohort], limit: Int = recentLimit) -> [CohortDisplay] {
        var seen = Set<String>()
        let newest = cohorts.filter { cohort in
            guard cohort.model != nil else { return false }
            let key = [cohort.client, cohort.model ?? "", cohort.reasoningEffort ?? "", cohort.measurement.chipTitle ?? "", cohort.provider ?? "", cohort.providerRegion ?? ""]
                .joined(separator: "\u{1F}")
            return seen.insert(key).inserted
        }
        .prefix(limit)
        // Labelled without versions, so a qualifier can only come from provider or region.
        let unversioned = newest.map { ModelCohort(model: $0.model, provider: $0.provider, clientVersion: nil, reasoningEffort: $0.reasoningEffort, client: $0.client, parserVersion: $0.parserVersion, metricVersion: $0.metricVersion, providerRegion: $0.providerRegion) }
        return zip(newest, CohortLabeler.displays(for: unversioned)).map { CohortDisplay(cohort: $0, qualifier: $1.qualifier) }
    }

    /// One "Auto within a coding tool" row: the tool and the model it currently resolves to.
    struct ToolEntry: Identifiable, Equatable {
        let tool: CodingTool
        let model: String?

        var id: String { tool.id }
        var title: String { model.map { "\(tool.title) · \($0)" } ?? tool.title }
    }

    /// One entry per coding tool in alphabetical title order. The tool's latest model comes from
    /// `records`; for the tool currently selected it is the `resolved` cohort, matching what is shown.
    static func toolEntries(clients: [String], records: [TurnMetric], selection: DashboardSelection, resolved: ModelCohort?) -> [ToolEntry] {
        clients.map { client in
            let cohort = selection == .autoTool(client) ? resolved : AutoSelection.resolve(records: records, activeModel: nil, client: client)
            return ToolEntry(tool: CodingTool.named(client), model: cohort?.model)
        }
        .sorted { $0.tool.title.localizedCaseInsensitiveCompare($1.tool.title) == .orderedAscending }
    }

    /// The coding tool a picker button shows as a chip; none for Auto and All models.
    static func chipTool(selection: DashboardSelection) -> CodingTool? {
        switch selection {
        case .autoTool(let client): CodingTool.named(client)
        case .cohort(let cohort): CodingTool.named(cohort.client)
        case .auto, .all: nil
        }
    }

    /// The model picker button text for the current selection: "Auto · claude-opus-5-5". The coding
    /// tool is shown as a chip beside it, not in the text.
    static func label(selection: DashboardSelection, resolved: ModelCohort?, cohorts: [ModelCohort]) -> String {
        switch selection {
        case .all:
            return "All models"
        case .auto, .autoTool:
            return resolved.map { "Auto · \($0.displayModel)" } ?? "Auto"
        case .cohort(let cohort):
            return displayTitle(for: cohort, in: cohorts)
        }
    }

    private static func displayTitle(for cohort: ModelCohort, in cohorts: [ModelCohort]) -> String {
        let all = cohorts.contains(cohort) ? cohorts : cohorts + [cohort]
        return CohortLabeler.displays(for: all).first { $0.cohort == cohort }?.menuTitle ?? cohort.displayModel
    }
}

// MARK: - Community line

struct CommunityLine: Equatable {
    enum Caution: Equatable {
        case earlyData, older
        var title: String { self == .older ? "Older data" : "Early data" }
    }

    enum Position: Equatable {
        case faster(percent: Int)
        case slower(percent: Int)
        case level
    }

    let medianTPS: Double
    let windowLabel: String
    let position: Position?
    let caution: Caution?

    /// Your median is only compared when it covers the same window as the community median.
    static func make(board: GlobalBoard, cohort: ModelCohort, local: LocalPeriodComparison?) -> CommunityLine? {
        guard board.collectionEnabled,
              let id = cohort.communityBoardID,
              let match = board.cohorts.first(where: { $0.id == id }),
              let community = match.medianThroughput, community.isFinite, community > 0 else { return nil }
        let localStats: MetricStats? = switch board.window {
        case "15m": local?.recent15Minutes.throughput
        case "24h", "24hr": local?.last24Hours.throughput
        default: nil
        }
        var position: Position?
        if let localStats, localStats.count >= SpeedDelta.minimumTurns, let mine = localStats.median {
            let percent = Int(((mine - community) / community * 100).rounded())
            position = percent > 0 ? .faster(percent: percent) : percent < 0 ? .slower(percent: -percent) : .level
        }
        let caution: Caution? = board.state == "stale"
            ? .older
            : (board.state == "insufficient_data" || board.publicationMode == "early_data") ? .earlyData : nil
        return CommunityLine(medianTPS: community, windowLabel: windowLabel(board.window), position: position, caution: caution)
    }

    static func windowLabel(_ window: String) -> String {
        switch window {
        case "15m": "15 min"
        case "24h", "24hr": "24 h"
        case "7d": "7 d"
        case "30d": "30 d"
        default: window
        }
    }

    var positionText: String? {
        switch position {
        case .faster(let percent)?: "You're \(percent)% faster"
        case .slower(let percent)?: "You're \(percent)% slower"
        case .level?: "You're right at the median"
        case nil: nil
        }
    }
}

// MARK: - Sharing state

enum SharingStateLabel {
    /// Short footer text for the sharing state.
    static func title(isRequested: Bool, isActive: Bool, isPending: Bool) -> String {
        if isPending { return "Sharing off" }
        if !isRequested { return "Local only" }
        return isActive ? "Sharing on" : "Sharing needs attention"
    }
}

// MARK: - Measurement groups

/// Cohorts are only ever listed and scaled against others with the same measurement definition:
/// the same coding tool and metric version (which also separates subagent from primary turns).
struct MeasurementGroup: Identifiable {
    let client: String
    let metricVersion: String
    let measurement: SpeedMeasurement
    let summaries: [DashboardSnapshot.CohortSummary]
    let latestAt: Date

    var id: String { "\(client)|\(metricVersion)" }
    /// "Claude Code · Subagent turn speed".
    var title: String { "\(ModelCohort.clientTitle(client)) · \(measurement.title)" }

    /// Mini-bar scale for this group only: the same nice-ceiling rule as the gauge.
    var barCeiling: Double {
        GaugeScale.niceCeiling(forMaximum: summaries.compactMap(\.throughput.median).max() ?? 0)
    }
}

enum MeasurementGrouping {
    /// Groups ordered by most recent activity; rows sorted within each group by `sort`.
    static func groups(_ summaries: [DashboardSnapshot.CohortSummary], sort: CohortComparisonSort) -> [MeasurementGroup] {
        Dictionary(grouping: summaries) { "\($0.cohort.client)|\($0.cohort.metricVersion)" }
            .values
            .compactMap { members -> MeasurementGroup? in
                guard let first = members.first else { return nil }
                return MeasurementGroup(
                    client: first.cohort.client,
                    metricVersion: first.cohort.metricVersion,
                    measurement: first.cohort.measurement,
                    summaries: DashboardSnapshot.ordered(members, by: sort),
                    latestAt: members.map(\.latestAt).max() ?? .distantPast
                )
            }
            .sorted { $0.latestAt == $1.latestAt ? $0.title < $1.title : $0.latestAt > $1.latestAt }
    }
}

// MARK: - Response speed vocabulary

/// The words for the primary metric. Response speed is the speed while the model is responding;
/// turn speed (whole turn, tools and waiting included) stays the secondary metric.
enum ResponseSpeedCopy {
    static let title = "Response speed"
    static let unit = "tok/s"
    /// The one-line definition shown next to a response-speed readout.
    static let definition = "Output tokens per second while the model is responding — tools and your time excluded."
    /// Very short qualifier shown beside the unit under the readout.
    static let shortDefinition = "while responding, tools excluded"
    static let explanation = "Response speed is output tokens divided by the seconds the model spent producing each response, from the request that triggered it to its last output. Tool runs and your own time are excluded; reasoning tokens are included. Only responses of at least 200 tokens and at most 10 minutes count, so tiny automated check-ins never do. It is not streaming speed."
    /// Grok Build records output tokens per turn only, so its response speed is a whole-turn average.
    static let grokBuildClient = "grok-build"
    static let grokBuildNote = "Grok Build: average over all model calls in a turn"
    static let grokBuildExplanation = "Grok Build records output tokens per turn, not per response, so its response speed is the turn's output tokens divided by the time its model calls spent generating (tool runs and permission waits excluded). Short calls are included, which can make it read lower than per-response measurements from Codex and Claude Code. Turns with nested agents are not counted."
}

// MARK: - Efficiency indicator vocabulary

/// The words for the efficiency indicator (efficiency-v1): a heuristic indicator, never a benchmark.
enum EfficiencyCopy {
    static let title = "Efficiency indicator"
    static let shortTitle = "Efficiency"
    /// The badge shown next to the value in comparison lists.
    static let badge = "Indicator"
    static let tick = "typical"
    /// Unit of the all-models chart, which plots the reference itself.
    static let tokensPerRequest = "tokens/request"
    static let definition = "Fewer output tokens per request scores higher. 100 = a typical request."
    static let explanation = "The efficiency indicator compares the median output tokens a model spends to finish one of your requests (reasoning and delegated subagent work included) with the median across all your requests in the last 7 days. 100 is typical; 200 means half the tokens. It is an indicator, not a benchmark: it depends on what you ask each model to do, requests under 200 tokens are left out, and answer quality is not measured."
    static let insufficient = "Not enough requests yet: the efficiency indicator needs 20 eligible requests per model."
    static let comparisonFootnote = "Each model and reasoning effort counts every coding tool, provider and version. Requests under 200 tokens are left out, and each group needs 20 eligible requests. It depends on what you ask each model to do, and this is not an answer-quality ranking."
    static let rangeNote = "The efficiency indicator always covers your last 7 days, whatever the range."
    static let chartHelp = "Efficiency indicator of the selected model and effort in each time interval, against your typical request over the last 7 days. An interval needs 3 eligible requests, otherwise it stays blank. " + explanation

    /// "12 of 20 requests" for a group that has not reached the floor yet.
    static func requestsOfFloor(_ turns: Int) -> String { "\(turns) of \(EfficiencyIndicator.minimumTurns) requests" }
    /// "1 request", "87 requests".
    static func requestCount(_ turns: Int) -> String { "\(turns) \(turns == 1 ? "request" : "requests")" }
    /// Chip text next to a model, like the other model rows: "high", but "effort unknown" for none.
    static func effortChip(_ effort: String) -> String { effort == "unknown" ? "effort unknown" : effort }
    /// "high effort", "effort unknown".
    static func effortText(_ effort: String) -> String { effort == "unknown" ? "effort unknown" : "\(effort) effort" }
}

// MARK: - Menu-bar readout

/// What the menu-bar item shows: the speed of the followed model, its maker and its coding tool. The
/// value is the same hero reading as the popover gauge: the live median while responses finish,
/// otherwise the model's latest turn.
struct MenuBarReadout: Equatable, Sendable {
    let speedText: String
    let group: ResponseGroupKey?
    let maker: ModelMaker?
    /// The coding tool the value comes from, shown as a chip.
    let tool: CodingTool?
    let accessibilityLabel: String

    static let unavailable = MenuBarReadout(speedText: "— tok/s", group: nil, maker: nil, tool: nil, accessibilityLabel: "Tokrate, response speed: unavailable")

    static func make(isMonitoring: Bool, selection: DashboardSelection, reading: HeroReading) -> MenuBarReadout {
        guard isMonitoring else { return .unavailable }
        if selection.isAllModels {
            return MenuBarReadout(speedText: "Compare", group: nil, maker: nil, tool: nil, accessibilityLabel: "Tokrate, model comparison")
        }
        let group = reading.group
        let maker = group.map { ModelMaker($0) }
        let tool = reading.client.map(CodingTool.named)
        let who = [maker.flatMap { $0 == .unknown ? nil : $0.title }, tool?.title].compactMap { $0 }.map { "\($0), " }.joined()
        guard let value = reading.value else {
            return MenuBarReadout(speedText: "— tok/s", group: group, maker: maker, tool: tool, accessibilityLabel: "Tokrate, \(who)response speed: unavailable")
        }
        let measure = switch reading.kind {
        case .live, .empty: "response speed"
        case .latestTurnResponse: "response speed of the latest turn"
        case .turnFallback: "turn speed of the latest turn"
        }
        return MenuBarReadout(
            speedText: String(format: "%.1f tok/s", value),
            group: group,
            maker: maker,
            tool: tool,
            accessibilityLabel: String(format: "Tokrate, %@%@: %.1f tokens per second", who, measure, value)
        )
    }
}
