import Foundation

/// The complete upload allowlist. Local deduplication identifiers never cross this boundary.
public struct SharedSample: Encodable, Sendable {
    public let sampleId: UUID
    public let observedAt: Date
    public let client = "codex"
    public let clientVersion: String
    public let appVersion = "0.1.5"
    public let parserVersion = "codex-rollout-v1"
    public let metricVersion = "turn-v1"
    public let model: String
    public let provider: String
    public let sourceKind: String
    public let outputTokens: Int
    public let reasoningOutputTokens: Int?
    public let durationMs: Double
    public let ttftMs: Double?

    public init?(_ metric: TurnMetric, sampleId: UUID = UUID()) {
        let duration = metric.durationSeconds * 1_000
        guard duration.isFinite, (1...86_400_000).contains(duration),
              (0...10_000_000).contains(metric.outputTokens) else { return nil }
        self.sampleId = sampleId
        observedAt = Date(timeIntervalSince1970: floor(metric.completedAt.timeIntervalSince1970 / 300) * 300)
        clientVersion = metric.clientVersion.flatMap { $0.range(of: "^[a-zA-Z0-9.+_-]{1,40}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        model = Self.safeIdentifier(metric.model, maximum: 80) ?? "unknown"
        sourceKind = ["primary", "subagent"].contains(metric.sourceKind ?? "") ? metric.sourceKind! : "unknown"
        provider = metric.provider == "openai" ? "openai" : "unknown"
        outputTokens = metric.outputTokens
        reasoningOutputTokens = metric.reasoningOutputTokens.flatMap { (0...metric.outputTokens).contains($0) ? $0 : nil }
        durationMs = duration
        ttftMs = metric.codexTTFTSeconds.flatMap { value in
            let ms = value * 1_000
            return ms.isFinite && (0...duration).contains(ms) ? ms : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sampleId, observedAt, client, clientVersion, appVersion, parserVersion, metricVersion, model, provider, sourceKind, outputTokens, reasoningOutputTokens, durationMs, ttftMs
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
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(ttftMs, forKey: .ttftMs)
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
