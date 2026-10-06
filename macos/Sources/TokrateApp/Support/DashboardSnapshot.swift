import Foundation
import TokrateCore

enum DashboardRange: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String { self == .day ? "24 hours" : "7 days" }
    var shortTitle: String { self == .day ? "24 h" : "7 d" }
    /// Number of chart buckets across the range.
    var bucketCount: Int { self == .day ? 48 : 56 }
    /// Efficiency buckets are coarser (hourly, six-hourly): each needs 3 eligible requests.
    var efficiencyBucketCount: Int { self == .day ? 24 : 28 }
    var duration: TimeInterval { self == .day ? 86_400 : MetricHistory.retention }
}

enum CohortComparisonSort: String, CaseIterable, Identifiable {
    case recent, higherThroughput, lowerTTFT
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Most recent"
        case .higherThroughput: "Faster turn speed"
        case .lowerTTFT: "Faster first token"
        }
    }
    var shortTitle: String {
        switch self {
        case .recent: "Recent"
        case .higherThroughput: "Turn speed"
        case .lowerTTFT: "First token"
        }
    }
}

/// Which speed the model comparison ranks. Response speed is the primary metric.
enum ComparisonMetric: String, CaseIterable, Identifiable {
    case responseSpeed, turnSpeed, efficiency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .responseSpeed: ResponseSpeedCopy.title
        case .turnSpeed: "Turn speed"
        case .efficiency: EfficiencyCopy.shortTitle
        }
    }
}

/// Sorting for the response-speed model list.
enum ResponseComparisonSort: String, CaseIterable, Identifiable {
    case recent, faster
    var id: String { rawValue }
    var title: String { self == .recent ? "Most recent" : "Faster response speed" }
}

/// A coding tool the app reads: its recorded id, display title and the two-letter chip shown in
/// the model picker. Adding a tool is one entry in `known`.
struct CodingTool: Equatable, Sendable {
    let id: String
    let title: String
    let chip: String

    private static let known = [
        CodingTool(id: "codex", title: "Codex", chip: "CX"),
        CodingTool(id: "claude-code", title: "Claude Code", chip: "CC"),
        CodingTool(id: "grok-build", title: "Grok Build", chip: "GB")
    ]

    /// The tool for a recorded client id; an unknown id is shown as recorded, chipped by its first two letters.
    static func named(_ id: String) -> CodingTool {
        known.first { $0.id == id } ?? CodingTool(id: id, title: id, chip: String(id.prefix(2)).uppercased())
    }
}

/// The exact local comparison dimensions. Missing fields stay distinct from explicit values.
struct ModelCohort: Hashable, Identifiable, Sendable {
    let model: String?
    let provider: String?
    let clientVersion: String?
    let reasoningEffort: String?
    let client: String
    let parserVersion: String
    let metricVersion: String
    /// Bedrock inference-profile region; nil for every other provider.
    let providerRegion: String?

    init(
        model: String?, provider: String?, clientVersion: String?, reasoningEffort: String? = nil,
        client: String = TurnMetric.codexClient,
        parserVersion: String = TurnMetric.codexParserVersion,
        metricVersion: String = TurnMetric.codexMetricVersion,
        providerRegion: String? = nil
    ) {
        self.providerRegion = providerRegion
        self.model = model
        self.provider = provider
        self.clientVersion = clientVersion
        self.reasoningEffort = reasoningEffort.flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
        self.client = client
        self.parserVersion = parserVersion
        self.metricVersion = metricVersion
    }

    init(_ metric: TurnMetric) {
        self.init(
            model: metric.model,
            provider: metric.provider,
            clientVersion: metric.clientVersion,
            reasoningEffort: metric.reasoningEffort,
            client: metric.client,
            parserVersion: metric.parserVersion,
            metricVersion: metric.metricVersion,
            providerRegion: metric.providerRegion
        )
    }

    /// Local cohort identity. The region is appended only when present so existing persisted
    /// selections (seven parts) keep restoring.
    var id: String {
        let parts = [model, provider, clientVersion, parserVersion, metricVersion, reasoningEffort, client] + (providerRegion.map { [$0] } ?? [])
        return parts.map(Self.encode).joined(separator: ".")
    }

    var displayModel: String { model ?? "Unknown model" }
    var clientLabel: String {
        Self.clientTitle(client)
    }
    static func clientTitle(_ client: String) -> String {
        CodingTool.named(client).title
    }
    /// Display name for an inference provider value; unknown values are shown as recorded.
    /// "us-gov" is shown as "US GovCloud", other regions in upper case ("EU", "APAC"), and "unknown" as is.
    static func regionTitle(_ region: String) -> String {
        switch region {
        case "unknown": "region unknown"
        case "global": "Global"
        case "us-gov": "US GovCloud"
        default: region.uppercased()
        }
    }

