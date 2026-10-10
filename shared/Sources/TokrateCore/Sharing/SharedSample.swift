import Foundation

/// The complete upload allowlist. Local deduplication identifiers never cross this boundary.
public struct SharedSample: Encodable, Sendable {
    public let sampleId: UUID
    public let observedAt: Date
    public let client: String
    public let clientVersion: String
    /// The release this build reports, in every upload and in the `User-Agent` of every community request.
    public static let appVersion = "0.1.22"
    public let appVersion = SharedSample.appVersion
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

    /// Why a turn is never uploaded. The first failing rule is reported; `init?(_:sampleId:)` accepts a
    /// turn exactly when there is none, so this is the one definition of upload eligibility.
    public enum Rejection: String, CaseIterable, Hashable, Sendable {
        /// The client/parser/metric tuple is not a supported measurement.
        case unsupportedSourceTuple
        /// v1 and v2 Claude records may remain in local history but are never shared (since 0.1.13).
        case legacyClaudeParser
        /// The provider is not shared for this client (for example an OpenCode gateway).
        case providerNotShared
        /// A Kimi Code record that claims prompt-cache writes, which its logs never report.
        case unreportedCacheWrite
        /// Grok Build records that carry a client version are not shared.
        case grokClientVersion
        /// A primary turn whose delegated output total is not final yet.
        case delegationNotFinal
        case durationOutOfRange
        case outputTokensOutOfRange
        case implausibleThroughput
        /// A primary turn whose delegated total is outside the accepted bound.
        case delegatedTokensOutOfRange
    }

    public static func rejection(of metric: TurnMetric) -> Rejection? {
        let duration = metric.durationSeconds * 1_000
        if !metric.isSupportedSourceTuple { return .unsupportedSourceTuple }
        if ["claude-transcript-v1", "claude-transcript-v2"].contains(metric.parserVersion) { return .legacyClaudeParser }
        if !isAllowedProvider(metric.provider, client: metric.client) { return .providerNotShared }
        if metric.client == "kimi-code", metric.cacheWriteInputTokens != nil { return .unreportedCacheWrite }
        if metric.client == "grok-build", let version = metric.clientVersion, version != "unknown" { return .grokClientVersion }
        if !metric.isDelegationFinal { return .delegationNotFinal }
        if !duration.isFinite || !(1...86_400_000).contains(duration) { return .durationOutOfRange }
        if !(0...10_000_000).contains(metric.outputTokens) { return .outputTokensOutOfRange }
        if !metric.hasPlausibleTurnThroughput { return .implausibleThroughput }
        if metric.sourceKind == "primary",
           !(0...maximumDelegatedOutputTokens).contains(metric.delegatedOutputTokens ?? -1) { return .delegatedTokensOutOfRange }
        return nil
    }

    public init?(_ metric: TurnMetric, sampleId: UUID = UUID()) {
        guard Self.rejection(of: metric) == nil else { return nil }
        let duration = metric.durationSeconds * 1_000
        self.sampleId = sampleId
        observedAt = Date(timeIntervalSince1970: floor(metric.completedAt.timeIntervalSince1970 / 300) * 300)
        client = metric.client
        clientVersion = metric.clientVersion.flatMap { $0.range(of: "^[a-zA-Z0-9.+_-]{1,40}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        parserVersion = metric.parserVersion
        metricVersion = metric.metricVersion
        model = Self.safeIdentifier(metric.model, maximum: 80) ?? "unknown"
        sourceKind = ["primary", "subagent"].contains(metric.sourceKind ?? "") ? metric.sourceKind! : "unknown"
        delegatedOutputTokens = sourceKind == "primary" ? metric.delegatedOutputTokens : nil
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
    /// routing Antigravity's Gemini models have by construction and OpenCode reports for Google's own API.
    /// OpenCode records with any other provider id (gateways, vendor plans, local servers) stay local.
    /// `moonshot` is the routing of Kimi Code's own API, which is the only provider it shares besides
    /// `unknown`.
    public static func isAllowedProvider(_ provider: String?, client: String) -> Bool {
        switch provider ?? "unknown" {
        case "unknown": true
        case "openai", "anthropic", "xai": client != "kimi-code"
        case "amazon-bedrock", "google-vertex": client == "claude-code"
        case "google": client == "antigravity" || client == "opencode"
        case "moonshot": client == "kimi-code"
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

/// The body of every upload from 0.1.22 (contract "Request outcomes (0.1.22)"): the completed turns and
/// the request counts waiting to leave. Both keys are always present, an empty array when there is
/// nothing of that kind.
public struct SampleEnvelope: Encodable, Sendable {
    public let schemaVersion = 2
    public let sentAt: Date
    public let samples: [SharedSample]
    public let requestCounts: [SharedRequestCount]

    public init(sentAt: Date, samples: [SharedSample], requestCounts: [SharedRequestCount] = []) {
        self.sentAt = sentAt
        self.samples = samples
        self.requestCounts = requestCounts
    }
    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// The encoder of every upload body; one sample encoded with it is exactly its entry in `samples`.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
