import Foundation

/// A completed client turn summarized without its prompt, response, or source path.
public struct TurnMetric: Codable, Identifiable, Hashable, Sendable {
    public static let codexClient = "codex"
    public static let codexParserVersion = "codex-rollout-v2"
    /// Parser version of Codex records saved before response speed existed; the decoding default.
    public static let legacyCodexParserVersion = "codex-rollout-v1"
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
    /// Output tokens summed over the turn's qualifying API responses (see `ResponseSpeed`). Nil when
    /// no response qualified or the source cannot provide per-response timing.
    public let responseOutputTokens: Int?
    /// Seconds summed over the same qualifying responses.
    public let responseDurationSeconds: Double?
    /// Number of qualifying responses behind the two totals.
    public let responseCount: Int?
    /// Inference-profile region of a Claude model routed through Amazon Bedrock (`us`, `eu`, `apac`,
    /// `global`, `jp`, `au`, `ca`, `us-gov`, or `unknown`). Nil for every other provider.
    public let providerRegion: String?
    /// Generic name for the source-reported TTFT observation. The stored Codex name remains
    /// for backward compatibility with existing history files.
    /// Output tokens per second while the model was responding: tools and waiting excluded.
    public var responseSpeedTPS: Double? {
        guard let tokens = responseOutputTokens, let seconds = responseDurationSeconds,
              let count = responseCount, count > 0, tokens > 0, seconds > 0, seconds.isFinite else { return nil }
        let speed = Double(tokens) / seconds
        return speed.isFinite ? speed : nil
    }
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
    /// measurements or shared. Older parser versions stay listed so saved history keeps decoding;
    /// `SharedSample` refuses Claude v1 and v2.
    public static func isSupportedSourceTuple(client: String, parserVersion: String, metricVersion: String) -> Bool {
        switch (client, parserVersion, metricVersion) {
        case ("codex", "codex-rollout-v1", "turn-v1"),
             ("codex", "codex-rollout-v2", "turn-v1"),
             ("claude-code", "claude-transcript-v1", "claude-observed-turn-v1"),
             ("claude-code", "claude-transcript-v2", "claude-observed-turn-v1"),
             ("claude-code", "claude-transcript-v2", "claude-observed-subagent-turn-v1"),
             ("claude-code", "claude-transcript-v3", "claude-observed-turn-v1"),
             ("claude-code", "claude-transcript-v3", "claude-observed-subagent-turn-v1"),
             ("claude-code", "claude-transcript-v4", "claude-observed-turn-v1"),
             ("claude-code", "claude-transcript-v4", "claude-observed-subagent-turn-v1"),
             ("grok-build", "grok-session-v1", "grok-observed-work-turn-v1"):
            true
        default:
            false
        }
    }

    public static func throughputLabel(client: String, parserVersion: String, metricVersion: String) -> String {
        guard isSupportedSourceTuple(client: client, parserVersion: parserVersion, metricVersion: metricVersion) else {
            return "Turn speed"
        }
        return switch metricVersion {
        case "grok-observed-work-turn-v1": "Work-turn speed"
        case "claude-observed-subagent-turn-v1": "Subagent turn speed"
        default: "Turn speed"
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
        reasoningEffort: String? = nil,
        responseOutputTokens: Int? = nil,
        responseDurationSeconds: Double? = nil,
        responseCount: Int? = nil,
        providerRegion: String? = nil
    ) {
        // The three response fields travel together: a partial set carries no usable measurement.
        let hasResponse = responseOutputTokens.map { $0 > 0 } == true
            && responseDurationSeconds.map { $0.isFinite && $0 > 0 } == true
            && responseCount.map { $0 > 0 } == true
        self.responseOutputTokens = hasResponse ? responseOutputTokens : nil
        self.responseDurationSeconds = hasResponse ? responseDurationSeconds : nil
        self.responseCount = hasResponse ? responseCount : nil
        self.providerRegion = providerRegion
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
        case responseOutputTokens, responseDurationSeconds, responseCount, providerRegion
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
        parserVersion = try values.decodeIfPresent(String.self, forKey: .parserVersion) ?? Self.legacyCodexParserVersion
        metricVersion = try values.decodeIfPresent(String.self, forKey: .metricVersion) ?? Self.codexMetricVersion
        reasoningOutputTokens = try values.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens)
        sourceKind = try values.decodeIfPresent(String.self, forKey: .sourceKind)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        codexTTFTSeconds = try values.decodeIfPresent(Double.self, forKey: .codexTTFTSeconds)
        turnThroughputTPS = try values.decode(Double.self, forKey: .turnThroughputTPS)
        streamingTPS = try values.decodeIfPresent(Double.self, forKey: .streamingTPS)
        // Records saved before response speed (0.1.14) carry none of these fields.
        responseOutputTokens = try values.decodeIfPresent(Int.self, forKey: .responseOutputTokens)
        responseDurationSeconds = try values.decodeIfPresent(Double.self, forKey: .responseDurationSeconds)
        responseCount = try values.decodeIfPresent(Int.self, forKey: .responseCount)
        providerRegion = try values.decodeIfPresent(String.self, forKey: .providerRegion)
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
        try values.encodeIfPresent(responseOutputTokens, forKey: .responseOutputTokens)
        try values.encodeIfPresent(responseDurationSeconds, forKey: .responseDurationSeconds)
        try values.encodeIfPresent(responseCount, forKey: .responseCount)
        try values.encodeIfPresent(providerRegion, forKey: .providerRegion)
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