    static func providerTitle(_ provider: String?) -> String {
        switch provider {
        case nil, "unknown": "Unknown"
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "xai": "xAI"
        case "amazon-bedrock": "Amazon Bedrock"
        case "google-vertex": "Google Vertex AI"
        case let other?: other
        }
    }
    var detailLabel: String {
        [clientLabel, "parser \(parserVersion)", "metric \(metricVersion)",
         "provider \(Self.providerTitle(provider))\(providerRegion.map { " (\(Self.regionTitle($0)))" } ?? "")", clientVersion.map { "version \($0)" } ?? "version unknown", "reasoning effort \(reasoningEffort ?? "unknown")"]
            .joined(separator: " · ")
    }
    var selectionLabel: String { "\(displayModel) · \(detailLabel)" }

    /// Matches the public board's stable seven-dimension JSON identity.
    var communityBoardID: String? {
        guard let model, isSafe(model, pattern: "^[a-zA-Z0-9._-]{1,80}$"),
              ["codex", "claude-code", "grok-build"].contains(client),
              SharedSample.isAllowedProvider(provider, client: client),
              isSupportedTuple else { return nil }
        let version = clientVersion.flatMap { isSafe($0, pattern: "^[a-zA-Z0-9.+_-]{1,40}$") ? $0 : nil } ?? "unknown"
        guard isSafe(parserVersion, pattern: "^[a-zA-Z0-9._-]{1,40}$"),
              isSafe(metricVersion, pattern: "^[a-zA-Z0-9._-]{1,48}$") else { return nil }
        let dimensions = [model, provider ?? "unknown", version, parserVersion, metricVersion, reasoningEffort ?? "unknown", client]
        guard let data = try? JSONSerialization.data(withJSONObject: dimensions, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(id: String) {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 || parts.count == 4 {
            guard let model = Self.decode(parts[0]),
                  let provider = Self.decode(parts[1]),
                  let clientVersion = Self.decode(parts[2]) else { return nil }
            let effort: String?? = parts.count == 4 ? Self.decode(parts[3]) : .some(nil)
            guard let effort else { return nil }
            self.init(model: model, provider: provider, clientVersion: clientVersion, reasoningEffort: effort)
            return
        }
        guard parts.count == 7 || parts.count == 8,
              let model = Self.decode(parts[0]),
              let provider = Self.decode(parts[1]),
              let clientVersion = Self.decode(parts[2]),
              let parserValue = Self.decode(parts[3]), let parserVersion = parserValue,
              let metricValue = Self.decode(parts[4]), let metricVersion = metricValue,
              let effort = Self.decode(parts[5]),
              let clientValue = Self.decode(parts[6]), let client = clientValue else { return nil }
        let region: String?? = parts.count == 8 ? Self.decode(parts[7]) : .some(nil)
        guard let region else { return nil }
        self.init(model: model, provider: provider, clientVersion: clientVersion, reasoningEffort: effort, client: client, parserVersion: parserVersion, metricVersion: metricVersion, providerRegion: region)
    }

    private static func encode(_ value: String?) -> String {
        guard let value else { return "~" }
        return Data(value.utf8).base64EncodedString()
    }

    private static func decode(_ value: String) -> String?? {
        if value == "~" { return .some(nil) }
        guard let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8) else { return nil }
        return .some(decoded)
    }

    private func isSafe(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private var isSupportedTuple: Bool {
        TurnMetric.isSupportedSourceTuple(client: client, parserVersion: parserVersion, metricVersion: metricVersion)
    }

    var throughputLabel: String {
        TurnMetric.throughputLabel(client: client, parserVersion: parserVersion, metricVersion: metricVersion)
    }

    var throughputExplanation: String {
        TurnMetric.throughputExplanation(client: client, parserVersion: parserVersion, metricVersion: metricVersion)
    }
}

enum DashboardSelection: Hashable, Sendable {
    /// Follows the model that is most active right now (default).
    case auto
    /// Like `auto`, restricted to one coding tool.
    case autoTool(String)
    case cohort(ModelCohort)
    case all

    static func restored(from value: String?) -> DashboardSelection {
        guard let value else { return .auto }
        // "latest" was the default before Auto existed.
        if value == "auto" || value == "latest" { return .auto }
        if value == "all" { return .all }
        if value.hasPrefix("auto:") {
            let client = String(value.dropFirst("auto:".count))
            return client.isEmpty ? .auto : .autoTool(client)
        }
        guard value.hasPrefix("cohort:"), let cohort = ModelCohort(id: String(value.dropFirst("cohort:".count))) else {
            return .auto
        }
        return .cohort(cohort)
    }

    var persistenceValue: String {
        switch self {
        case .auto: "auto"
        case .autoTool(let client): "auto:\(client)"
        case .all: "all"
        case .cohort(let cohort): "cohort:\(cohort.id)"
        }
    }

    var isAllModels: Bool {
        if case .all = self { return true }
        return false
    }

    var isAuto: Bool {
        switch self {
        case .auto, .autoTool: true
        default: false
        }
    }

    /// The coding tool an Auto selection is restricted to.
    var autoClient: String? {
        if case .autoTool(let client) = self { return client }
        return nil
    }

    func displayLabel(resolved: ModelCohort?) -> String {
        switch self {
        case .auto: resolved.map { "Auto (most active) · \($0.selectionLabel)" } ?? "Auto (most active)"
        case .autoTool(let client):
            "Auto within \(ModelCohort.clientTitle(client))" + (resolved.map { " · \($0.selectionLabel)" } ?? "")
        case .cohort(let cohort): cohort.selectionLabel
        case .all: "All models"
        }
    }
}

struct MetricStats: Equatable, Sendable {
    let median: Double?
    let minimum: Double?
    let maximum: Double?
    let count: Int

    init(values: [Double]) {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        count = sorted.count
        minimum = sorted.first
        maximum = sorted.last
        if sorted.isEmpty {
            median = nil
        } else {
            let middle = sorted.count / 2
            median = sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
        }
    }
}

struct PeriodMetricStats: Equatable, Sendable {
    /// Turn speed.
    let throughput: MetricStats
    let ttft: MetricStats
    /// Per-turn response speed.
    let response: MetricStats
}

struct LocalPeriodComparison: Equatable, Sendable {
    let range: DashboardRange
    let recent15Minutes: PeriodMetricStats
    let last24Hours: PeriodMetricStats
    let previous24Hours: PeriodMetricStats
    let currentRange: PeriodMetricStats
    let previousRange: PeriodMetricStats?
    let throughputChangePercent: Double?
    let responseChangePercent: Double?
    let ttftChangePercent: Double?

    /// `records` are the selected cohort's turns (turn speed, first token); `responseRecords` the
    /// selected model's turns across coding tools and source kinds (response speed).
    init(records: [TurnMetric], responseRecords: [TurnMetric], range: DashboardRange, now: Date) {
        func stats(from values: [TurnMetric], responses: [TurnMetric]) -> PeriodMetricStats {
            let throughput = values.filter { $0.outputTokens >= 20 && $0.turnThroughputTPS.isFinite && $0.turnThroughputTPS >= 0 }
            let ttft = values.compactMap(\.ttftSeconds).filter { $0.isFinite && $0 >= 0 }
            return PeriodMetricStats(
                throughput: MetricStats(values: throughput.map(\.turnThroughputTPS)),
                ttft: MetricStats(values: ttft),
                response: MetricStats(values: responses.compactMap(\.responseSpeedTPS))
            )
        }
        func window(_ lower: TimeInterval, _ upper: TimeInterval) -> PeriodMetricStats {
            let low = now.addingTimeInterval(-lower), high = now.addingTimeInterval(-upper)
            return stats(
                from: records.filter { $0.completedAt >= low && $0.completedAt <= high },
                responses: responseRecords.filter { $0.completedAt >= low && $0.completedAt <= high }
            )
        }

        self.range = range
        recent15Minutes = window(15 * 60, 0)
        last24Hours = window(86_400, 0)
        let dayStart = now.addingTimeInterval(-86_400)
        let previousDayStart = now.addingTimeInterval(-2 * 86_400)
        previous24Hours = stats(
            from: records.filter { $0.completedAt >= previousDayStart && $0.completedAt < dayStart },
            responses: responseRecords.filter { $0.completedAt >= previousDayStart && $0.completedAt < dayStart }
        )
        currentRange = range == .day ? last24Hours : stats(from: records, responses: responseRecords)
        previousRange = range == .day ? previous24Hours : nil
        throughputChangePercent = Self.changePercent(current: last24Hours.throughput, previous: previous24Hours.throughput)
        responseChangePercent = Self.changePercent(current: last24Hours.response, previous: previous24Hours.response)
        ttftChangePercent = Self.changePercent(current: last24Hours.ttft, previous: previous24Hours.ttft)
    }

    private static func changePercent(current: MetricStats, previous: MetricStats) -> Double? {
        guard current.count >= 5, previous.count >= 5,
              let currentMedian = current.median,
              let previousMedian = previous.median, previousMedian > 0 else { return nil }
        let change = ((currentMedian - previousMedian) / previousMedian) * 100
        return change.isFinite ? change : nil
    }
}

struct PersonalTrend: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case noRecentObservations
        case buildingBaseline
        case noLargeChange
        case slower
    }

