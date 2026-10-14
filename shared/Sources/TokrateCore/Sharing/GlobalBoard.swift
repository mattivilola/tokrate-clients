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
    /// The provider-error alerts of `errors.alerts` (contract "Community error alerts (0.1.23)"): empty
    /// when the board has no `errors` or `alerts` (an older server) or only malformed entries, at most
    /// `maximumErrorAlerts`. A malformed alert never fails the board.
    public let errorAlerts: [ErrorAlert]
    public static let maximumErrorAlerts = 20
    public var publicationMode: String? { methodology?.publicationMode }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, dataAsOf, collectionEnabled, state, window, methodology, cohorts, alerts, errors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        dataAsOf = try container.decodeIfPresent(String.self, forKey: .dataAsOf)
        collectionEnabled = try container.decode(Bool.self, forKey: .collectionEnabled)
        state = try container.decode(String.self, forKey: .state)
        window = try container.decode(String.self, forKey: .window)
        methodology = try container.decodeIfPresent(Methodology.self, forKey: .methodology)
        cohorts = try container.decode([Cohort].self, forKey: .cohorts)
        alerts = try container.decode([Alert].self, forKey: .alerts)
        // Additive and optional: anything unreadable under `errors` means no error alerts.
        errorAlerts = (try? container.decodeIfPresent(ErrorSummary.self, forKey: .errors))?.alerts ?? []
    }

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

    /// A (model, provider) pair that contributors report provider failures for in the last hour.
    public struct ErrorAlert: Decodable, Equatable, Sendable {
        public let model: String
        public let provider: String
        public let clients: [String]
        public let failingContributors: Int
        public let overloaded: Int
        public let serverError: Int
        /// Requests the provider throttled while contributors' plans had quota left (0.1.24); 0 from
        /// servers that do not send it.
        public let throttled: Int
        public let firstFailureAt: Date?
        public let lastFailureAt: Date

        public init(
            model: String, provider: String = "", clients: [String] = [], failingContributors: Int,
            overloaded: Int = 0, serverError: Int = 0, throttled: Int = 0, firstFailureAt: Date? = nil,
            lastFailureAt: Date
        ) {
            self.model = model
            self.provider = provider
            self.clients = clients
            self.failingContributors = failingContributors
            self.overloaded = overloaded
            self.serverError = serverError
            self.throttled = throttled
            self.firstFailureAt = firstFailureAt
            self.lastFailureAt = lastFailureAt
        }

        private enum CodingKeys: String, CodingKey {
            case model, provider, clients, failingContributors, overloaded, serverError, throttled, firstFailureAt, lastFailureAt
        }

        /// The model, the contributor count and the time of the latest failure are required (the line
        /// cannot be worded without them); everything else defaults. Negative counts read as zero.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let model = try container.decode(String.self, forKey: .model)
            guard !model.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .model, in: container, debugDescription: "Empty model")
            }
            self.model = model
            provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
            clients = try container.decodeIfPresent([String].self, forKey: .clients) ?? []
            failingContributors = max(0, try container.decode(Int.self, forKey: .failingContributors))
            overloaded = max(0, try container.decodeIfPresent(Int.self, forKey: .overloaded) ?? 0)
            serverError = max(0, try container.decodeIfPresent(Int.self, forKey: .serverError) ?? 0)
            throttled = max(0, try container.decodeIfPresent(Int.self, forKey: .throttled) ?? 0)
            firstFailureAt = try container.decodeIfPresent(String.self, forKey: .firstFailureAt).flatMap(TranscriptTimestamp.parse)
            let last = try container.decode(String.self, forKey: .lastFailureAt)
            guard let lastDate = TranscriptTimestamp.parse(last) else {
                throw DecodingError.dataCorruptedError(forKey: .lastFailureAt, in: container, debugDescription: "Not a timestamp")
            }
            lastFailureAt = lastDate
        }
    }

    private struct ErrorSummary: Decodable {
        let alerts: [ErrorAlert]

        private enum CodingKeys: String, CodingKey { case alerts }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            alerts = (try? container.decodeIfPresent(LossyErrorAlerts.self, forKey: .alerts))?.elements ?? []
        }
    }

    /// Decodes each alert on its own and drops the ones that fail, so one malformed entry never fails
    /// the list. Stops reading once `GlobalBoard.maximumErrorAlerts` valid entries are in.
    private struct LossyErrorAlerts: Decodable {
        let elements: [ErrorAlert]

        private struct Skipped: Decodable {
            init(from decoder: any Decoder) throws {}
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var elements: [ErrorAlert] = []
            while !container.isAtEnd, elements.count < GlobalBoard.maximumErrorAlerts {
                if let element = try? container.decode(ErrorAlert.self) {
                    elements.append(element)
                } else {
                    // A failed decode leaves the cursor in place: step over the entry.
                    _ = try? container.decode(Skipped.self)
                }
            }
            self.elements = elements
        }
    }
}
