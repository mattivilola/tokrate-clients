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
    /// Stable client identifier, such as `codex`, `claude-code`, `grok-build`, `antigravity`, `opencode`, or `kimi-code`.
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
    /// Output tokens of delegated subagent work started during this primary turn that are not already
    /// part of `outputTokens` (contract "Delegated output"). Nil while the attribution is not final
    /// and for records it does not apply to (subagent records, history saved before 0.1.16).
    public let delegatedOutputTokens: Int?
    /// Where the coding tool ran (contract "Surface"). Nil when the source gives no signal; only the
    /// category is kept, never the originator or entrypoint it came from.
    public let surface: ToolSurface?
    /// Input (prompt) tokens processed across all model requests of the turn, including tokens served
    /// from the prompt cache (contract "Prompt cache"). Nil when the source does not report it.
    public let inputTokens: Int?
    /// Input tokens served from the provider's prompt cache; never more than `inputTokens`, and nil
    /// exactly when `inputTokens` is.
    public let cacheReadInputTokens: Int?
    /// Tokens written to the prompt cache. Reported by Claude Code only; nil for Codex and Grok Build
    /// (their logs carry a field that is always 0, which is not a report) and whenever `inputTokens` is nil.
    public let cacheWriteInputTokens: Int?
    /// Generic name for the source-reported TTFT observation. The stored Codex name remains
    /// for backward compatibility with existing history files.
    /// Output tokens per second while the model was responding: tools and waiting excluded.
    public var responseSpeedTPS: Double? {
        guard let tokens = responseOutputTokens, let seconds = responseDurationSeconds,
              let count = responseCount, count > 0, tokens > 0, seconds > 0, seconds.isFinite else { return nil }
        let speed = Double(tokens) / seconds
        return speed.isFinite ? speed : nil
    }
    /// Whether the turn's throughput is physically plausible (see `ResponseSpeed`).
    public var hasPlausibleTurnThroughput: Bool {
        ResponseSpeed.isPlausibleTurnThroughput(outputTokens: outputTokens, durationSeconds: durationSeconds)
    }
    /// Whether the three response fields are present and add up, the one rule behind sharing them and
    /// keeping them in loaded history: at least 200 tokens per response, no more than the turn's
    /// output, 600 s per response at most, inside the turn's duration and at most the speed bound.
    public var hasPlausibleResponseTiming: Bool {
        guard let tokens = responseOutputTokens, let seconds = responseDurationSeconds, let count = responseCount,
              count > 0, tokens <= outputTokens,
              tokens >= ResponseSpeed.minimumOutputTokens * count,
              seconds.isFinite, seconds > 0,
              seconds <= Double(count) * ResponseSpeed.maximumDurationSeconds,
              seconds <= durationSeconds
        else { return false }
        return Double(tokens) / seconds <= ResponseSpeed.maximumTokensPerSecond
    }
    /// A primary turn's delegated attribution is settled once its total is known; every other record
    /// has nothing to wait for.
    public var isDelegationFinal: Bool { sourceKind != "primary" || delegatedOutputTokens != nil }
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
             ("grok-build", "grok-session-v1", "grok-observed-work-turn-v1"),
             ("grok-build", "grok-session-v2", "grok-observed-work-turn-v1"),
             ("antigravity", "antigravity-conversation-v1", "antigravity-observed-execution-v1"),
             ("opencode", "opencode-db-v1", "opencode-observed-turn-v1"),
             ("kimi-code", "kimi-wire-v1", "kimi-observed-turn-v1"):
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
        case "antigravity-observed-execution-v1": "Prompt through final answer of one agent run, including tools & waiting"
        case "opencode-observed-turn-v1", "kimi-observed-turn-v1": "Prompt through final answer, including tools & waiting"
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
        providerRegion: String? = nil,
        delegatedOutputTokens: Int? = nil,
        surface: ToolSurface? = nil,
        inputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil
    ) {
        // The three response fields travel together: a partial set carries no usable measurement.
        let hasResponse = responseOutputTokens.map { $0 > 0 } == true
            && responseDurationSeconds.map { $0.isFinite && $0 > 0 } == true
            && responseCount.map { $0 > 0 } == true
        self.responseOutputTokens = hasResponse ? responseOutputTokens : nil
        self.responseDurationSeconds = hasResponse ? responseDurationSeconds : nil
        self.responseCount = hasResponse ? responseCount : nil
        self.providerRegion = providerRegion
        self.delegatedOutputTokens = delegatedOutputTokens
        self.surface = surface
        let cache = Self.consistentPromptCache(input: inputTokens, read: cacheReadInputTokens, write: cacheWriteInputTokens)
        self.inputTokens = cache.input
        self.cacheReadInputTokens = cache.read
        self.cacheWriteInputTokens = cache.write
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
        case responseOutputTokens, responseDurationSeconds, responseCount, providerRegion, delegatedOutputTokens, surface
        case inputTokens, cacheReadInputTokens, cacheWriteInputTokens
    }

    /// The prompt-cache fields as one consistent set (contract "Prompt cache"): input and cache-read
    /// travel together, cache-write needs the input total, and a read larger than the input is
    /// inconsistent source data, so every field is dropped. Negative values are never valid.
    static func consistentPromptCache(input: Int?, read: Int?, write: Int?) -> (input: Int?, read: Int?, write: Int?) {
        guard let input, let read, input >= 0, read >= 0, read <= input, write.map({ $0 >= 0 }) ?? true
        else { return (nil, nil, nil) }
        return (input, read, write)
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
        // Records saved before response speed (0.1.14; Grok Build 0.1.15) carry none of these fields.
        responseOutputTokens = try values.decodeIfPresent(Int.self, forKey: .responseOutputTokens)
        responseDurationSeconds = try values.decodeIfPresent(Double.self, forKey: .responseDurationSeconds)
        responseCount = try values.decodeIfPresent(Int.self, forKey: .responseCount)
        providerRegion = try values.decodeIfPresent(String.self, forKey: .providerRegion)
        // Records saved before 0.1.16 carry no delegated total: the attribution was never made.
        delegatedOutputTokens = try values.decodeIfPresent(Int.self, forKey: .delegatedOutputTokens)
        // Records saved before 0.1.18 carry no surface. A value this build does not know (written by a
        // newer one) reads as unknown instead of failing the record.
        surface = (try? values.decodeIfPresent(String.self, forKey: .surface)).flatMap(ToolSurface.init(rawValue:))
        // Records saved before 0.1.18 carry no prompt-cache fields. The set is normalized exactly as
        // when it is built, so a stored inconsistent set reads as not reported.
        let cache = Self.consistentPromptCache(
            input: try values.decodeIfPresent(Int.self, forKey: .inputTokens),
            read: try values.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens),
            write: try values.decodeIfPresent(Int.self, forKey: .cacheWriteInputTokens)
        )
        inputTokens = cache.input
        cacheReadInputTokens = cache.read
        cacheWriteInputTokens = cache.write
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
        try values.encodeIfPresent(delegatedOutputTokens, forKey: .delegatedOutputTokens)
        try values.encodeIfPresent(surface, forKey: .surface)
        try values.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try values.encodeIfPresent(cacheReadInputTokens, forKey: .cacheReadInputTokens)
        try values.encodeIfPresent(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
    }

    /// This record without response timing, for a measurement that failed `hasPlausibleResponseTiming`.
    public func withoutResponseTiming() -> TurnMetric {
        TurnMetric(
            id: id, completedAt: completedAt, model: model, outputTokens: outputTokens,
            durationSeconds: durationSeconds, codexTTFTSeconds: codexTTFTSeconds,
            turnThroughputTPS: turnThroughputTPS, streamingTPS: streamingTPS, client: client,
            clientVersion: clientVersion, parserVersion: parserVersion, metricVersion: metricVersion,
            reasoningOutputTokens: reasoningOutputTokens, sourceKind: sourceKind, provider: provider,
            reasoningEffort: reasoningEffort, providerRegion: providerRegion,
            delegatedOutputTokens: delegatedOutputTokens, surface: surface,
            inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens
        )
    }

    /// This record with its delegated total settled; the attribution re-emits the same id.
    public func withDelegatedOutputTokens(_ tokens: Int?) -> TurnMetric {
        TurnMetric(
            id: id, completedAt: completedAt, model: model, outputTokens: outputTokens,
            durationSeconds: durationSeconds, codexTTFTSeconds: codexTTFTSeconds,
            turnThroughputTPS: turnThroughputTPS, streamingTPS: streamingTPS, client: client,
            clientVersion: clientVersion, parserVersion: parserVersion, metricVersion: metricVersion,
            reasoningOutputTokens: reasoningOutputTokens, sourceKind: sourceKind, provider: provider,
            reasoningEffort: reasoningEffort, responseOutputTokens: responseOutputTokens,
            responseDurationSeconds: responseDurationSeconds, responseCount: responseCount,
            providerRegion: providerRegion, delegatedOutputTokens: tokens, surface: surface,
            inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens
        )
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