    /// Which speed the slower-than-usual signal compares: response speed whenever the model has any
    /// response data, whole-turn speed for sources that cannot provide it.
    enum Basis: Equatable, Sendable { case response, turn }

    let status: Status
    let basis: Basis
    let currentThroughput: MetricStats
    let baselineThroughput: MetricStats
    let currentResponse: MetricStats
    let baselineResponse: MetricStats
    let currentTTFT: MetricStats
    let baselineTTFT: MetricStats
    /// True when the compared speed (per `basis`) met the evidence requirements.
    let comparesSpeed: Bool
    let comparesTTFT: Bool

    var currentSpeed: MetricStats { basis == .response ? currentResponse : currentThroughput }
    var baselineSpeed: MetricStats { basis == .response ? baselineResponse : baselineThroughput }
    var speedTitle: String { basis == .response ? "Response speed" : "Turn speed" }
}

/// What the gauge shows and where it came from. Response speed is primary; a source without
/// per-response timing falls back to its latest whole-turn speed, labelled as such.
struct HeroReading: Equatable {
    enum Kind: Equatable {
        /// Median of the latest live responses of the selected model.
        case live
        /// The selected model's latest turn that has response data.
        case latestTurnResponse
        /// The selected cohort's latest turn speed, for sources without per-response timing.
        case turnFallback
        case empty
    }

