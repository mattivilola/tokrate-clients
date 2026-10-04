import Foundation

/// A completed client turn summarized without its prompt, response, or source path.
public struct TurnMetric: Codable, Identifiable, Hashable, Sendable {
    public static let codexClient = "codex"
    public static let codexParserVersion = "codex-rollout-v1"
    public static let codexMetricVersion = "turn-v1"

    /// Only populated when every observed turn_context agrees on an allowlisted effort.
    public let reasoningEffort: String?
    /// A SHA-256 pseudonym derived locally from the session and turn identifiers.
    public let id: String
    public let completedAt: Date
    /// Stable client identifier, such as `codex`, `claude-code`, or `grok-build`.
    public let client: String
    public let model: String?
    public let clientVersion: String?
    public let parserVersion: String
    public let metricVersion: String
    public let reasoningOutputTokens: Int?
    public let sourceKind: String?
    public let provider: String?
    public let outputTokens: Int
    public let durationSeconds: Double
    public let codexTTFTSeconds: Double?
    /// Generic name for the source-reported TTFT observation. The stored Codex name remains
    /// for backward compatibility with existing history files.
    public var isSupportedSourceTuple: Bool {
        Self.isSupportedSourceTuple(client: client, parserVersion: parserVersion, metricVersion: metricVersion)
    }
    public var ttftSeconds: Double? {
        isSupportedSourceTuple && client == "codex" ? codexTTFTSeconds : nil
    }
    public var throughputLabel: String {
        Self.throughputLabel(client: client, parserVersion: parserVersion, metricVersion: metricVersion)
    }
    public var throughputExplanation: String {
        Self.throughputExplanation(client: client, parserVersion: parserVersion, metricVersion: metricVersion)
    }

    /// The single allowlist of client/parser/metric tuples that may be displayed as comparable
    /// measurements or shared. Claude's v1 parser stays listed so saved history keeps decoding.
    public static func isSupportedSourceTuple(client: String, parserVersion: String, metricVersion: String) -> Bool {
        switch (client, parserVersion, metricVersion) {
        case ("codex", "codex-rollout-v1", "turn-v1"),
             ("claude-code", "claude-transcript-v1", "claude-observed-turn-v1"),
             ("claude-code", "claude-transcript-v2", "claude-observed-turn-v1"),
             ("claude-code", "claude-transcript-v2", "claude-observed-subagent-turn-v1"),
             ("grok-build", "grok-session-v1", "grok-observed-work-turn-v1"):
            true
        default:
            false
        }
    }

    public static func throughputLabel(client: String, parserVersion: String, metricVersion: String) -> String {
        guard isSupportedSourceTuple(client: client, parserVersion: parserVersion, metricVersion: metricVersion) else {
            return "Turn throughput"
        }
        return switch metricVersion {
        case "grok-observed-work-turn-v1": "Work-turn throughput · includes subagent output"
        case "claude-observed-subagent-turn-v1": "Subagent turn speed"
        default: "Turn throughput"
        }
    }

    public static func throughputExplanation(client: String, parserVersion: String, metricVersion: String) -> String {
        guard isSupportedSourceTuple(client: client, parserVersion: parserVersion, metricVersion: metricVersion) else {
            return "Includes tools, waiting & reasoning"
        }
        return switch metricVersion {
        case "grok-observed-work-turn-v1": "Includes nested subagent output, tools & waiting"
        case "claude-observed-subagent-turn-v1": "Subagent task prompt to final answer, including tools and waiting."
        default: "Includes tools, waiting & reasoning"
        }
    }
    public let turnThroughputTPS: Double
    /// Deliberately unavailable until Codex provides a verified generation-only metric.
    public let streamingTPS: Double?

    public init(
        id: String,
        completedAt: Date,
        model: String?,
        outputTokens: Int,
        durationSeconds: Double,
        codexTTFTSeconds: Double?,
        turnThroughputTPS: Double,
        streamingTPS: Double? = nil,
        client: String = TurnMetric.codexClient,
        clientVersion: String? = nil,
        parserVersion: String = TurnMetric.codexParserVersion,
        metricVersion: String = TurnMetric.codexMetricVersion,
        reasoningOutputTokens: Int? = nil,
        sourceKind: String? = nil,
        provider: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.reasoningEffort = reasoningEffort.flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
        self.client = client
        self.clientVersion = clientVersion
        self.parserVersion = parserVersion
        self.metricVersion = metricVersion
        self.reasoningOutputTokens = reasoningOutputTokens
        self.sourceKind = sourceKind
        self.provider = provider
        self.id = id
        self.completedAt = completedAt
        self.model = model
        self.outputTokens = outputTokens
        self.durationSeconds = durationSeconds
        self.codexTTFTSeconds = codexTTFTSeconds
        self.turnThroughputTPS = turnThroughputTPS
        self.streamingTPS = streamingTPS
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort, id, completedAt, client, model, clientVersion, parserVersion, metricVersion
        case reasoningOutputTokens, sourceKind, provider, outputTokens, durationSeconds, codexTTFTSeconds
        case turnThroughputTPS, streamingTPS
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
            .flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
        id = try values.decode(String.self, forKey: .id)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        // History written before multi-client support contains only Codex observations.
        client = try values.decodeIfPresent(String.self, forKey: .client) ?? Self.codexClient
        model = try values.decodeIfPresent(String.self, forKey: .model)
        clientVersion = try values.decodeIfPresent(String.self, forKey: .clientVersion)
        parserVersion = try values.decodeIfPresent(String.self, forKey: .parserVersion) ?? Self.codexParserVersion
        metricVersion = try values.decodeIfPresent(String.self, forKey: .metricVersion) ?? Self.codexMetricVersion
        reasoningOutputTokens = try values.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens)
        sourceKind = try values.decodeIfPresent(String.self, forKey: .sourceKind)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        codexTTFTSeconds = try values.decodeIfPresent(Double.self, forKey: .codexTTFTSeconds)
        turnThroughputTPS = try values.decode(Double.self, forKey: .turnThroughputTPS)
        streamingTPS = try values.decodeIfPresent(Double.self, forKey: .streamingTPS)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try values.encode(id, forKey: .id)
        try values.encode(completedAt, forKey: .completedAt)
        try values.encode(client, forKey: .client)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try values.encode(parserVersion, forKey: .parserVersion)
        try values.encode(metricVersion, forKey: .metricVersion)
        try values.encodeIfPresent(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try values.encodeIfPresent(sourceKind, forKey: .sourceKind)
        try values.encodeIfPresent(provider, forKey: .provider)
        try values.encode(outputTokens, forKey: .outputTokens)
        try values.encode(durationSeconds, forKey: .durationSeconds)
        try values.encodeIfPresent(codexTTFTSeconds, forKey: .codexTTFTSeconds)
        try values.encode(turnThroughputTPS, forKey: .turnThroughputTPS)
        try values.encodeIfPresent(streamingTPS, forKey: .streamingTPS)
    }
}

public enum ReportedReasoningEffort {
    public static func isAllowed(_ value: String) -> Bool {
        switch value {
        case "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra": true
        default: false
        }
    }
}
