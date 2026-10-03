import Foundation

public struct GlobalBoard: Decodable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String?
    public let dataAsOf: String?
    public let collectionEnabled: Bool
    public let state: String
    public let window: String
    public let methodology: Methodology?
    public let cohorts: [Cohort]
    public let alerts: [Alert]
    public var publicationMode: String? { methodology?.publicationMode }

    public struct Methodology: Decodable, Sendable {
        public let statistics: String?
        public let publicationMode: String?
        public let minimumContributors: Int?
        public let minimumTurns: Int?
        public let observationBucketMinutes: Int?
        public let streamingSpeedAvailable: Bool?
        public let source: String?
        public let detectorVersion: String?
    }

    public struct Cohort: Decodable, Identifiable, Sendable {
        public let id: String
        public let model: String
        public let provider: String
        public let clientVersion: String?
        public let reasoningEffort: String?
        public let client: String?
        public let parserVersion: String?
        public let metricVersion: String?
        public let contributors: Int
        public let turns: Int
        public let throughputContributors: Int?
        public let throughputTurns: Int?
        public let ttftContributors: Int?
        public let ttftTurns: Int?
        public let medianThroughput: Double?
        public let throughputCount: Int?
        public let minThroughput: Double?
        public let maxThroughput: Double?
        public let p10Throughput: Double?
        public let medianTtftMs: Double?
        public let ttftCount: Int?
        public let minTtftMs: Double?
        public let maxTtftMs: Double?
        public let p95TtftMs: Double?
        public let comparison: Comparison?
        public let signals: Signals?
    }

    /// Additive server trend data. Every field is optional so older and partial boards remain readable.
    public struct Comparison: Decodable, Sendable {
        public let throughput: ComparisonMetric?
        public let ttft: ComparisonMetric?
    }

    public struct ComparisonMetric: Decodable, Sendable {
        public let method: String?
        public let current: ComparisonPeriod?
        public let previous: ComparisonPeriod?
        public let changePercent: Double?
        public let availability: String?
    }

    public struct ComparisonPeriod: Decodable, Sendable {
        public let startAt: String?
        public let endAt: String?
        public let median: Double?
        public let contributors: Int?
        public let turns: Int?
    }

    public struct Signals: Decodable, Sendable {
        public let throughput: Signal?
        public let ttft: Signal?
    }

    public struct Signal: Decodable, Sendable {
        public let state: String?
        public let reason: String?
        public let baselineBuckets: Int?
        public let baselineDays: Int?
        public let baselineHours: Double?
        public let baselineMedian: Double?
        public let changePercent: Double?
        public let lastObservedAt: String?
        public let recentContributors: Int?
        public let recentTurns: Int?
    }
    public struct Alert: Decodable, Identifiable, Sendable {
        public var id: String { "\(cohortId ?? model ?? "all"):\(metric ?? "unknown"):\(state ?? "alert")" }
        public let cohortId: String?
        public let state: String?
        public let metric: String?
        public let changePercent: Double?
        public let model: String?
        public let provider: String?
        public let clientVersion: String?
        public let kind: String?
        public let message: String?
    }
}