    let kind: Kind
    let value: Double?
    let model: String?
    let provider: String?
    let effort: String?
    /// Source chips such as "Subagent" or "Work turn".
    let chip: String?
    /// When the underlying measurement completed.
    let completedAt: Date?
    /// Live readings: how many responses the median covers.
    let responseCount: Int?
    let cohort: ModelCohort?

    var usesResponseSpeed: Bool { kind == .live || kind == .latestTurnResponse }

    /// "last 5 responses · 2 min ago" for live readings, "latest turn · 3 h ago" otherwise.
    func caption(now: Date) -> String? {
        guard let completedAt else { return nil }
        let when = RelativeTime.string(from: completedAt, now: now)
        switch kind {
        case .live: return "last \(responseCount ?? 1) \((responseCount ?? 1) == 1 ? "response" : "responses") · \(when)"
        case .latestTurnResponse: return "latest turn · \(when)"
        case .turnFallback: return "latest turn · \(when)"
        case .empty: return nil
        }
    }

    static let empty = HeroReading(kind: .empty, value: nil, model: nil, provider: nil, effort: nil, chip: nil, completedAt: nil, responseCount: nil, cohort: nil)
}

/// Pure presentation data: safe to construct for previews without any store, monitor, or network.
struct DashboardSnapshot {
    struct Bucket: Identifiable {
        var id: Date { date }
        let date: Date
        let median: Double
        let turns: Int
    }

    /// One exact cohort (coding tool, version, parser, metric, effort): the Turn speed list.
    struct CohortSummary: Identifiable {
        var id: String { cohort.id }
        let cohort: ModelCohort
        let throughput: MetricStats
        let ttft: MetricStats
        let latestAt: Date
    }

    /// One model and provider across every coding tool and source kind: the Response speed list.
    struct ResponseSummary: Identifiable {
        var id: String { "\(group.model ?? "~")|\(group.provider)" }
        let group: ResponseGroupKey
        /// Per-turn response speed.
        let response: MetricStats
        /// Turn speed, shown as secondary text.
        let throughput: MetricStats
        /// Qualifying responses behind `response`.
        let responseCount: Int
        /// Coding tools that contributed, alphabetical.
        let clients: [String]
        let includesSubagent: Bool
        let latestAt: Date
        /// The cohort of the model's most recent turn; selecting the row pins it.
        let latestCohort: ModelCohort
    }

    let range: DashboardRange
    let selection: DashboardSelection
    let selectedCohort: ModelCohort?
    let throughputLabel: String
    let latest: TurnMetric?
    /// The selected model's latest turn with response data (any coding tool), within retention.
    let responseHero: TurnMetric?
    /// The selected cohort's latest eligible turn: the gauge fallback for sources without response data.
    let turnHero: TurnMetric?
    /// Largest 24 h median of per-turn response speed among all models; sets the gauge scale.
    let responseGaugeMedian: Double?
    /// Largest 24 h median of per-turn speed within the selected cohort's measurement group.
    let turnGaugeMedian: Double?
    let points: [Bucket]
    let responsePoints: [Bucket]
    let ttftPoints: [Bucket]
    let turnCount: Int
    let throughput: MetricStats
    let ttft: MetricStats
    let response: MetricStats
    /// Qualifying responses behind `response` in the selected range.
    let responseCount: Int
    let medianRate: Double?
    let medianTTFT: Double?
    let personalTrend: PersonalTrend?
    let cohortSummaries: [CohortSummary]
    let responseSummaries: [ResponseSummary]
    /// R: median total tokens over every eligible turn of the retained history (7 days, whatever the
    /// range); nil below 20 eligible turns.
    let efficiencyReference: EfficiencyIndicator.Reference?
    /// One row per model and effort over the retained history.
    let efficiencyRows: [EfficiencyIndicator.Row]
    /// The row of the selected model and effort, when it has eligible turns.
    let efficiencySelected: EfficiencyIndicator.Row?
    /// Chart buckets of the selected range: the selected group's indicator, or median total tokens
    /// per request when all models are compared.
    let efficiencyPoints: [Bucket]
    let localPeriodComparison: LocalPeriodComparison?
    let records: [TurnMetric]
    let dates: ClosedRange<Date>

