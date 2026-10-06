import Foundation

/// The complete upload allowlist. Local deduplication identifiers never cross this boundary.
public struct SharedSample: Encodable, Sendable {
    public let sampleId: UUID
    public let observedAt: Date
    public let client: String
    public let clientVersion: String
    public let appVersion = "0.1.18"
    public let parserVersion: String
    public let metricVersion: String
    public let model: String
    public let provider: String
    public let reasoningEffort: String
    public let sourceKind: String
    public let outputTokens: Int
    public let reasoningOutputTokens: Int?
    public let durationMs: Double
    public let ttftMs: Double?
    /// Response speed (contract `response-v1`): totals over the turn's qualifying API responses.
    /// All three are null together when the turn has none or they fail validation.
    public let responseOutputTokens: Int?
    public let responseDurationMs: Double?
    public let responseCount: Int?
    /// Amazon Bedrock inference-profile region; null for every other provider.
    public let providerRegion: String?
    /// Output tokens of subagent work a primary turn started, beyond `outputTokens`. Always sent, null
    /// for subagent records. A primary turn is shared only once this total is final.
    public let delegatedOutputTokens: Int?
    /// Where the coding tool ran, as a category (contract "Surface"); null when unknown. Always sent.
    public let surface: String?
    /// Prompt-cache usage (contract "Prompt cache"): input tokens of the turn including cached ones,
    /// those read from the cache, and those written to it (Claude Code only). Always sent; null when
    /// the source does not report them.
    public let inputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheWriteInputTokens: Int?
    /// Largest accepted delegated total (the same bound the server enforces).
    public static let maximumDelegatedOutputTokens = 100_000_000
    public static let providerRegions: Set<String> = ["us", "eu", "apac", "global", "jp", "au", "ca", "us-gov", "unknown"]

    public init?(_ metric: TurnMetric, sampleId: UUID = UUID()) {
        let duration = metric.durationSeconds * 1_000
        // v1 and v2 Claude records may remain in local history but are never shared (since 0.1.13).
        guard metric.isSupportedSourceTuple,
              !["claude-transcript-v1", "claude-transcript-v2"].contains(metric.parserVersion),
              Self.isAllowedProvider(metric.provider, client: metric.client),
              (metric.client != "grok-build" || metric.clientVersion == nil || metric.clientVersion == "unknown"),
              metric.isDelegationFinal
        else { return nil }
        guard duration.isFinite, (1...86_400_000).contains(duration),
              (0...10_000_000).contains(metric.outputTokens),
              metric.hasPlausibleTurnThroughput else { return nil }
        self.sampleId = sampleId
        observedAt = Date(timeIntervalSince1970: floor(metric.completedAt.timeIntervalSince1970 / 300) * 300)
        client = metric.client
        clientVersion = metric.clientVersion.flatMap { $0.range(of: "^[a-zA-Z0-9.+_-]{1,40}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        parserVersion = metric.parserVersion
        metricVersion = metric.metricVersion
        model = Self.safeIdentifier(metric.model, maximum: 80) ?? "unknown"
        sourceKind = ["primary", "subagent"].contains(metric.sourceKind ?? "") ? metric.sourceKind! : "unknown"
        if sourceKind == "primary" {
            guard let delegated = metric.delegatedOutputTokens,
                  (0...Self.maximumDelegatedOutputTokens).contains(delegated) else { return nil }
            delegatedOutputTokens = delegated
        } else {
            delegatedOutputTokens = nil
        }
        surface = metric.surface?.rawValue
        inputTokens = metric.inputTokens
        cacheReadInputTokens = metric.cacheReadInputTokens
        cacheWriteInputTokens = metric.cacheWriteInputTokens
        provider = metric.provider ?? "unknown"
        reasoningEffort = metric.reasoningEffort.flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil } ?? "unknown"
        outputTokens = metric.outputTokens
        reasoningOutputTokens = metric.reasoningOutputTokens.flatMap { (0...metric.outputTokens).contains($0) ? $0 : nil }
        durationMs = duration
        ttftMs = metric.ttftSeconds.flatMap { value in
            let ms = value * 1_000
            return ms.isFinite && (0...duration).contains(ms) ? ms : nil
        }
        if metric.hasPlausibleResponseTiming, let tokens = metric.responseOutputTokens,
           let seconds = metric.responseDurationSeconds, let count = metric.responseCount {
            responseOutputTokens = tokens
            responseDurationMs = seconds * 1_000
            responseCount = count
        } else {
            responseOutputTokens = nil
            responseDurationMs = nil
            responseCount = nil
        }
        providerRegion = metric.provider == "amazon-bedrock"
            ? metric.providerRegion.flatMap { Self.providerRegions.contains($0) ? $0 : nil } ?? "unknown"
            : nil
    }

    /// Bedrock and Vertex are explicit-evidence providers only Claude Code reports; `google` is the
    /// routing Antigravity's Gemini models have by construction.
    public static func isAllowedProvider(_ provider: String?, client: String) -> Bool {
        switch provider ?? "unknown" {
        case "openai", "anthropic", "xai", "unknown": true
        case "amazon-bedrock", "google-vertex": client == "claude-code"
        case "google": client == "antigravity"
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sampleId, observedAt, client, clientVersion, appVersion, parserVersion, metricVersion, model, provider, reasoningEffort, sourceKind, outputTokens, reasoningOutputTokens, durationMs, ttftMs
        case responseOutputTokens, responseDurationMs, responseCount, providerRegion, delegatedOutputTokens, surface
        case inputTokens, cacheReadInputTokens, cacheWriteInputTokens
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleId, forKey: .sampleId)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(client, forKey: .client)
        try container.encode(clientVersion, forKey: .clientVersion)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(parserVersion, forKey: .parserVersion)
        try container.encode(metricVersion, forKey: .metricVersion)
        try container.encode(model, forKey: .model)
        try container.encode(provider, forKey: .provider)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(ttftMs, forKey: .ttftMs)
        try container.encode(responseOutputTokens, forKey: .responseOutputTokens)
        try container.encode(responseDurationMs, forKey: .responseDurationMs)
        try container.encode(responseCount, forKey: .responseCount)
        try container.encode(providerRegion, forKey: .providerRegion)
        try container.encode(delegatedOutputTokens, forKey: .delegatedOutputTokens)
        try container.encode(surface, forKey: .surface)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(cacheReadInputTokens, forKey: .cacheReadInputTokens)
        try container.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
    }

    private static func safeIdentifier(_ value: String?, maximum: Int) -> String? {
        guard let value, value.range(of: "^[a-zA-Z0-9._-]{1,\(maximum)}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

public struct SampleEnvelope: Encodable, Sendable {
    public let schemaVersion = 1
    public let sentAt: Date
    public let samples: [SharedSample]

    public init(sentAt: Date, samples: [SharedSample]) { self.sentAt = sentAt; self.samples = samples }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
