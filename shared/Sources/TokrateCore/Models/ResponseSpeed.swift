import Foundation

/// The rules that decide whether one API response counts toward response speed (contract name
/// `response-v1`). The Mac and Windows/Linux clients share them verbatim.
public enum ResponseSpeed {
    /// Shorter responses are mostly automated check-ins and tool calls, and their timing is dominated
    /// by request latency rather than decoding.
    public static let minimumOutputTokens = 200
    /// A longer gap is a stalled or resumed request, not one response.
    public static let maximumDurationSeconds: TimeInterval = 600

    /// A rate above this is a measurement error, not a model: it applies to responses and to whole
    /// turns, at measurement time, when saved history loads and before anything is shared.
    public static let maximumTokensPerSecond = 2_000.0

    public static func qualifies(outputTokens: Int, durationSeconds: TimeInterval) -> Bool {
        outputTokens >= minimumOutputTokens
            && durationSeconds.isFinite && durationSeconds > 0 && durationSeconds <= maximumDurationSeconds
            && Double(outputTokens) / durationSeconds <= maximumTokensPerSecond
    }

    /// Whether a whole turn's throughput is physically plausible. A turn that fails is a measurement
    /// error: parsers emit no record for it, like any other invalid duration.
    public static func isPlausibleTurnThroughput(outputTokens: Int, durationSeconds: TimeInterval) -> Bool {
        guard outputTokens >= 0, durationSeconds.isFinite, durationSeconds > 0 else { return false }
        return Double(outputTokens) / durationSeconds <= maximumTokensPerSecond
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

    /// A completed primary turn that reports its response timing as one aggregate, as a live
    /// response. Grok Build reports speed per turn only, so its live entry is the response average
    /// of one whole turn (every model call, tools and waiting excluded), not a single response; the
    /// turn id is the response id. Nil for subagent turns, a missing model or timing, or timing that
    /// does not qualify as a response (`ResponseSpeed.qualifies`).
    public init?(turn: TurnMetric) {
        guard turn.sourceKind == "primary", let model = turn.model,
              let tokens = turn.responseOutputTokens, let seconds = turn.responseDurationSeconds,
              ResponseSpeed.qualifies(outputTokens: tokens, durationSeconds: seconds) else { return nil }
        self.init(
            id: turn.id, model: model, provider: turn.provider, client: turn.client, sourceKind: "primary",
            metricVersion: turn.metricVersion, reasoningEffort: turn.reasoningEffort, completedAt: turn.completedAt,
            outputTokens: tokens, durationSeconds: seconds
        )
    }

    public var tokensPerSecond: Double { Double(outputTokens) / durationSeconds }
}

/// What one monitor poll produced: completed turns, plus the qualifying responses that finished
/// after the monitor started. Only the responses feed the live readout.
public struct MonitorUpdate: Sendable {
    public var metrics: [TurnMetric]
    public var responses: [LiveResponse]
    /// Request outcomes that finished after the monitor started (see `RequestOutcome`). They go to the
    /// sharing session only: never into the history, the dashboard or any export.
    public var outcomes: [RequestOutcome] = []
    /// Delegated-work lifecycle events a source monitor collected; consumed by the monitor that owns
    /// the attribution and never part of what it returns.
    var delegation: [DelegationEvent] = []

    public init(metrics: [TurnMetric] = [], responses: [LiveResponse] = [], outcomes: [RequestOutcome] = []) {
        self.metrics = metrics
        self.responses = responses
        self.outcomes = outcomes
    }
}