    init(
        records: [TurnMetric],
        range: DashboardRange,
        selection: DashboardSelection = .auto,
        activeModel: ResponseGroupKey? = nil,
        now: Date = .now,
        calendar: Calendar = .current,
        clientFilter: String? = nil,
        providerFilter: String? = nil
    ) {
        self.range = range
        self.selection = selection
        let retentionCutoff = now.addingTimeInterval(-MetricHistory.retention)
        let inRetention = records.filter { $0.completedAt >= retentionCutoff && $0.completedAt <= now }
        let retained = inRetention.filter { metric in
            (clientFilter == nil || metric.client == clientFilter)
                && (providerFilter == nil || (metric.provider ?? "unknown") == providerFilter)
        }
        let resolvedCohort: ModelCohort?
        switch selection {
        case .auto, .autoTool:
            resolvedCohort = AutoSelection.resolve(records: retained, activeModel: activeModel, client: selection.autoClient)
        case .cohort(let cohort):
            resolvedCohort = cohort
        case .all:
            resolvedCohort = nil
        }
        selectedCohort = resolvedCohort
        throughputLabel = resolvedCohort?.throughputLabel ?? "Turn speed"

        let start = now.addingTimeInterval(-range.duration)
        dates = start...max(now, start.addingTimeInterval(1))
        let inRange = retained.filter { $0.completedAt >= start }
        let sortedRange = inRange.sorted { $0.completedAt > $1.completedAt }
        cohortSummaries = Self.summaries(in: sortedRange)
        responseSummaries = Self.responseSummaries(in: sortedRange)
        let gaugeMedian = Self.responseGaugeMedian(in: inRetention, now: now)
        // The indicator spans the whole retained history so it stays stable while the range moves.
        let reference = EfficiencyIndicator.reference(in: retained)
        let efficiencyGroup = resolvedCohort.flatMap(EfficiencyIndicator.Key.init)
        let efficiencyTable = EfficiencyIndicator.rows(in: retained, reference: reference)
        efficiencyReference = reference
        efficiencyRows = efficiencyTable
        efficiencySelected = efficiencyGroup.flatMap { group in efficiencyTable.first { $0.group == group } }
        efficiencyPoints = selection.isAllModels || efficiencyGroup != nil
            ? EfficiencyIndicator.points(
                in: retained, group: efficiencyGroup, reference: reference,
                start: start, now: now, duration: range.duration, bucketCount: range.efficiencyBucketCount
            )
            : []

        if selection.isAllModels {
            self.records = sortedRange
            turnCount = 0
            throughput = MetricStats(values: [])
            ttft = MetricStats(values: [])
            response = MetricStats(values: [])
            responseCount = 0
            medianRate = nil
            medianTTFT = nil
            latest = nil
            responseHero = nil
            turnHero = nil
            responseGaugeMedian = gaugeMedian
            turnGaugeMedian = nil
            points = []
            responsePoints = []
            ttftPoints = []
            personalTrend = nil
            localPeriodComparison = nil
            return
        }

        let selectedRetained = resolvedCohort.map { cohort in retained.filter { ModelCohort($0) == cohort } } ?? []
        // Response speed is one definition across tools: it merges a model's cohorts. An unknown
        // model has no identity to merge on, so it stays in its exact cohort.
        let responseScope: [TurnMetric]
        if let cohort = resolvedCohort, cohort.model != nil {
            let group = ResponseGroupKey(cohort)
            responseScope = retained.filter { ResponseGroupKey($0) == group }
        } else {
            responseScope = selectedRetained
        }
        localPeriodComparison = resolvedCohort == nil
            ? nil
            : LocalPeriodComparison(records: selectedRetained, responseRecords: responseScope, range: range, now: now)

        let scoped = sortedRange.filter { metric in resolvedCohort.map { ModelCohort(metric) == $0 } ?? false }
        self.records = scoped
        let eligible = scoped.filter(Self.isThroughputEligible)
        turnCount = eligible.count
        throughput = MetricStats(values: eligible.map(\.turnThroughputTPS))
        ttft = MetricStats(values: scoped.compactMap(\.ttftSeconds).filter { $0.isFinite && $0 >= 0 })
        medianRate = throughput.median
        medianTTFT = ttft.median
        latest = eligible.max { $0.completedAt < $1.completedAt }
        turnHero = selectedRetained.filter(Self.isThroughputEligible).max { $0.completedAt < $1.completedAt }
        turnGaugeMedian = turnHero.flatMap { Self.groupMedianMaximum(for: $0, in: inRetention, now: now) }

        let scopedResponses = responseScope.filter { $0.completedAt >= start && $0.responseSpeedTPS != nil }
        response = MetricStats(values: scopedResponses.compactMap(\.responseSpeedTPS))
        responseCount = scopedResponses.reduce(0) { $0 + ($1.responseCount ?? 0) }
        responseHero = responseScope.filter { $0.responseSpeedTPS != nil }.max { $0.completedAt < $1.completedAt }
        responseGaugeMedian = gaugeMedian

        points = Self.buckets(eligible.map { ($0.completedAt, $0.turnThroughputTPS) }, start: start, now: now, range: range)
        responsePoints = Self.buckets(scopedResponses.compactMap { turn in turn.responseSpeedTPS.map { (turn.completedAt, $0) } }, start: start, now: now, range: range)
        ttftPoints = Self.buckets(scoped.compactMap { turn in turn.ttftSeconds.flatMap { $0.isFinite && $0 >= 0 ? (turn.completedAt, $0) : nil } }, start: start, now: now, range: range)

        let hasKnownModelAndProvider = resolvedCohort?.model.map { !$0.isEmpty && $0 != "unknown" } == true
            && resolvedCohort?.provider.map { !$0.isEmpty && $0 != "unknown" } == true
        personalTrend = hasKnownModelAndProvider
            ? Self.personalTrend(cohortRecords: selectedRetained, responseRecords: responseScope, now: now, calendar: calendar)
            : nil
    }

