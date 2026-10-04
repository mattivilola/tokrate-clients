import Foundation
import TokrateCore

enum DashboardRange: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String { self == .day ? "24 hours" : "7 days" }
    var shortTitle: String { self == .day ? "24 h" : "7 d" }
    /// Number of chart buckets across the range.
    var bucketCount: Int { self == .day ? 48 : 56 }
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

/// The exact local comparison dimensions. Missing fields stay distinct from explicit values.
struct ModelCohort: Hashable, Identifiable, Sendable {
    let model: String?
    let provider: String?
    let clientVersion: String?
    let reasoningEffort: String?
    let client: String
    let parserVersion: String
    let metricVersion: String

    init(
        model: String?, provider: String?, clientVersion: String?, reasoningEffort: String? = nil,
        client: String = TurnMetric.codexClient,
        parserVersion: String = TurnMetric.codexParserVersion,
        metricVersion: String = TurnMetric.codexMetricVersion
    ) {
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
            metricVersion: metric.metricVersion
        )
    }

    var id: String {
        [model, provider, clientVersion, parserVersion, metricVersion, reasoningEffort, client].map(Self.encode).joined(separator: ".")
    }

    var displayModel: String { model ?? "Unknown model" }
    var clientLabel: String {
        Self.clientTitle(client)
    }
    static func clientTitle(_ client: String) -> String {
        switch client {
        case "codex": "Codex"
        case "claude-code": "Claude Code"
        case "grok-build": "Grok Build"
        default: client
        }
    }
    var detailLabel: String {
        [clientLabel, "parser \(parserVersion)", "metric \(metricVersion)", provider.map { "provider \($0)" } ?? "provider unknown", clientVersion.map { "version \($0)" } ?? "version unknown", "reasoning effort \(reasoningEffort ?? "unknown")"]
            .joined(separator: " · ")
    }
    var selectionLabel: String { "\(displayModel) · \(detailLabel)" }

    /// Matches the public board's stable seven-dimension JSON identity.
    var communityBoardID: String? {
        guard let model, isSafe(model, pattern: "^[a-zA-Z0-9._-]{1,80}$"),
              ["openai", "anthropic", "xai", "unknown"].contains(provider ?? "unknown"),
              ["codex", "claude-code", "grok-build"].contains(client),
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
        guard parts.count == 7,
              let model = Self.decode(parts[0]),
              let provider = Self.decode(parts[1]),
              let clientVersion = Self.decode(parts[2]),
              let parserValue = Self.decode(parts[3]), let parserVersion = parserValue,
              let metricValue = Self.decode(parts[4]), let metricVersion = metricValue,
              let effort = Self.decode(parts[5]),
              let clientValue = Self.decode(parts[6]), let client = clientValue else { return nil }
        self.init(model: model, provider: provider, clientVersion: clientVersion, reasoningEffort: effort, client: client, parserVersion: parserVersion, metricVersion: metricVersion)
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
    case latest
    case cohort(ModelCohort)
    case all

    static func restored(from value: String?) -> DashboardSelection {
        guard let value else { return .latest }
        if value == "latest" { return .latest }
        if value == "all" { return .all }
        guard value.hasPrefix("cohort:"), let cohort = ModelCohort(id: String(value.dropFirst("cohort:".count))) else {
            return .latest
        }
        return .cohort(cohort)
    }

    var persistenceValue: String {
        switch self {
        case .latest: "latest"
        case .all: "all"
        case .cohort(let cohort): "cohort:\(cohort.id)"
        }
    }

    var isAllModels: Bool {
        if case .all = self { return true }
        return false
    }

    func displayLabel(latest: ModelCohort?) -> String {
        switch self {
        case .latest: latest.map { "Latest · \($0.selectionLabel)" } ?? "Latest completed model"
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
    let throughput: MetricStats
    let ttft: MetricStats
}

struct LocalPeriodComparison: Equatable, Sendable {
    let range: DashboardRange
    let recent15Minutes: PeriodMetricStats
    let last24Hours: PeriodMetricStats
    let previous24Hours: PeriodMetricStats
    let currentRange: PeriodMetricStats
    let previousRange: PeriodMetricStats?
    let throughputChangePercent: Double?
    let ttftChangePercent: Double?

    init(records: [TurnMetric], range: DashboardRange, now: Date) {
        func stats(from values: [TurnMetric]) -> PeriodMetricStats {
            let throughput = values.filter { $0.outputTokens >= 20 && $0.turnThroughputTPS.isFinite && $0.turnThroughputTPS >= 0 }
            let ttft = values.compactMap(\.ttftSeconds).filter { $0.isFinite && $0 >= 0 }
            return PeriodMetricStats(
                throughput: MetricStats(values: throughput.map(\.turnThroughputTPS)),
                ttft: MetricStats(values: ttft)
            )
        }

        self.range = range
        let recentStart = now.addingTimeInterval(-15 * 60)
        let dayStart = now.addingTimeInterval(-86_400)
        let previousDayStart = now.addingTimeInterval(-2 * 86_400)
        recent15Minutes = stats(from: records.filter { $0.completedAt >= recentStart && $0.completedAt <= now })
        last24Hours = stats(from: records.filter { $0.completedAt >= dayStart && $0.completedAt <= now })
        previous24Hours = stats(from: records.filter { $0.completedAt >= previousDayStart && $0.completedAt < dayStart })
        currentRange = range == .day ? last24Hours : stats(from: records)
        previousRange = range == .day ? previous24Hours : nil
        throughputChangePercent = Self.changePercent(current: last24Hours.throughput, previous: previous24Hours.throughput)
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

    let status: Status
    let currentThroughput: MetricStats
    let baselineThroughput: MetricStats
    let currentTTFT: MetricStats
    let baselineTTFT: MetricStats
    let comparesThroughput: Bool
    let comparesTTFT: Bool
}

/// Pure presentation data: safe to construct for previews without any store, monitor, or network.
struct DashboardSnapshot {
    struct Bucket: Identifiable {
        var id: Date { date }
        let date: Date
        let median: Double
        let turns: Int
    }

    struct CohortSummary: Identifiable {
        var id: String { cohort.id }
        let cohort: ModelCohort
        let throughput: MetricStats
        let ttft: MetricStats
        let latestAt: Date
    }

    let range: DashboardRange
    let selection: DashboardSelection
    let selectedCohort: ModelCohort?
    let throughputLabel: String
    let latest: TurnMetric?
    /// The selected cohort's latest eligible turn within local retention, independent of the range control.
    let heroMetric: TurnMetric?
    /// Largest 24 h median among cohorts sharing the hero turn's coding tool, metric version and
    /// source kind. Sets the gauge scale; other measurement definitions never stretch it.
    let gaugeGroupMedian: Double?
    let points: [Bucket]
    let turnCount: Int
    let throughput: MetricStats
    let ttft: MetricStats
    let medianRate: Double?
    let medianTTFT: Double?
    let personalTrend: PersonalTrend?
    let cohortSummaries: [CohortSummary]
    let localPeriodComparison: LocalPeriodComparison?
    let records: [TurnMetric]
    let dates: ClosedRange<Date>

    init(
        records: [TurnMetric],
        range: DashboardRange,
        selection: DashboardSelection = .latest,
        now: Date = .now,
        calendar: Calendar = .current,
        clientFilter: String? = nil,
        providerFilter: String? = nil
    ) {
        self.range = range
        self.selection = selection
        let retentionCutoff = now.addingTimeInterval(-MetricHistory.retention)
        let retained = records.filter { metric in
            metric.completedAt >= retentionCutoff && metric.completedAt <= now
                && (clientFilter == nil || metric.client == clientFilter)
                && (providerFilter == nil || (metric.provider ?? "unknown") == providerFilter)
        }
        let latestCohort = retained.max { $0.completedAt < $1.completedAt }.map(ModelCohort.init)
        let resolvedCohort: ModelCohort?
        switch selection {
        case .latest:
            resolvedCohort = latestCohort
        case .cohort(let cohort):
            resolvedCohort = cohort
        case .all:
            resolvedCohort = nil
        }
        selectedCohort = resolvedCohort
        throughputLabel = resolvedCohort?.throughputLabel ?? "Turn speed"

        let selectedRetained = resolvedCohort.map { cohort in
            retained.filter { ModelCohort($0) == cohort }
        } ?? []
        localPeriodComparison = selection.isAllModels || resolvedCohort == nil
            ? nil
            : LocalPeriodComparison(records: selectedRetained, range: range, now: now)

        let start = now.addingTimeInterval(-range.duration)
        dates = start...max(now, start.addingTimeInterval(1))
        let inRange = retained.filter { $0.completedAt >= start }
        let sortedRange = inRange.sorted { $0.completedAt > $1.completedAt }
        let allSummaries = Self.summaries(in: sortedRange)
        cohortSummaries = allSummaries

        if selection.isAllModels {
            self.records = sortedRange
            turnCount = 0
            throughput = MetricStats(values: [])
            ttft = MetricStats(values: [])
            medianRate = nil
            medianTTFT = nil
            latest = nil
            heroMetric = nil
            gaugeGroupMedian = nil
            points = []
            personalTrend = nil
            return
        }

        let scoped: [TurnMetric]
        if let resolvedCohort {
            scoped = sortedRange.filter { ModelCohort($0) == resolvedCohort }
        } else {
            scoped = []
        }
        self.records = scoped

        let eligible = scoped.filter(Self.isThroughputEligible)
        turnCount = eligible.count
        throughput = MetricStats(values: eligible.map(\.turnThroughputTPS))
        ttft = MetricStats(values: scoped.compactMap(\.ttftSeconds).filter { $0.isFinite && $0 >= 0 })
        medianRate = throughput.median
        medianTTFT = ttft.median
        latest = eligible.max { $0.completedAt < $1.completedAt }
        let hero = selectedRetained.filter(Self.isThroughputEligible).max { $0.completedAt < $1.completedAt }
        heroMetric = hero
        gaugeGroupMedian = hero.flatMap { Self.groupMedianMaximum(for: $0, in: records, now: now) }

        let maximumBuckets = range.bucketCount
        let bucketWidth = max(1, range.duration / Double(maximumBuckets))
        var buckets: [Int: [Double]] = [:]
        for record in eligible {
            let index = min(maximumBuckets - 1, max(0, Int(record.completedAt.timeIntervalSince(start) / bucketWidth)))
            buckets[index, default: []].append(record.turnThroughputTPS)
        }
        points = buckets.keys.sorted().map { index in
            let values = buckets[index]!
            return Bucket(
                date: min(now, start.addingTimeInterval((Double(index) + 0.5) * bucketWidth)),
                median: MetricStats(values: values).median ?? 0,
                turns: values.count
            )
        }

        let scopedRetained = retained.filter { ModelCohort($0) == resolvedCohort }
        let hasKnownModelAndProvider = resolvedCohort?.model.map { !$0.isEmpty && $0 != "unknown" } == true
            && resolvedCohort?.provider.map { !$0.isEmpty && $0 != "unknown" } == true
        personalTrend = hasKnownModelAndProvider
            ? Self.personalTrend(in: scopedRetained, now: now, calendar: calendar)
            : nil
    }

    /// The latest turn compared with the selected cohort's own 24 h median.
    var speedDelta: SpeedDelta? {
        SpeedDelta(latest: heroMetric?.turnThroughputTPS, median: localPeriodComparison?.last24Hours.throughput ?? MetricStats(values: []))
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
                return compare(left.throughput.median, right.throughput.median, descending: true, left: left, right: right)
            case .lowerTTFT:
                return compare(left.ttft.median, right.ttft.median, descending: false, left: left, right: right)
            }
        }
    }

    private static func compare(
        _ leftValue: Double?,
        _ rightValue: Double?,
        descending: Bool,
        left: CohortSummary,
        right: CohortSummary
    ) -> Bool {
        switch (leftValue, rightValue) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            return left.latestAt == right.latestAt ? left.id < right.id : left.latestAt > right.latestAt
        }
    }

    private static func isThroughputEligible(_ metric: TurnMetric) -> Bool {
        metric.outputTokens >= 20 && metric.turnThroughputTPS.isFinite && metric.turnThroughputTPS >= 0
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

    private static func personalTrend(in records: [TurnMetric], now: Date, calendar: Calendar) -> PersonalTrend {
        let currentStart = now.addingTimeInterval(-86_400)
        let baselineStart = now.addingTimeInterval(-MetricHistory.retention)
        let eligible = records.filter(isThroughputEligible)
        let current = eligible.filter { $0.completedAt >= currentStart }
        let baseline = eligible.filter { $0.completedAt < currentStart && $0.completedAt >= baselineStart }
        let ttftRecords = records.filter { $0.ttftSeconds.map { $0.isFinite && $0 >= 0 } == true }
        let currentTTFTRecords = ttftRecords.filter { $0.completedAt >= currentStart }
        let baselineTTFTRecords = ttftRecords.filter { $0.completedAt < currentStart && $0.completedAt >= baselineStart }
        let currentThroughput = MetricStats(values: current.map(\.turnThroughputTPS))
        let baselineThroughput = MetricStats(values: baseline.map(\.turnThroughputTPS))
        let currentTTFT = MetricStats(values: currentTTFTRecords.compactMap(\.ttftSeconds))
        let baselineTTFT = MetricStats(values: baselineTTFTRecords.compactMap(\.ttftSeconds))

        let status: PersonalTrend.Status
        let latestCurrentObservation = [current.map(\.completedAt).max(), currentTTFTRecords.map(\.completedAt).max()]
            .compactMap { $0 }
            .max()
        guard latestCurrentObservation.map({ now.timeIntervalSince($0) <= 3_600 }) == true else {
            status = .noRecentObservations
            return PersonalTrend(status: status, currentThroughput: currentThroughput, baselineThroughput: baselineThroughput, currentTTFT: currentTTFT, baselineTTFT: baselineTTFT, comparesThroughput: false, comparesTTFT: false)
        }

        let throughputBaselineDays = Set(baseline.map { calendar.startOfDay(for: $0.completedAt) })
        let ttftBaselineDays = Set(baselineTTFTRecords.map { calendar.startOfDay(for: $0.completedAt) })
        let comparesThroughput = current.count >= 5 && baseline.count >= 20 && throughputBaselineDays.count >= 2
            && current.map(\.completedAt).max().map { now.timeIntervalSince($0) <= 3_600 } == true
            && (baselineThroughput.median ?? 0) > 0
        let comparesTTFT = currentTTFTRecords.count >= 5 && baselineTTFTRecords.count >= 20 && ttftBaselineDays.count >= 2
            && currentTTFTRecords.map(\.completedAt).max().map { now.timeIntervalSince($0) <= 3_600 } == true
            && (baselineTTFT.median ?? 0) > 0

        guard comparesThroughput || comparesTTFT else {
            status = .buildingBaseline
            return PersonalTrend(status: status, currentThroughput: currentThroughput, baselineThroughput: baselineThroughput, currentTTFT: currentTTFT, baselineTTFT: baselineTTFT, comparesThroughput: false, comparesTTFT: false)
        }

        let throughputDrop = comparesThroughput
            && (currentThroughput.median ?? .infinity) <= (baselineThroughput.median ?? 0) * 0.7
        let ttftIncrease = comparesTTFT
            && (currentTTFT.median ?? 0) >= (baselineTTFT.median ?? 0) * 1.5
            && (currentTTFT.median ?? 0) - (baselineTTFT.median ?? 0) >= 1
        status = throughputDrop || ttftIncrease ? .slower : .noLargeChange
        return PersonalTrend(status: status, currentThroughput: currentThroughput, baselineThroughput: baselineThroughput, currentTTFT: currentTTFT, baselineTTFT: baselineTTFT, comparesThroughput: comparesThroughput, comparesTTFT: comparesTTFT)
    }
}
