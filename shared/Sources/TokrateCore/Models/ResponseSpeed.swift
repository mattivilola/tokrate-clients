import Foundation

/// The rules that decide whether one API response counts toward response speed (contract name
/// `response-v1`). The Mac and Windows/Linux clients share them verbatim.
public enum ResponseSpeed {
    /// Shorter responses are mostly automated check-ins and tool calls, and their timing is dominated
    /// by request latency rather than decoding.
    public static let minimumOutputTokens = 200
    /// A longer gap is a stalled or resumed request, not one response.
    public static let maximumDurationSeconds: TimeInterval = 600

    public static func qualifies(outputTokens: Int, durationSeconds: TimeInterval) -> Bool {
        outputTokens >= minimumOutputTokens
            && durationSeconds.isFinite && durationSeconds > 0 && durationSeconds <= maximumDurationSeconds
    }
}

/// One qualifying API response, exposed as it completes. Local only: it is never persisted, shared
/// or uploaded, and carries no prompt, response text, path or session identifier.
public struct LiveResponse: Hashable, Sendable, Identifiable {
    /// Local deduplication key (the live and archive readers can both see a response).
    public let id: String
    public let model: String?
    public let provider: String?
    public let client: String
    public let sourceKind: String
    public let metricVersion: String
    public let reasoningEffort: String?
    public let completedAt: Date
    public let outputTokens: Int
    public let durationSeconds: Double

    public init(
        id: String, model: String?, provider: String?, client: String, sourceKind: String,
        metricVersion: String, reasoningEffort: String?, completedAt: Date, outputTokens: Int, durationSeconds: Double
    ) {
        self.id = id
        self.model = model
        self.provider = provider
        self.client = client
        self.sourceKind = sourceKind
        self.metricVersion = metricVersion
        self.reasoningEffort = reasoningEffort
        self.completedAt = completedAt
        self.outputTokens = outputTokens
        self.durationSeconds = durationSeconds
    }

    public var tokensPerSecond: Double { Double(outputTokens) / durationSeconds }
}

/// What one monitor poll produced: completed turns, plus the qualifying responses that finished
/// after the monitor started. Only the responses feed the live readout.
public struct MonitorUpdate: Sendable {
    public var metrics: [TurnMetric]
    public var responses: [LiveResponse]

    public init(metrics: [TurnMetric] = [], responses: [LiveResponse] = []) {
        self.metrics = metrics
        self.responses = responses
    }
}