    /// The gauge reading: live median first, then the model's latest turn with response data, then
    /// the cohort's latest turn speed for sources without per-response timing.
    func heroReading(live: LiveSpeed?, liveGroup: ResponseGroupKey?) -> HeroReading {
        guard let cohort = selectedCohort else { return .empty }
        let chip = cohort.measurement.chipTitle
        if let live, let liveGroup {
            return HeroReading(
                kind: .live, value: live.medianTPS, model: liveGroup.model, provider: liveGroup.provider,
                effort: cohort.reasoningEffort, chip: chip, completedAt: live.latestAt, responseCount: live.responseCount, cohort: cohort
            )
        }
        if let turn = responseHero, let speed = turn.responseSpeedTPS {
            return HeroReading(
                kind: .latestTurnResponse, value: speed, model: turn.model, provider: turn.provider,
                effort: turn.reasoningEffort, chip: turn.isSubagentTurn ? "Subagent" : ModelCohort(turn).measurement.chipTitle,
                completedAt: turn.completedAt, responseCount: turn.responseCount, cohort: ModelCohort(turn)
            )
        }
        if let turn = turnHero {
            return HeroReading(
                kind: .turnFallback, value: turn.turnThroughputTPS, model: turn.model, provider: turn.provider,
                effort: turn.reasoningEffort, chip: turn.isSubagentTurn ? "Subagent" : ModelCohort(turn).measurement.chipTitle,
                completedAt: turn.completedAt, responseCount: nil, cohort: ModelCohort(turn)
            )
        }
        return HeroReading(kind: .empty, value: nil, model: cohort.model, provider: cohort.provider, effort: cohort.reasoningEffort, chip: chip, completedAt: nil, responseCount: nil, cohort: cohort)
    }

    /// The reading compared with the selected model's own 24 h response-speed median (or the turn
    /// speed median for the turn fallback).
    func speedDelta(for reading: HeroReading) -> SpeedDelta? {
        guard let comparison = localPeriodComparison else { return nil }
        return SpeedDelta(
            latest: reading.value,
            median: reading.usesResponseSpeed ? comparison.last24Hours.response : comparison.last24Hours.throughput
        )
    }

    /// The largest 24 h median of any cohort in `hero`'s measurement group (same client, metric
    /// version and source kind), over all supplied records regardless of the dashboard filters.
    static func groupMedianMaximum(for hero: TurnMetric, in records: [TurnMetric], now: Date) -> Double? {
        let start = now.addingTimeInterval(-86_400)
        let group = records.filter {
            $0.completedAt >= start && $0.completedAt <= now && isThroughputEligible($0)
                && $0.client == hero.client && $0.metricVersion == hero.metricVersion && $0.sourceKind == hero.sourceKind
        }
        return Dictionary(grouping: group, by: ModelCohort.init)
            .values
            .compactMap { MetricStats(values: $0.map(\.turnThroughputTPS)).median }
            .max()
    }

    /// The largest 24 h median of per-turn response speed among models (response speed is one
    /// definition, so every model shares one gauge scale).
    static func responseGaugeMedian(in records: [TurnMetric], now: Date) -> Double? {
        let start = now.addingTimeInterval(-86_400)
        return Dictionary(grouping: records.filter { $0.completedAt >= start && $0.completedAt <= now && $0.responseSpeedTPS != nil }, by: ResponseGroupKey.init)
            .values
            .compactMap { MetricStats(values: $0.compactMap(\.responseSpeedTPS)).median }
            .max()
    }

