import Foundation
import TokrateCore

enum DashboardRange: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String { self == .day ? "24 hours" : "7 days" }
    var duration: TimeInterval { self == .day ? 86_400 : MetricHistory.retention }
}

/// The exact local comparison dimensions. Missing fields stay distinct from explicit values.
struct ModelCohort: Hashable, Identifiable, Sendable {
    let model: String?
    let provider: String?
    let clientVersion: String?

    init(model: String?, provider: String?, clientVersion: String?) {
        self.model = model
        self.provider = provider
        self.clientVersion = clientVersion
    }

    init(_ metric: TurnMetric) {
        self.init(model: metric.model, provider: metric.provider, clientVersion: metric.clientVersion)
    }

    var id: String {
        [model, provider, clientVersion].map(Self.encode).joined(separator: ".")
    }

    var displayModel: String { model ?? "Unknown model" }
    var detailLabel: String {
        [provider, clientVersion.map { "client \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
            .ifEmpty("provider or client version unavailable")
    }
    var selectionLabel: String { "\(displayModel) · \(detailLabel)" }

    init?(id: String) {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let model = Self.decode(parts[0]),
              let provider = Self.decode(parts[1]),
              let clientVersion = Self.decode(parts[2]) else { return nil }
        self.init(model: model, provider: provider, clientVersion: clientVersion)
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
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
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
    let latest: TurnMetric?
    let points: [Bucket]
    let turnCount: Int
    let throughput: MetricStats
    let ttft: MetricStats
    let medianRate: Double?
    let medianTTFT: Double?
    let personalTrend: PersonalTrend?
    let cohortSummaries: [CohortSummary]
    let records: [TurnMetric]
    let dates: ClosedRange<Date>

    init(
        records: [TurnMetric],
        range: DashboardRange,
        selection: DashboardSelection = .latest,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.range = range
        self.selection = selection
        let retentionCutoff = now.addingTimeInterval(-MetricHistory.retention)
        let retained = records.filter { $0.completedAt >= retentionCutoff && $0.completedAt <= now }
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
        ttft = MetricStats(values: scoped.compactMap(\.codexTTFTSeconds).filter { $0.isFinite && $0 >= 0 })
        medianRate = throughput.median
        medianTTFT = ttft.median
        latest = eligible.max { $0.completedAt < $1.completedAt }

        let maximumBuckets = range == .day ? 48 : 56
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
        personalTrend = Self.personalTrend(in: scopedRetained, now: now, calendar: calendar)
    }

    static func median(_ values: [Double]) -> Double? { MetricStats(values: values).median }

    static func rate(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }

    private static func isThroughputEligible(_ metric: TurnMetric) -> Bool {
        metric.outputTokens >= 20 && metric.turnThroughputTPS.isFinite && metric.turnThroughputTPS >= 0
    }

    private static func summaries(in records: [TurnMetric]) -> [CohortSummary] {
        let groups = Dictionary(grouping: records, by: ModelCohort.init)
        return groups.map { cohort, turns in
            let eligible = turns.filter(isThroughputEligible)
            let ttft = turns.compactMap(\.codexTTFTSeconds).filter { $0.isFinite && $0 >= 0 }
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
        let ttftRecords = records.filter { $0.codexTTFTSeconds.map { $0.isFinite && $0 >= 0 } == true }
        let currentTTFTRecords = ttftRecords.filter { $0.completedAt >= currentStart }
        let baselineTTFTRecords = ttftRecords.filter { $0.completedAt < currentStart && $0.completedAt >= baselineStart }
        let currentThroughput = MetricStats(values: current.map(\.turnThroughputTPS))
        let baselineThroughput = MetricStats(values: baseline.map(\.turnThroughputTPS))
        let currentTTFT = MetricStats(values: currentTTFTRecords.compactMap(\.codexTTFTSeconds))
        let baselineTTFT = MetricStats(values: baselineTTFTRecords.compactMap(\.codexTTFTSeconds))

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