    static func median(_ values: [Double]) -> Double? { MetricStats(values: values).median }

    static func rate(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }

    static func ordered(_ summaries: [CohortSummary], by sort: CohortComparisonSort) -> [CohortSummary] {
        summaries.sorted { left, right in
            if left.cohort.metricVersion != right.cohort.metricVersion {
                return left.cohort.metricVersion < right.cohort.metricVersion
            }
            switch sort {
            case .recent:
                return left.latestAt == right.latestAt
                    ? left.id < right.id
                    : left.latestAt > right.latestAt
            case .higherThroughput:
                return compare(left.throughput.median, right.throughput.median, descending: true, leftAt: left.latestAt, rightAt: right.latestAt, leftID: left.id, rightID: right.id)
            case .lowerTTFT:
                return compare(left.ttft.median, right.ttft.median, descending: false, leftAt: left.latestAt, rightAt: right.latestAt, leftID: left.id, rightID: right.id)
            }
        }
    }

    /// Models with a response-speed median first (fastest first), then the rest by recency.
    static func ordered(_ summaries: [ResponseSummary], by sort: ResponseComparisonSort) -> [ResponseSummary] {
        summaries.sorted { left, right in
            switch sort {
            case .recent:
                return left.latestAt == right.latestAt ? left.id < right.id : left.latestAt > right.latestAt
            case .faster:
                return compare(left.response.median, right.response.median, descending: true, leftAt: left.latestAt, rightAt: right.latestAt, leftID: left.id, rightID: right.id)
            }
        }
    }

    private static func compare(
        _ leftValue: Double?,
        _ rightValue: Double?,
        descending: Bool,
        leftAt: Date, rightAt: Date, leftID: String, rightID: String
    ) -> Bool {
        switch (leftValue, rightValue) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            return leftAt == rightAt ? leftID < rightID : leftAt > rightAt
        }
    }

    private static func isThroughputEligible(_ metric: TurnMetric) -> Bool {
        metric.outputTokens >= 20 && metric.turnThroughputTPS.isFinite && metric.turnThroughputTPS >= 0
    }

    /// Median per time bucket; at most `range.bucketCount` buckets.
    private static func buckets(_ values: [(Date, Double)], start: Date, now: Date, range: DashboardRange) -> [Bucket] {
        let maximumBuckets = range.bucketCount
        let bucketWidth = max(1, range.duration / Double(maximumBuckets))
        var grouped: [Int: [Double]] = [:]
        for (date, value) in values {
            let index = min(maximumBuckets - 1, max(0, Int(date.timeIntervalSince(start) / bucketWidth)))
            grouped[index, default: []].append(value)
        }
        return grouped.keys.sorted().map { index in
            let values = grouped[index]!
            return Bucket(
                date: min(now, start.addingTimeInterval((Double(index) + 0.5) * bucketWidth)),
                median: MetricStats(values: values).median ?? 0,
                turns: values.count
            )
        }
    }

    private static func summaries(in records: [TurnMetric]) -> [CohortSummary] {
        let groups = Dictionary(grouping: records, by: ModelCohort.init)
        return groups.map { cohort, turns in
            let eligible = turns.filter(isThroughputEligible)
            let ttft = turns.compactMap(\.ttftSeconds).filter { $0.isFinite && $0 >= 0 }
            return CohortSummary(
                cohort: cohort,
                throughput: MetricStats(values: eligible.map(\.turnThroughputTPS)),
                ttft: MetricStats(values: ttft),
                latestAt: turns.map(\.completedAt).max() ?? .distantPast
            )
        }
        .sorted { $0.latestAt > $1.latestAt }
    }

    private static func responseSummaries(in records: [TurnMetric]) -> [ResponseSummary] {
        Dictionary(grouping: records, by: ResponseGroupKey.init).compactMap { group, turns in
            guard let newest = turns.max(by: { $0.completedAt < $1.completedAt }) else { return nil }
            let withResponse = turns.filter { $0.responseSpeedTPS != nil }
            return ResponseSummary(
                group: group,
                response: MetricStats(values: withResponse.compactMap(\.responseSpeedTPS)),
                throughput: MetricStats(values: turns.filter(isThroughputEligible).map(\.turnThroughputTPS)),
                responseCount: withResponse.reduce(0) { $0 + ($1.responseCount ?? 0) },
                clients: Array(Set(turns.map(\.client))).sorted(),
                includesSubagent: turns.contains(where: \.isSubagentTurn),
                latestAt: newest.completedAt,
                latestCohort: ModelCohort(turns.filter { !$0.isSubagentTurn }.max { $0.completedAt < $1.completedAt } ?? newest)
            )
        }
        .sorted { $0.latestAt > $1.latestAt }
    }

    private static func personalTrend(cohortRecords: [TurnMetric], responseRecords: [TurnMetric], now: Date, calendar: Calendar) -> PersonalTrend {
        let currentStart = now.addingTimeInterval(-86_400)
        let baselineStart = now.addingTimeInterval(-MetricHistory.retention)
        let basis: PersonalTrend.Basis = responseRecords.contains { $0.responseSpeedTPS != nil } ? .response : .turn

        // Turn speed (cohort) and response speed (model) are both measured; `basis` picks the one
        // that drives the signal.
        let turnEligible = cohortRecords.filter(isThroughputEligible)
        let turnCurrent = turnEligible.filter { $0.completedAt >= currentStart }
        let turnBaseline = turnEligible.filter { $0.completedAt < currentStart && $0.completedAt >= baselineStart }
        let responseEligible = responseRecords.filter { $0.responseSpeedTPS != nil }
        let responseCurrent = responseEligible.filter { $0.completedAt >= currentStart }
        let responseBaseline = responseEligible.filter { $0.completedAt < currentStart && $0.completedAt >= baselineStart }
        let ttftRecords = cohortRecords.filter { $0.ttftSeconds.map { $0.isFinite && $0 >= 0 } == true }
        let currentTTFTRecords = ttftRecords.filter { $0.completedAt >= currentStart }
        let baselineTTFTRecords = ttftRecords.filter { $0.completedAt < currentStart && $0.completedAt >= baselineStart }

        let currentThroughput = MetricStats(values: turnCurrent.map(\.turnThroughputTPS))
        let baselineThroughput = MetricStats(values: turnBaseline.map(\.turnThroughputTPS))
        let currentResponse = MetricStats(values: responseCurrent.compactMap(\.responseSpeedTPS))
        let baselineResponse = MetricStats(values: responseBaseline.compactMap(\.responseSpeedTPS))
        let currentTTFT = MetricStats(values: currentTTFTRecords.compactMap(\.ttftSeconds))
        let baselineTTFT = MetricStats(values: baselineTTFTRecords.compactMap(\.ttftSeconds))

        func trend(_ status: PersonalTrend.Status, speed: Bool, ttft: Bool) -> PersonalTrend {
            PersonalTrend(
                status: status, basis: basis,
                currentThroughput: currentThroughput, baselineThroughput: baselineThroughput,
                currentResponse: currentResponse, baselineResponse: baselineResponse,
                currentTTFT: currentTTFT, baselineTTFT: baselineTTFT,
                comparesSpeed: speed, comparesTTFT: ttft
            )
        }

        let speedCurrent = basis == .response ? responseCurrent : turnCurrent
        let speedBaseline = basis == .response ? responseBaseline : turnBaseline
        let currentSpeed = basis == .response ? currentResponse : currentThroughput
        let baselineSpeed = basis == .response ? baselineResponse : baselineThroughput
        let latestCurrentObservation = [speedCurrent.map(\.completedAt).max(), currentTTFTRecords.map(\.completedAt).max()]
            .compactMap { $0 }
            .max()
        guard latestCurrentObservation.map({ now.timeIntervalSince($0) <= 3_600 }) == true else {
            return trend(.noRecentObservations, speed: false, ttft: false)
        }

        let speedBaselineDays = Set(speedBaseline.map { calendar.startOfDay(for: $0.completedAt) })
        let ttftBaselineDays = Set(baselineTTFTRecords.map { calendar.startOfDay(for: $0.completedAt) })
        let comparesSpeed = speedCurrent.count >= 5 && speedBaseline.count >= 20 && speedBaselineDays.count >= 2
            && speedCurrent.map(\.completedAt).max().map { now.timeIntervalSince($0) <= 3_600 } == true
            && (baselineSpeed.median ?? 0) > 0
        let comparesTTFT = currentTTFTRecords.count >= 5 && baselineTTFTRecords.count >= 20 && ttftBaselineDays.count >= 2
            && currentTTFTRecords.map(\.completedAt).max().map { now.timeIntervalSince($0) <= 3_600 } == true
            && (baselineTTFT.median ?? 0) > 0

        guard comparesSpeed || comparesTTFT else {
            return trend(.buildingBaseline, speed: false, ttft: false)
        }

        let speedDrop = comparesSpeed && (currentSpeed.median ?? .infinity) <= (baselineSpeed.median ?? 0) * 0.7
        let ttftIncrease = comparesTTFT
            && (currentTTFT.median ?? 0) >= (baselineTTFT.median ?? 0) * 1.5
            && (currentTTFT.median ?? 0) - (baselineTTFT.median ?? 0) >= 1
        return trend(speedDrop || ttftIncrease ? .slower : .noLargeChange, speed: comparesSpeed, ttft: comparesTTFT)
    }
}
